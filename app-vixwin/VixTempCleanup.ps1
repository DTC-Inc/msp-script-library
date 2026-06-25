#Requires -Version 5.1

<#
.SYNOPSIS
    VixTemp Folder Cleanup Script
.DESCRIPTION
    Monitors C:\vixtemp folder size and archives oldest files when threshold exceeded.
    Maintains 5 rotating archive versions for recovery purposes.
    Runs only on workstations, never on servers.
.NOTES
    Version: 1.1.0
    Exit Codes:
        0 = Success (or not applicable - server, no folder, under threshold)
        1 = General failure
        2 = Insufficient disk space
        3 = Archive creation failed
        4 = Lock file conflict (valid instance running)
#>

#region Version
$ScriptVersion = "1.1.2"
#endregion

## ============================================================================
## RMM VARIABLES - SET THESE IN NINJA WHEN DEPLOYING
## ============================================================================
## $RMM = 1                    # Set to 1 when running from RMM
## $RMMScriptPath = ""         # Optional: Custom log path from RMM
## $Description = ""           # Optional: Ticket # or technician initials
## ============================================================================

# Getting input from user if not running from RMM else set variables from RMM.
$ScriptLogName = "VixTempCleanup.log"
if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
} else {
    # Store the logs in the RMMScriptPath if provided
    if ($null -ne $RMMScriptPath -and $RMMScriptPath -ne "") {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
    }
    if ($null -eq $Description -or $Description -eq "") {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    }
}

# Start transcript for RMM logging
Start-Transcript -Path $LogPath -Append
Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host "Script Version: $ScriptVersion"

#region Configuration
$Config = @{
    SourcePath         = "C:\vixtemp"
    ArchivePath        = "C:\vixtemp_archives"
    LogPath            = "C:\ProgramData\VixTempCleanup\Logs"
    DataPath           = "C:\ProgramData\VixTempCleanup"
    LockFile           = "C:\ProgramData\VixTempCleanup\cleanup.lock"
    LastSuccessFile    = "C:\ProgramData\VixTempCleanup\last_success.txt"
    VersionFile        = "C:\ProgramData\VixTempCleanup\version.txt"
    DisableFlag        = "C:\vixtemp_archives\DISABLE_CLEANUP"
    ThresholdMB        = 250
    TargetMB           = 200
    MaxArchives        = 5
    LogRetentionDays   = 30
    MaxLockAgeMinutes  = 5
    OverdueAlertHours  = 24
    DiskSpaceBufferPct = 1.5
    EventSource        = "VixTempCleanup"
    EventLog           = "Application"
}
#endregion

#region Core Functions

