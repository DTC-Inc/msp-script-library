## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMMScriptPath    - Optional log directory base provided by the RMM
##
## $env:PozativeLogPath  - Root of Pozative install (default: "C:\Program Files (x86)\Pozative")
## $env:RetentionDays    - Delete matching files older than this many days (default: "14")
## $env:FileFilter       - Filename filter for deletion candidates (default: "*.txt")
## $env:ExcludeRegex     - Regex of paths to never delete (default excludes DTX_Helper,
##                         Pozative_final_DTX_RCM, config backup dirs, connection strings, readmes)
## $env:MinFreePercent   - Warn (exit 2) if volume free % is below this after prune (default: "10")
## $env:DryRun           - "1" = report what would be deleted, delete nothing (default: "0")

# app-pozative-log-prune.ps1
#
# Prunes Pozative log files (SyncLogFile, PaymentLogFile, AditEventListener,
# and any subdirectory streams) older than a retention window. Files only -
# directory structure is preserved so the application never loses its log
# folders. Deletion is restricted to files matching $env:FileFilter under
# $env:PozativeLogPath. Files directly in the Pozative root and anything
# matching $env:ExcludeRegex (integration config, connection strings, vendor
# notes, config backups) are never touched.
#
# Fully non-interactive. No Read-Host anywhere; safe for scheduled RMM
# execution and manual console runs alike.
#
# PHI NOTICE: Pozative log files have been observed to contain patient names,
# patient IDs, and embedded patient documents. This script NEVER reads or
# echoes file contents. Transcript output contains file names, sizes, and
# counts only.
#
# Runs correctly from the NinjaOne 32-bit host; no 64-bit relaunch required
# (filesystem operations only, no WOW64 redirection applies to this path).
#
# Exit codes: 0 = success, 2 = completed with warnings (free space still
# below threshold, some deletions failed, or another instance already
# running), 1 = failure (target path missing or invalid).
#
# Minimum PowerShell version: 5.1 (uses no 7.x-only constructs).
#Requires -Version 5.1

$ScriptLogName = "app-pozative-log-prune.log"

# --- Default optional RMM environment variables --------------------------

if ([string]::IsNullOrEmpty($env:PozativeLogPath)) {
    $env:PozativeLogPath = "C:\Program Files (x86)\Pozative"
}
if ([string]::IsNullOrEmpty($env:RetentionDays)) {
    $env:RetentionDays = "14"
}
if ([string]::IsNullOrEmpty($env:FileFilter)) {
    $env:FileFilter = "*.txt"
}
if ([string]::IsNullOrEmpty($env:ExcludeRegex)) {
    $env:ExcludeRegex = 'DTX_Helper|Pozative_final_DTX_RCM|\\backup\\|DentrixConnectionString|ReadMe'
}
if ([string]::IsNullOrEmpty($env:MinFreePercent)) {
    $env:MinFreePercent = "10"
}
if ([string]::IsNullOrEmpty($env:DryRun)) {
    $env:DryRun = "0"
}

# --- Log path setup -------------------------------------------------------

if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
    $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"
}

# Ensure log directory exists before starting the transcript
$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# Transcript rotation: roll the transcript at 10 MB, keep one prior copy
if (Test-Path -Path $LogPath) {
    $existingLog = Get-Item -Path $LogPath
    if ($existingLog.Length -gt 10MB) {
        $rolledPath = "$LogPath.old"
        if (Test-Path -Path $rolledPath) {
            Remove-Item -Path $rolledPath -Force
        }
        Move-Item -Path $LogPath -Destination $rolledPath -Force
    }
}

# --- Script logic --------------------------------------------------------

Start-Transcript -Path $LogPath -Append

Write-Host "Log path: $LogPath"

$exitCode = 0
$mutex = $null
$mutexAcquired = $false

