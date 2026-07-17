## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## This script is 100% NON-INTERACTIVE - it hard-fails if $env:RMM is not "1".
## $env:RMM         - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode. REQUIRED.
## $env:RMMScriptPath - Optional log directory base provided by the RMM
## $env:ReportOnly  - "1" to detect and log orphans WITHOUT deleting anything (default "0")
##
## PURPOSE: Removes orphaned Patterson Eaglesoft entries from Add/Remove Programs left
## behind by in-place upgrades (e.g. 21.00.18 -> 25.00.08). The stale entry is registry
## metadata only - there are no old files behind it, and its UninstallString carries
## ESREMOVE=1 (Patterson's DATA-removal switch). This script NEVER runs msiexec: acting
## on the shared install directory risks the live install and the practice database.
## Registry key delete only, and only when ALL THREE proofs hold:
##   1. Entry version parses and is lower than the live (highest) detected version
##   2. Entry InstallLocation matches the live entry's InstallLocation (shared directory)
##   3. Eaglesoft.exe on disk under that location reports the LIVE version (old files are gone)
## Anything unproven is skipped and logged. Idempotent - reruns no-op once clean.
##
## EXIT CODES: 0 = success or nothing to do; 1 = a proven orphan failed to delete,
## or an Eaglesoft entry was detected but orphan status could not be proven (needs eyes).

$ScriptLogName = "eaglesoft-arp-cleanup.log"

# --- Relaunch in 64-bit PowerShell if running under WOW64 -----------------
if ($env:PROCESSOR_ARCHITEW6432 -eq "AMD64") {
    Write-Host "Relaunching in 64-bit PowerShell..."
    & "$env:WINDIR\sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path
    exit $LASTEXITCODE
}

# --- Default optional RMM environment variables --------------------------
if ([string]::IsNullOrEmpty($env:ReportOnly)) { $env:ReportOnly = "0" }

# --- Input handling: non-interactive only --------------------------------
if ($env:RMM -ne "1") {
    Write-Host "ERROR: This script is non-interactive and requires RMM mode. Set `$env:RMM='1' before running manually."
    exit 1
}
if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
    $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"
}

# --- Log rotation (runaway protection: cap transcript growth at ~10MB) ---
$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 10MB)) {
    Move-Item -Path $LogPath -Destination "$LogPath.old" -Force
}

# --- Script logic --------------------------------------------------------
Start-Transcript -Path $LogPath -Append

Write-Host "Log path: $LogPath"
Write-Host "RMM: $env:RMM"
Write-Host "ReportOnly: $env:ReportOnly"

$exitCode = 0