function Initialize-Directories {
    # Create all required directories if they don't exist
    $directories = @(
        $Config.ArchivePath,
        $Config.LogPath,
        $Config.DataPath
    )

    foreach ($dir in $directories) {
        if (-not (Test-Path $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
            Write-Log "[INFO] Created directory: $dir"
        }
    }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    # Write to daily log file
    $dailyLogFile = Join-Path $Config.LogPath "VixTempCleanup_$(Get-Date -Format 'yyyy-MM-dd').log"
    Add-Content -Path $dailyLogFile -Value $logEntry -ErrorAction SilentlyContinue

    # Also write to console/transcript
    Write-Host $logEntry
}

function Test-IsServer {
    $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
    $productType = $osInfo.ProductType

    # ProductType: 1 = Workstation, 2 = Domain Controller, 3 = Server
    if ($productType -ne 1) {
        return $true
    }

    if ($osInfo.Caption -match "Server") {
        return $true
    }

    return $false
}

function Test-LockFile {
    if (Test-Path $Config.LockFile) {
        $lockAge = (Get-Date) - (Get-Item $Config.LockFile).LastWriteTime
        if ($lockAge.TotalMinutes -lt $Config.MaxLockAgeMinutes) {
            Write-Log "[INFO] Another instance running (lock age: $([math]::Round($lockAge.TotalSeconds)) seconds). Exiting."
            return $true
        }
        else {
            Write-Log "[WARN] Stale lock file detected (age: $([math]::Round($lockAge.TotalMinutes, 1)) minutes). Removing." -Level WARN
            Remove-Item $Config.LockFile -Force
            return $false
        }
    }
    return $false
}

function New-LockFile {
    $null = New-Item -Path $Config.LockFile -ItemType File -Force
    Set-Content -Path $Config.LockFile -Value (Get-Date -Format "o")
}

function Remove-LockFile {
    if (Test-Path $Config.LockFile) {
        Remove-Item $Config.LockFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-SufficientDiskSpace {
    param([int64]$RequiredBytes)

    $drive = Get-PSDrive -Name "C"
    $freeBytes = $drive.Free
    $requiredWithBuffer = [int64]($RequiredBytes * $Config.DiskSpaceBufferPct)

    $freeMB = [math]::Round($freeBytes / 1MB, 2)
    $requiredMB = [math]::Round($requiredWithBuffer / 1MB, 2)

    if ($freeBytes -lt $requiredWithBuffer) {
        return @{
            Success = $false
            Message = "Insufficient disk space. Free: ${freeMB}MB, Required: ${requiredMB}MB"
            FreeMB = $freeMB
            RequiredMB = $requiredMB
        }
    }

    return @{
        Success = $true
        FreeMB = $freeMB
        RequiredMB = $requiredMB
    }
}

function Get-FolderSizeMB {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return 0 }

    $sizeBytes = (Get-ChildItem $Path -Recurse -File -ErrorAction SilentlyContinue |
                  Measure-Object -Property Length -Sum).Sum

    if ($null -eq $sizeBytes) { return 0 }

    return [math]::Round($sizeBytes / 1MB, 2)
}

function Get-UnixTimestamp {
    return [int][double]::Parse((Get-Date -UFormat %s))
}

function Get-ArchivePath {
    $timestamp = Get-UnixTimestamp
    $friendlyDate = Get-Date -Format "yyyy-MM-dd_HHmm"
    $archiveName = "vixtemp_archive_${timestamp}_${friendlyDate}.zip"
    return Join-Path $Config.ArchivePath $archiveName
}

function Get-FilesToArchive {
    param(
        [string]$SourcePath,
        [int64]$TargetSizeBytes
    )

    $files = Get-ChildItem $SourcePath -Recurse -File -ErrorAction SilentlyContinue
    if ($null -eq $files -or $files.Count -eq 0) {
        return @()
    }

    $currentSize = ($files | Measure-Object -Property Length -Sum).Sum
    $bytesToRemove = $currentSize - $TargetSizeBytes

    if ($bytesToRemove -le 0) {
        return @()
    }

    $filesToArchive = @()
    $accumulatedSize = 0

    # Sort by LastWriteTime ascending (oldest first)
    $allFiles = $files | Sort-Object LastWriteTime

    foreach ($file in $allFiles) {
        if ($accumulatedSize -ge $bytesToRemove) { break }
        $filesToArchive += $file
        $accumulatedSize += $file.Length
    }

    return $filesToArchive
}

function New-VixTempArchive {
    param(
        [System.IO.FileInfo[]]$Files,
        [string]$ArchivePath,
        [string]$SourceRoot
    )

    try {
        $archivedFiles = @()
        $originalSizeBytes = 0
        $filePaths = @()

        foreach ($file in $Files) {
            try {
                # Test if file is accessible
                $null = [System.IO.File]::OpenRead($file.FullName).Close()
                $filePaths += $file.FullName
                $archivedFiles += $file
                $originalSizeBytes += $file.Length
            }
            catch {
                Write-Log "[WARN] Could not access file (skipping): $($file.FullName) - $_" -Level WARN
            }
        }

        if ($filePaths.Count -eq 0) {
            return @{
                Success = $false
                Error = "No files were accessible for archiving"
            }
        }

        # Use Compress-Archive cmdlet (built into PowerShell 5.0+)
        # Note: Compress-Archive doesn't preserve folder structure from different paths,
        # but since all files are in C:\vixtemp, this is acceptable
        Compress-Archive -Path $filePaths -DestinationPath $ArchivePath -CompressionLevel Optimal -Force -ErrorAction Stop

        # Get compressed size
        $compressedSizeBytes = 0
        if (Test-Path $ArchivePath) {
            $compressedSizeBytes = (Get-Item $ArchivePath).Length
        }

        return @{
            Success = $true
            ArchivedCount = $archivedFiles.Count
            ArchivedFiles = $archivedFiles
            ArchivePath = $ArchivePath
            OriginalSizeBytes = $originalSizeBytes
            CompressedSizeBytes = $compressedSizeBytes
        }
    }
    catch {
        if (Test-Path $ArchivePath) {
            Remove-Item $ArchivePath -Force -ErrorAction SilentlyContinue
        }

        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Remove-ArchivedFiles {
    param([System.IO.FileInfo[]]$ArchivedFiles)

    $deletedCount = 0
    $failedCount = 0

    foreach ($file in $ArchivedFiles) {
        try {
            if (Test-Path $file.FullName) {
                Remove-Item $file.FullName -Force -ErrorAction Stop
                $deletedCount++
            }
        }
        catch {
            Write-Log "[WARN] Could not delete: $($file.FullName) - $_" -Level WARN
            $failedCount++
            # Continue with other files - don't fail entire operation
        }
    }

    # Clean up empty subdirectories
    Get-ChildItem $Config.SourcePath -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0 } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    return @{
        DeletedCount = $deletedCount
        FailedCount = $failedCount
    }
}

function Remove-OldArchives {
    param(
        [string]$ArchiveDirectory,
        [int]$KeepCount = 5
    )

    $archives = Get-ChildItem $ArchiveDirectory -Filter "vixtemp_archive_*.zip" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending  # Unix timestamp ensures correct sort

    if ($null -eq $archives) { return }

    if ($archives.Count -gt $KeepCount) {
        $archivesToDelete = $archives | Select-Object -Skip $KeepCount

        foreach ($old in $archivesToDelete) {
            try {
                Remove-Item $old.FullName -Force
                Write-Log "[INFO] Rotated out archive: $($old.Name)"
            }
            catch {
                Write-Log "[WARN] Could not remove old archive: $($old.Name) - $_" -Level WARN
            }
        }
    }

    $remainingCount = [math]::Min($archives.Count, $KeepCount)
    Write-Log "[INFO] Archive count after rotation: $remainingCount"
}

function Remove-OldLogs {
    param(
        [string]$LogDirectory,
        [int]$RetentionDays = 30
    )

    Get-ChildItem $LogDirectory -Filter "VixTempCleanup_*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Update-LastSuccess {
    Set-Content -Path $Config.LastSuccessFile -Value (Get-Date -Format "o") -Force
}

function Get-LastSuccess {
    if (Test-Path $Config.LastSuccessFile) {
        try {
            $timestamp = Get-Content $Config.LastSuccessFile -ErrorAction Stop
            return [DateTime]::Parse($timestamp)
        }
        catch {
            return $null
        }
    }
    return $null
}

function Test-CleanupOverdue {
    param([int]$MaxHours = 24)

    $lastSuccess = Get-LastSuccess
    if ($null -eq $lastSuccess) {
        return $true  # Never succeeded - will alert on first run (expected behavior)
    }

    $hoursSinceSuccess = ((Get-Date) - $lastSuccess).TotalHours
    return $hoursSinceSuccess -gt $MaxHours
}

function Initialize-EventLog {
    if (-not [System.Diagnostics.EventLog]::SourceExists($Config.EventSource)) {
        try {
            New-EventLog -LogName $Config.EventLog -Source $Config.EventSource -ErrorAction Stop
        }
        catch {
            Write-Log "[WARN] Could not create event log source: $_" -Level WARN
        }
    }
}

function Write-NinjaAlert {
    param(
        [string]$Message,
        [ValidateSet('Error','Warning','Information')]
        [string]$Severity = 'Error'
    )

    $eventType = switch ($Severity) {
        'Error'       { [System.Diagnostics.EventLogEntryType]::Error }
        'Warning'     { [System.Diagnostics.EventLogEntryType]::Warning }
        'Information' { [System.Diagnostics.EventLogEntryType]::Information }
    }

    $eventId = switch ($Severity) {
        'Error'       { 1001 }
        'Warning'     { 1002 }
        'Information' { 1000 }
    }

    try {
        Write-EventLog -LogName $Config.EventLog -Source $Config.EventSource -EventId $eventId -EntryType $eventType -Message $Message
    }
    catch {
        Write-Log "[WARN] Could not write to event log: $_" -Level WARN
    }

    Write-Log "[$Severity] NINJA ALERT: $Message"
}

function Update-VersionFile {
    Set-Content -Path $Config.VersionFile -Value $ScriptVersion -Force
}

function Invoke-OverdueCheck {
    if (Test-CleanupOverdue -MaxHours $Config.OverdueAlertHours) {
        $lastSuccess = Get-LastSuccess
        $lastStr = if ($lastSuccess) { $lastSuccess.ToString("yyyy-MM-dd HH:mm") } else { "never" }
        $currentSize = if (Test-Path $Config.SourcePath) {
            Get-FolderSizeMB -Path $Config.SourcePath
        } else {
            "N/A (folder not present)"
        }
        Write-NinjaAlert -Message "VixTemp cleanup hasn't succeeded since $lastStr on $env:COMPUTERNAME. Current folder size: $currentSize MB" -Severity Warning
    }
}

#endregion

#region Main Execution

# Initialize directories first (creates paths if they don't exist)
Initialize-Directories

# Update version file on every run
Update-VersionFile

Write-Log "[INFO] ========================================"
Write-Log "[INFO] VixTemp Cleanup Script v$ScriptVersion started"
Write-Log "[INFO] Hostname: $env:COMPUTERNAME"
Write-Log "[INFO] Description: $Description"

# 1. Server check (logs and exits if server)
if (Test-IsServer) {
    $productType = (Get-CimInstance Win32_OperatingSystem).ProductType
    Write-Log "[INFO] Server OS detected (ProductType=$productType). Script only runs on workstations. Exiting."
    Invoke-OverdueCheck
    Write-Log "[INFO] ========================================"
    Stop-Transcript
    exit 0
}
Write-Log "[INFO] Workstation detected. Proceeding."

# 2. Initialize event log
Initialize-EventLog

# 3. Check disable flag
if (Test-Path $Config.DisableFlag) {
    Write-Log "[INFO] Cleanup disabled by override file. Exiting."
    Invoke-OverdueCheck
    Write-Log "[INFO] ========================================"
    Stop-Transcript
    exit 0
}

# 4. Lock file check (exits without overdue check - another instance is running)
if (Test-LockFile) {
    Write-Log "[INFO] ========================================"
    Stop-Transcript
    exit 4
}
New-LockFile
Write-Log "[INFO] Lock file created"

try {
    # 5. Check source folder exists
    if (-not (Test-Path $Config.SourcePath)) {
        Write-Log "[INFO] C:\vixtemp folder not present on this workstation. Exiting."
        Update-LastSuccess
        Invoke-OverdueCheck
        Remove-LockFile
        Write-Log "[INFO] Lock file removed"
        Write-Log "[INFO] ========================================"
        Stop-Transcript
        exit 0
    }

    # 6. Check folder size
    $currentSizeMB = Get-FolderSizeMB -Path $Config.SourcePath
    Write-Log "[INFO] Current folder size: $currentSizeMB MB"

    if ($currentSizeMB -le $Config.ThresholdMB) {
        Write-Log "[INFO] Folder size ($currentSizeMB MB) below threshold ($($Config.ThresholdMB) MB). No action required."
        Update-LastSuccess
        Invoke-OverdueCheck
        Remove-LockFile
        Write-Log "[INFO] Lock file removed"
        Write-Log "[INFO] ========================================"
        Stop-Transcript
        exit 0
    }

    Write-Log "[INFO] Folder size exceeds threshold ($($Config.ThresholdMB) MB). Initiating cleanup..."
    $targetReductionMB = [math]::Round($currentSizeMB - $Config.TargetMB, 2)
    Write-Log "[INFO] Target reduction: $targetReductionMB MB to reach $($Config.TargetMB) MB target"

    # 7. Get files to archive
    $filesToArchive = Get-FilesToArchive -SourcePath $Config.SourcePath -TargetSizeBytes ($Config.TargetMB * 1MB)

    # 7a. Check if any files selected (handles all-locked or empty scenario)
    if ($null -eq $filesToArchive -or $filesToArchive.Count -eq 0) {
        Write-Log "[WARN] All files locked or no files eligible for archival. Skipping archive creation." -Level WARN
        Update-LastSuccess  # Still consider this a "success" - we tried, nothing to archive
        Invoke-OverdueCheck
        Remove-LockFile
        Write-Log "[INFO] Lock file removed"
        Write-Log "[INFO] ========================================"
        Stop-Transcript
        exit 0
    }

    $archiveSizeBytes = ($filesToArchive | Measure-Object -Property Length -Sum).Sum
    $archiveSizeMB = [math]::Round($archiveSizeBytes / 1MB, 2)
    Write-Log "[INFO] Selected $($filesToArchive.Count) files for archival ($archiveSizeMB MB)"

    $oldestFile = $filesToArchive | Sort-Object LastWriteTime | Select-Object -First 1
    Write-Log "[INFO] Oldest file: $($oldestFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"

    # 8. Disk space check
    $spaceCheck = Test-SufficientDiskSpace -RequiredBytes $archiveSizeBytes
    if (-not $spaceCheck.Success) {
        Write-Log "[ERROR] $($spaceCheck.Message)" -Level ERROR
        Write-NinjaAlert -Message "VixTemp cleanup failed: $($spaceCheck.Message) on $env:COMPUTERNAME" -Severity Error
        Invoke-OverdueCheck
        Remove-LockFile
        Write-Log "[INFO] Lock file removed"
        Write-Log "[INFO] ========================================"
        Stop-Transcript
        exit 2
    }
    Write-Log "[INFO] Disk space check: $($spaceCheck.FreeMB) GB free, $($spaceCheck.RequiredMB) MB required. OK."

    # 9. Create archive
    $archivePath = Get-ArchivePath
    Write-Log "[INFO] Creating archive: $(Split-Path $archivePath -Leaf)"
    $archiveResult = New-VixTempArchive -Files $filesToArchive -ArchivePath $archivePath -SourceRoot $Config.SourcePath

    if (-not $archiveResult.Success) {
        Write-Log "[ERROR] Archive creation failed: $($archiveResult.Error)" -Level ERROR
        Write-NinjaAlert -Message "VixTemp cleanup failed: Could not create archive. $($archiveResult.Error) on $env:COMPUTERNAME" -Severity Error
        Invoke-OverdueCheck
        Remove-LockFile
        Write-Log "[INFO] Lock file removed"
        Write-Log "[INFO] ========================================"
        Stop-Transcript
        exit 3
    }

    $originalSizeMB = [math]::Round($archiveResult.OriginalSizeBytes / 1MB, 2)
    $compressedSizeMB = [math]::Round($archiveResult.CompressedSizeBytes / 1MB, 2)
    $compressionRatio = if ($archiveResult.OriginalSizeBytes -gt 0) {
        [math]::Round(($archiveResult.CompressedSizeBytes / $archiveResult.OriginalSizeBytes) * 100, 1)
    } else { 0 }

    Write-Log "[INFO] Archive created: $(Split-Path $archivePath -Leaf)"
    Write-Log "[INFO] Archive size: $compressedSizeMB MB ($($archiveResult.ArchivedCount) files, $compressionRatio% of original $originalSizeMB MB)"

    # 10. Delete ONLY archived files
    $deleteResult = Remove-ArchivedFiles -ArchivedFiles $archiveResult.ArchivedFiles
    Write-Log "[INFO] Deleted $($deleteResult.DeletedCount) archived files from C:\vixtemp"
    if ($deleteResult.FailedCount -gt 0) {
        Write-Log "[WARN] Failed to delete $($deleteResult.FailedCount) files (may be locked)" -Level WARN
    }

    # 11. Rotate archives
    Remove-OldArchives -ArchiveDirectory $Config.ArchivePath -KeepCount $Config.MaxArchives

    # 12. Update success timestamp
    Update-LastSuccess
    Write-Log "[INFO] Last success timestamp updated"

    # 13. Log completion
    $finalSizeMB = Get-FolderSizeMB -Path $Config.SourcePath
    Write-Log "[INFO] Post-cleanup folder size: $finalSizeMB MB"
    Write-Log "[INFO] Cleanup completed successfully"
}
catch {
    Write-Log "[ERROR] Unexpected error: $_" -Level ERROR
    Write-NinjaAlert -Message "VixTemp cleanup failed with unexpected error on $env:COMPUTERNAME. Check logs at C:\ProgramData\VixTempCleanup\Logs. Error: $_" -Severity Error
    Invoke-OverdueCheck
}
finally {
    # Cleanup logs and lock
    Remove-OldLogs -LogDirectory $Config.LogPath -RetentionDays $Config.LogRetentionDays
    Remove-LockFile
    Write-Log "[INFO] Lock file removed"
    Write-Log "[INFO] ========================================"
    Stop-Transcript
}

exit 0

#endregion