try {
    # Single-instance mutex - RMM can double-fire scheduled runs
    $mutex = New-Object System.Threading.Mutex($false, "Global\DTC-PozativeLogPrune")
    try {
        $mutexAcquired = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        # Prior holder terminated without releasing; safe to proceed
        $mutexAcquired = $true
    }
    if (-not $mutexAcquired) {
        Write-Host "WARNING: Another instance of this script is already running. Exiting without action."
        $exitCode = 2
        throw "MUTEX_BUSY"
    }

    $targetPath    = $env:PozativeLogPath
    $retentionDays = [int]$env:RetentionDays
    $fileFilter    = $env:FileFilter
    $excludeRegex  = $env:ExcludeRegex
    $minFreePct    = [double]$env:MinFreePercent
    $dryRun        = ($env:DryRun -eq "1")

    Write-Host "Target path: $targetPath"
    Write-Host "Retention: $retentionDays days | Filter: $fileFilter | DryRun: $dryRun | Min free %: $minFreePct"
    Write-Host "Exclusions: $excludeRegex (plus all files directly in the target root)"

    # Safety rails: path must exist and must not be a volume root
    if (-not (Test-Path -Path $targetPath -PathType Container)) {
        Write-Host "ERROR: Target path does not exist: $targetPath"
        $exitCode = 1
        throw "PATH_MISSING"
    }
    $resolvedTarget = (Resolve-Path -Path $targetPath).Path.TrimEnd('\')
    $volumeRoot = [System.IO.Path]::GetPathRoot($resolvedTarget).TrimEnd('\')
    if ($resolvedTarget -eq $volumeRoot) {
        Write-Host "ERROR: Refusing to operate on a volume root: $resolvedTarget"
        $exitCode = 1
        throw "PATH_UNSAFE"
    }

    $driveLetter = $volumeRoot.Substring(0, 1)
    $volume = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($driveLetter):'"
    $freeBeforeGb = [math]::Round($volume.FreeSpace / 1GB, 2)
    $sizeGb = [math]::Round($volume.Size / 1GB, 2)
    Write-Host "Volume $($driveLetter): $sizeGb GB total, $freeBeforeGb GB free before prune"

    $cutoffDate = (Get-Date).AddDays(-$retentionDays)
    Write-Host "Cutoff (LastWriteTime older than): $($cutoffDate.ToString('yyyy-MM-dd HH:mm:ss'))"

    $candidates = Get-ChildItem -Path $resolvedTarget -Filter $fileFilter -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LastWriteTime -lt $cutoffDate -and
            $_.DirectoryName -ne $resolvedTarget -and
            $_.FullName -notmatch $excludeRegex
        }

    if (-not $candidates -or $candidates.Count -eq 0) {
        Write-Host "No files matching '$fileFilter' older than $retentionDays days found under $resolvedTarget."
    } else {
        $totalBytes = ($candidates | Measure-Object -Property Length -Sum).Sum
        $totalGb = [math]::Round($totalBytes / 1GB, 2)
        Write-Host "Candidates: $($candidates.Count) files, $totalGb GB total"

        # Per-directory breakdown (names and sizes only - never file contents)
        Write-Host "--- Per-directory breakdown ---"
        $candidates | Group-Object -Property DirectoryName | Sort-Object -Property @{Expression = { ($_.Group | Measure-Object -Property Length -Sum).Sum }} -Descending | ForEach-Object {
            $grpGb = [math]::Round((($_.Group | Measure-Object -Property Length -Sum).Sum) / 1GB, 2)
            Write-Host ("{0} : {1} files, {2} GB" -f $_.Name, $_.Count, $grpGb)
        }
        Write-Host "-------------------------------"

        $deletedCount = 0
        $deletedBytes = 0
        $failedCount = 0
        foreach ($file in $candidates) {
            if ($dryRun) {
                Write-Host "DRYRUN would delete: $($file.FullName) ($([math]::Round($file.Length / 1MB, 1)) MB)"
                continue
            }
            try {
                $fileLength = $file.Length
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                $deletedCount++
                $deletedBytes += $fileLength
            } catch {
                Write-Host "WARNING: Failed to delete: $($file.FullName) - $($_.Exception.Message)"
                $failedCount++
            }
        }

        if ($dryRun) {
            Write-Host "DRYRUN complete. $($candidates.Count) files / $totalGb GB would be deleted. Nothing was removed."
        } else {
            $deletedGb = [math]::Round($deletedBytes / 1GB, 2)
            Write-Host "Deleted $deletedCount files, $deletedGb GB. Failed: $failedCount."
            if ($failedCount -gt 0 -and $exitCode -eq 0) {
                $exitCode = 2
            }
        }
    }

    # Post-prune free space check
    $volume = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$($driveLetter):'"
    $freeAfterGb = [math]::Round($volume.FreeSpace / 1GB, 2)
    $freeAfterPct = [math]::Round(($volume.FreeSpace / $volume.Size) * 100, 1)
    Write-Host "Volume $($driveLetter): $freeAfterGb GB free after prune ($freeAfterPct`%)"

    if ($freeAfterPct -lt $minFreePct) {
        Write-Host "WARNING: Free space $freeAfterPct`% is below threshold $minFreePct`% after prune. Retention window cannot hold current write rate - investigate log volume growth."
        if ($exitCode -eq 0) {
            $exitCode = 2
        }
    }
} catch {
    if ($_.Exception.Message -notin @("MUTEX_BUSY", "PATH_MISSING", "PATH_UNSAFE")) {
        Write-Host "ERROR: Unhandled exception: $($_.Exception.Message)"
        $exitCode = 1
    }
} finally {
    if ($mutexAcquired -and $mutex) {
        $mutex.ReleaseMutex()
    }
    if ($mutex) {
        $mutex.Dispose()
    }
}

Write-Host "Exit code: $exitCode"

Stop-Transcript

exit $exitCode