try {
    # --- Enumerate Eaglesoft ARP entries; highest parseable version = live ---
    # @() wrappers throughout: PS 5.1 does not expose .Count on a single PSCustomObject.
    $esEntries = @(Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
                                    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'Eaglesoft' })

    if ($esEntries.Count -eq 0) {
        Write-Host "No Eaglesoft ARP entries detected. Nothing to do."
        Stop-Transcript
        exit 0
    }

    $esVersion = $null
    foreach ($e in $esEntries) {
        Write-Host "Detected: $($e.DisplayName) $($e.DisplayVersion) ($($e.PSChildName)) InstallLocation='$($e.InstallLocation)'"
        $v = $null
        if ([version]::TryParse($e.DisplayVersion, [ref]$v)) {
            if (-not $esVersion -or $v -gt $esVersion) { $esVersion = $v }
        } else {
            Write-Host "WARNING: Unparseable Eaglesoft version string '$($e.DisplayVersion)'."
        }
    }

    if ($esEntries.Count -eq 1) {
        Write-Host "Single Eaglesoft entry only - no orphans possible. Nothing to do."
        Stop-Transcript
        exit 0
    }
    if (-not $esVersion) {
        Write-Host "WARNING: No parseable Eaglesoft version among $($esEntries.Count) entries - cannot determine live install. No change made."
        Stop-Transcript
        exit 1
    }

    # --- Proof 1 precondition: exactly one entry must claim the live version ---
    $liveEntries = @($esEntries | Where-Object {
        $v = $null
        [version]::TryParse($_.DisplayVersion, [ref]$v) -and $v -eq $esVersion
    })
    if ($liveEntries.Count -ne 1) {
        Write-Host "WARNING: $($liveEntries.Count) ARP entries report the live version $esVersion - ambiguous, no change made."
        Stop-Transcript
        exit 1
    }
    $liveEntry = $liveEntries[0]
    $liveLocation = $liveEntry.InstallLocation
    Write-Host "Live install: $($liveEntry.DisplayName) $($liveEntry.DisplayVersion) ($($liveEntry.PSChildName)) at '$liveLocation'"

    # --- Proofs 1 + 2: lower version AND shared InstallLocation ---
    $orphans = @($esEntries | Where-Object {
        $v = $null
        $_.PSChildName -ne $liveEntry.PSChildName -and
        [version]::TryParse($_.DisplayVersion, [ref]$v) -and
        $v -lt $esVersion -and
        -not [string]::IsNullOrWhiteSpace($_.InstallLocation) -and
        -not [string]::IsNullOrWhiteSpace($liveLocation) -and
        ($_.InstallLocation.TrimEnd('\') -eq $liveLocation.TrimEnd('\'))
    })

    # Surface entries that are extra but NOT provable orphans (different InstallLocation,
    # unparseable version, etc.) - these need human eyes, never automatic deletion.
    $unproven = @($esEntries | Where-Object {
        $_.PSChildName -ne $liveEntry.PSChildName -and
        ($orphans | ForEach-Object { $_.PSChildName }) -notcontains $_.PSChildName
    })
    foreach ($u in $unproven) {
        Write-Host "WARNING: Extra entry NOT provable as orphan (version/InstallLocation mismatch): $($u.DisplayName) $($u.DisplayVersion) ($($u.PSChildName)) at '$($u.InstallLocation)'. Investigate manually - possible real parallel install."
        $exitCode = 1
    }

    if ($orphans.Count -eq 0) {
        Write-Host "No provable orphans among $($esEntries.Count) Eaglesoft entries. No change made."
        Stop-Transcript
        exit $exitCode
    }

    # --- Proof 3: binary on disk at the shared location reports the live version ---
    # Major.Minor.Build comparison handles ARP "25.00.08" vs FileVersion "25.0.8.0".
    $esExe = Get-ChildItem -Path $liveLocation -Filter "Eaglesoft.exe" -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $binVersion = $null
    if ($esExe) { [void][version]::TryParse($esExe.VersionInfo.FileVersion, [ref]$binVersion) }
    $binMatchesLive = $binVersion -and
        $binVersion.Major -eq $esVersion.Major -and
        $binVersion.Minor -eq $esVersion.Minor -and
        $binVersion.Build -eq $esVersion.Build

    if (-not $binMatchesLive) {
        Write-Host "WARNING: on-disk Eaglesoft.exe version ($(if ($esExe) { $esExe.VersionInfo.FileVersion } else { 'not found under ' + $liveLocation })) does not confirm live $esVersion - orphan status unproven, no change made."
        Stop-Transcript
        exit 1
    }
    Write-Host "Disk proof: $($esExe.FullName) reports $($esExe.VersionInfo.FileVersion) - matches live $esVersion."

    # --- Remove (or report) proven orphans - registry key delete ONLY ---
    foreach ($orphan in $orphans) {
        $cleanPath = $orphan.PSPath -replace 'Microsoft\.PowerShell\.Core\\Registry::', ''
        if ($env:ReportOnly -eq "1") {
            Write-Host "[ReportOnly] Orphan proven, would remove: $($orphan.DisplayName) $($orphan.DisplayVersion) ($($orphan.PSChildName)) at $cleanPath"
            continue
        }
        Write-Host "Orphan proven: $($orphan.DisplayName) $($orphan.DisplayVersion) ($($orphan.PSChildName)) - shares InstallLocation with live $esVersion."
        Remove-Item -LiteralPath $orphan.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $orphan.PSPath) {
            Write-Host "ERROR: key still present after delete: $cleanPath"
            $exitCode = 1
        } else {
            Write-Host "Removed: $cleanPath"
        }
    }

    Write-Host "Completed with exit code $exitCode."
}
catch {
    Write-Host "CRITICAL: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    $exitCode = 1
}

Stop-Transcript
exit $exitCode