<#
.SYNOPSIS
    Storage Growth Monitor - Tracks server storage growth trends over 60 days
    and reports to Ninja RMM custom fields.

.DESCRIPTION
    Collects daily storage metrics from servers (physical Hyper-V hosts and VMs),
    maintains a 60-day rolling history, calculates growth trends using linear
    regression, and updates Ninja RMM custom fields with actionable insights.
    Critical trends trigger Ninja event log entries for automated alerting and
    Halo PSA ticket creation.

    Technical Design Document: Ticket 1123004 - DTC Internal
    Version: 2.5 (Final)

.PARAMETER Verbose
    Enable detailed diagnostic output for troubleshooting.

.EXAMPLE
    .\Storage-Growth-Monitor.ps1
    Run in standard mode (Ninja or Test mode auto-detected).

.EXAMPLE
    .\Storage-Growth-Monitor.ps1 -Verbose
    Run with verbose diagnostic output.
#>

[CmdletBinding()]
param()

# ============================================================================
# CONSTANTS
# ============================================================================
$Script:VERSION = "1.0"
$Script:STORAGE_PATH = "C:\ProgramData\NinjaRMM\StorageMetrics"
$Script:HISTORY_FILE = Join-Path $Script:STORAGE_PATH "storage_history.json"
$Script:BACKUP_FILE = Join-Path $Script:STORAGE_PATH "storage_history.json.bak"
$Script:LOG_FILE = Join-Path $Script:STORAGE_PATH "storage_monitor.log"
$Script:EVENT_SOURCE = "StorageGrowthMonitor"
$Script:RETENTION_DAYS = 65
$Script:LOG_RETENTION_DAYS = 90
$Script:OFFLINE_REMOVAL_DAYS = 30
$Script:MIN_DATA_POINTS = 7
$Script:FULL_CONFIDENCE_POINTS = 30
$Script:MAX_DATA_DRIVES = 3
$Script:DAYS_CAP = 1825
$Script:MIN_DRIVE_SIZE_GB = 1
$Script:CRITICAL_DAYS = 30
$Script:ATTENTION_DAYS_LOW = 30
$Script:ATTENTION_DAYS_HIGH = 90
$Script:CRITICAL_USAGE_PERCENT = 95
$Script:GROWING_THRESHOLD_GB_DAY = 0.1
$Script:EXCLUDED_LABELS = @("Recovery", "EFI", "System Reserved", "SYSTEM", "Windows RE")
$Script:EXCLUDED_FILESYSTEMS = @("FAT", "FAT32", "RAW")
$Script:JSON_VERSION = "1.0"

# Ninja RMM field name constants (Section 10)
$Script:FIELD_SERVER_STATUS = "Server Storage Status"
$Script:FIELD_OS_STATUS = "OS Drive Status"
$Script:FIELD_OS_GROWTH = "OS Drive GB per Month"
$Script:FIELD_OS_DAYS = "OS Drive Days Until Full"
$Script:FIELD_DATA_LETTER = "Data Drive {0} Letter"
$Script:FIELD_DATA_STATUS = "Data Drive {0} Status"
$Script:FIELD_DATA_GROWTH = "Data Drive {0} GB per Month"
$Script:FIELD_DATA_DAYS = "Data Drive {0} Days Until Full"

# ============================================================================
# LOGGING
# ============================================================================
$Script:LogBuffer = [System.Collections.ArrayList]::new()

function Get-TimestampString {
    $now = Get-Date
    $tz = [System.TimeZoneInfo]::Local
    $tzAbbr = if ($now.IsDaylightSavingTime()) {
        $dn = $tz.DaylightName
        ($dn -split '\s' | ForEach-Object { $_[0] }) -join ''
    } else {
        $sn = $tz.StandardName
        ($sn -split '\s' | ForEach-Object { $_[0] }) -join ''
    }
    return "[{0} {1}]" -f ($now.ToString("yyyy-MM-dd HH:mm:ss")), $tzAbbr
}

function Write-Log {
    param(
        [string]$Message,
        [switch]$IsVerbose
    )
    if ($IsVerbose -and $VerbosePreference -ne 'Continue') { return }

    $ts = Get-TimestampString
    $line = if ($Message -eq '') {
        "$ts "
    } elseif ($IsVerbose) {
        "$ts [VERBOSE] $Message"
    } else {
        "$ts $Message"
    }

    Write-Host $line
    [void]$Script:LogBuffer.Add($line)
}

function Write-VerboseLog {
    param([string]$Message)
    if ($VerbosePreference -eq 'Continue') {
        Write-Log -Message $Message -IsVerbose
    }
}

# ============================================================================
# LOG FILE MANAGEMENT (Section 14)
# ============================================================================
function Save-LogFile {
    try {
        $existingLines = @()
        if (Test-Path $Script:LOG_FILE) {
            $existingLines = @(Get-Content -Path $Script:LOG_FILE -ErrorAction SilentlyContinue)
        }

        # Prune entries older than 90 days
        $cutoff = (Get-Date).AddDays(-$Script:LOG_RETENTION_DAYS)
        $prunedLines = [System.Collections.ArrayList]::new()
        $removedCount = 0

        foreach ($line in $existingLines) {
            if ($line -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
                $parsedDate = $null
                if ([DateTime]::TryParseExact($Matches[1], "yyyy-MM-dd HH:mm:ss", $null, [System.Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
                    if ($parsedDate -lt $cutoff) {
                        $removedCount++
                        continue
                    }
                }
            }
            # Keep line if timestamp unparseable or within retention
            [void]$prunedLines.Add($line)
        }

        if ($removedCount -gt 0) {
            Write-VerboseLog "Log file pruning: $removedCount entries removed (older than $($Script:LOG_RETENTION_DAYS) days)"
        }

        # Append new entries
        foreach ($line in $Script:LogBuffer) {
            [void]$prunedLines.Add($line)
        }

        $prunedLines | Set-Content -Path $Script:LOG_FILE -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Host "$(Get-TimestampString) ERROR: Failed to write log file: $_"
    }
}

# ============================================================================
# SAFE TIMESTAMP PARSING HELPER
# ============================================================================
function ConvertTo-SafeDateTime {
    <#
    .SYNOPSIS
        Safely parses a timestamp string, returning $null on failure instead of throwing.
    #>
    param([string]$Timestamp)

    $parsed = $null
    if ([DateTime]::TryParse($Timestamp, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

# ============================================================================
# JSON PERSISTENCE (Section 6)
# ============================================================================
function New-EmptyHistory {
    return [ordered]@{
        version              = $Script:JSON_VERSION
        deviceId             = $env:COMPUTERNAME
        lastUpdated          = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        excessDriveAlertSent = $false
        drives               = [ordered]@{}
    }
}

function Import-HistoryFromFile {
    <#
    .SYNOPSIS
        Attempts to parse a history JSON file. Returns $null on failure.
    #>
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) { return $null }

    try {
        $content = Get-Content -Path $FilePath -Raw -Encoding UTF8 -ErrorAction Stop
        $data = $content | ConvertFrom-Json -ErrorAction Stop

        if (-not $data.version -or -not $data.drives) {
            throw "Invalid JSON structure - missing version or drives"
        }

        $history = [ordered]@{
            version              = $data.version
            deviceId             = if ($data.deviceId) { $data.deviceId } else { $env:COMPUTERNAME }
            lastUpdated          = if ($data.lastUpdated) { $data.lastUpdated } else { (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss") }
            excessDriveAlertSent = if ($null -ne $data.excessDriveAlertSent) { [bool]$data.excessDriveAlertSent } else { $false }
            drives               = [ordered]@{}
        }

        foreach ($prop in $data.drives.PSObject.Properties) {
            $driveLetter = $prop.Name
            $driveData = $prop.Value

            $historyEntries = [System.Collections.ArrayList]::new()
            if ($driveData.history) {
                foreach ($entry in $driveData.history) {
                    [void]$historyEntries.Add([ordered]@{
                        timestamp    = $entry.timestamp
                        usedGB       = [double]$entry.usedGB
                        freeGB       = [double]$entry.freeGB
                        usagePercent = [double]$entry.usagePercent
                    })
                }
            }

            $history.drives[$driveLetter] = [ordered]@{
                volumeLabel = if ($driveData.volumeLabel) { $driveData.volumeLabel } else { "" }
                totalSizeGB = [double]$driveData.totalSizeGB
                driveType   = if ($driveData.driveType) { $driveData.driveType } else { "Data" }
                alertSent   = if ($null -ne $driveData.alertSent) { [bool]$driveData.alertSent } else { $false }
                status      = if ($driveData.status) { $driveData.status } else { "Online" }
                lastSeen    = if ($driveData.lastSeen) { $driveData.lastSeen } else { (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss") }
                history     = $historyEntries
            }
        }

        return $history
    }
    catch {
        return $null
    }
}

function Load-History {
    $maxRetries = 3
    $retryDelay = 5

    if (-not (Test-Path $Script:HISTORY_FILE)) {
        Write-VerboseLog "Existing JSON: No - creating new history"
        return New-EmptyHistory
    }

    $fileInfo = Get-Item $Script:HISTORY_FILE -ErrorAction SilentlyContinue
    Write-VerboseLog "Existing JSON: Yes ($([math]::Round($fileInfo.Length / 1KB)) KB)"

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        $result = Import-HistoryFromFile -FilePath $Script:HISTORY_FILE
        if ($null -ne $result) {
            return $result
        }

        if ($attempt -lt $maxRetries) {
            Write-Log "WARNING: Failed to load history (attempt $attempt/$maxRetries), retrying in ${retryDelay}s..."
            Start-Sleep -Seconds $retryDelay
        }
    }

    # Primary file corrupted after all retries - attempt backup recovery
    if (Test-Path $Script:BACKUP_FILE) {
        Write-Log "WARNING: Primary history corrupted. Attempting backup recovery..."
        $backupResult = Import-HistoryFromFile -FilePath $Script:BACKUP_FILE
        if ($null -ne $backupResult) {
            Write-Log "Backup recovery successful - restored from $($Script:BACKUP_FILE)"
            return $backupResult
        }
        Write-Log "WARNING: Backup file also corrupted."
    }

    # Both primary and backup failed - rename corrupted file and start fresh
    Write-Log "WARNING: History unrecoverable after $maxRetries attempts. Renaming and starting fresh."
    $corruptedPath = $Script:HISTORY_FILE + ".corrupted"
    try {
        Move-Item -Path $Script:HISTORY_FILE -Destination $corruptedPath -Force -ErrorAction Stop
    }
    catch {
        Write-Log "WARNING: Could not rename corrupted file: $_"
    }
    return New-EmptyHistory
}

function Save-History {
    param([hashtable]$History)

    # Backup existing file before overwriting
    if (Test-Path $Script:HISTORY_FILE) {
        try {
            Copy-Item -Path $Script:HISTORY_FILE -Destination $Script:BACKUP_FILE -Force -ErrorAction Stop
        }
        catch {
            Write-Log "WARNING: Could not create backup: $_"
        }
    }

    $History.lastUpdated = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")

    # Atomic write: write to temp file first, then rename to prevent corruption
    $tempFile = $Script:HISTORY_FILE + ".tmp"

    try {
        $History | ConvertTo-Json -Depth 10 | Set-Content -Path $tempFile -Encoding UTF8 -ErrorAction Stop
        Move-Item -Path $tempFile -Destination $Script:HISTORY_FILE -Force -ErrorAction Stop

        $totalPoints = 0
        $driveCount = 0
        foreach ($drive in $History.drives.Values) {
            $driveCount++
            $totalPoints += $drive.history.Count
        }
        Write-Log ([char]0x2713 + " History file saved ($driveCount drives, $totalPoints data points)")
    }
    catch {
        Write-Log "ERROR: Failed to save history file: $_"
        # Clean up temp file if it exists
        if (Test-Path $tempFile) {
            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================================
# DRIVE DISCOVERY & FILTERING (Section 5)
# ============================================================================
function Get-FilteredDrives {
    # Detect OS drive (Section 5.3)
    $osDriveLetter = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).SystemDrive
    if (-not $osDriveLetter) {
        Write-Log "WARNING: Could not detect OS drive, falling back to C:"
        $osDriveLetter = "C:"
    }
    Write-VerboseLog "OS Drive detected: $osDriveLetter"

    # Primary source - Win32_LogicalDisk (Section 5.1)
    $logicalDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop)
    Write-VerboseLog "Drive Discovery: $($logicalDisks.Count) drives found"

    # Secondary source - Win32_Volume for filtering metadata only (Section 5.1)
    $volumes = $null
    try {
        $volumes = @(Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop)
        Write-VerboseLog "Win32_Volume query: Success"
    }
    catch {
        Write-Log "WARNING: Win32_Volume query failed - continuing with LogicalDisk only"
        Write-VerboseLog "Win32_Volume query: Failed - $_"
    }

    $filteredDrives = [System.Collections.ArrayList]::new()

    foreach ($disk in $logicalDisks) {
        $letter = $disk.DeviceID  # e.g., "C:"
        $sizeGB = [math]::Round($disk.Size / 1GB, 3)
        $label = $disk.VolumeName

        # Find matching volume for additional metadata
        $matchingVolume = $null
        if ($volumes) {
            $matchingVolume = $volumes | Where-Object {
                $_.DriveLetter -eq $letter
            } | Select-Object -First 1
        }

        $fileSystem = if ($matchingVolume -and $matchingVolume.FileSystem) {
            $matchingVolume.FileSystem
        } else { "" }

        # Use volume label from Volume if LogicalDisk doesn't have one
        if (-not $label -and $matchingVolume -and $matchingVolume.Label) {
            $label = $matchingVolume.Label
        }

        # --- Exclusion checks (Section 5.2) ---

        # Size < 1 GB
        if ($sizeGB -lt $Script:MIN_DRIVE_SIZE_GB) {
            Write-VerboseLog "  $letter DriveType=3 Size=${sizeGB}GB - EXCLUDED (Size < 1GB)"
            continue
        }

        # Excluded volume labels
        $labelExcluded = $false
        if ($label) {
            foreach ($excludedLabel in $Script:EXCLUDED_LABELS) {
                if ($label -ieq $excludedLabel) {
                    Write-VerboseLog "  $letter DriveType=3 Size=${sizeGB}GB Label=`"$label`" - EXCLUDED ($excludedLabel partition)"
                    $labelExcluded = $true
                    break
                }
            }
        }
        if ($labelExcluded) { continue }

        # Excluded file systems (FAT, FAT32, RAW)
        if ($fileSystem -and $Script:EXCLUDED_FILESYSTEMS -contains $fileSystem) {
            Write-VerboseLog "  $letter DriveType=3 Size=${sizeGB}GB - EXCLUDED (FileSystem: $fileSystem)"
            continue
        }

        # Drive passed all filters - classify and collect metrics
        $isOS = ($letter -eq $osDriveLetter)
        $driveType = if ($isOS) { "OS" } else { "Data" }

        Write-VerboseLog "  $letter DriveType=3 Size=${sizeGB}GB - INCLUDED ($driveType)"

        $usedBytes = $disk.Size - $disk.FreeSpace
        $usedGB = [math]::Round($usedBytes / 1GB, 3)
        $freeGB = [math]::Round($disk.FreeSpace / 1GB, 3)
        $usagePercent = if ($disk.Size -gt 0) {
            [math]::Round(($usedBytes / $disk.Size) * 100, 2)
        } else { 0 }

        Write-VerboseLog "Drive $letter Raw values - Total: $($sizeGB.ToString('F3')) Used: $($usedGB.ToString('F3')) Free: $($freeGB.ToString('F3')) Percent: $($usagePercent.ToString('F3'))%"

        [void]$filteredDrives.Add(@{
            Letter       = $letter
            VolumeLabel  = if ($label) { $label } else { "" }
            TotalSizeGB  = $sizeGB
            UsedGB       = $usedGB
            FreeGB       = $freeGB
            UsagePercent = $usagePercent
            DriveType    = $driveType
            IsOS         = $isOS
        })
    }

    return $filteredDrives
}

# ============================================================================
# HISTORY UPDATE & PRUNING (Section 6)
# ============================================================================
function Update-History {
    param(
        [hashtable]$History,
        [array]$CurrentDrives
    )

    $now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    $cutoffDate = (Get-Date).AddDays(-$Script:RETENTION_DAYS)
    $visibleLetters = @($CurrentDrives | ForEach-Object { $_.Letter })

    # Update/add visible drives
    foreach ($drive in $CurrentDrives) {
        $letter = $drive.Letter

        if (-not $History.drives.ContainsKey($letter)) {
            # New drive - create entry
            $History.drives[$letter] = [ordered]@{
                volumeLabel = $drive.VolumeLabel
                totalSizeGB = $drive.TotalSizeGB
                driveType   = $drive.DriveType
                alertSent   = $false
                status      = "Online"
                lastSeen    = $now
                history     = [System.Collections.ArrayList]::new()
            }
        }
        else {
            # Existing drive - update metadata
            $existingDrive = $History.drives[$letter]
            $existingDrive.status = "Online"
            $existingDrive.lastSeen = $now
            $existingDrive.driveType = $drive.DriveType
            $existingDrive.volumeLabel = $drive.VolumeLabel

            # Detect disk resize (Section 5.5)
            if ($existingDrive.totalSizeGB -ne $drive.TotalSizeGB) {
                Write-Log "Drive ${letter}: disk size changed from $($existingDrive.totalSizeGB) GB to $($drive.TotalSizeGB) GB"
                Write-VerboseLog "Drive ${letter}: Size change detected - Old: $($existingDrive.totalSizeGB) GB, New: $($drive.TotalSizeGB) GB"
                $existingDrive.totalSizeGB = $drive.TotalSizeGB
            }
        }

        # Append new data point
        [void]$History.drives[$letter].history.Add([ordered]@{
            timestamp    = $now
            usedGB       = $drive.UsedGB
            freeGB       = $drive.FreeGB
            usagePercent = $drive.UsagePercent
        })

        # Prune entries older than 65-day retention window (defensive parsing)
        $driveHistory = $History.drives[$letter].history
        $beforeCount = $driveHistory.Count
        $prunedHistory = [System.Collections.ArrayList]::new()
        foreach ($entry in $driveHistory) {
            $entryDate = ConvertTo-SafeDateTime -Timestamp $entry.timestamp
            if ($null -eq $entryDate) {
                Write-VerboseLog "Drive ${letter}: Skipping entry with unparseable timestamp: $($entry.timestamp)"
                continue
            }
            if ($entryDate -ge $cutoffDate) {
                [void]$prunedHistory.Add($entry)
            }
        }
        $History.drives[$letter].history = $prunedHistory
        $afterCount = $prunedHistory.Count

        if ($beforeCount -ne $afterCount) {
            Write-VerboseLog "Drive ${letter}: Pruned $($beforeCount - $afterCount) entries older than $($Script:RETENTION_DAYS) days"
        }

        if ($prunedHistory.Count -gt 0) {
            $oldest = $prunedHistory[0].timestamp.Substring(0, 10)
            $newest = $prunedHistory[$prunedHistory.Count - 1].timestamp.Substring(0, 10)
            Write-VerboseLog "Drive ${letter}: History - $($prunedHistory.Count) points loaded, $afterCount after pruning (oldest: $oldest, newest: $newest)"
        }
    }

    # Handle drives in history that are NOT currently visible (Section 7)
    $drivesToRemove = [System.Collections.ArrayList]::new()

    foreach ($letter in @($History.drives.Keys)) {
        if ($letter -notin $visibleLetters) {
            $driveData = $History.drives[$letter]

            if ($driveData.status -ne "Offline") {
                Write-VerboseLog "Drive ${letter}: No longer visible - marking Offline"
                $driveData.status = "Offline"
            }

            # Remove if offline > 30 days (Section 7.1) - defensive parsing
            if ($driveData.lastSeen) {
                $lastSeenDate = ConvertTo-SafeDateTime -Timestamp $driveData.lastSeen
                if ($null -ne $lastSeenDate) {
                    $daysOffline = ((Get-Date) - $lastSeenDate).TotalDays
                    if ($daysOffline -gt $Script:OFFLINE_REMOVAL_DAYS) {
                        Write-Log "Drive ${letter}: Offline for $([math]::Round($daysOffline, 0)) days - removing from history"
                        [void]$drivesToRemove.Add($letter)
                    }
                }
                else {
                    Write-VerboseLog "Drive ${letter}: Unparseable lastSeen timestamp: $($driveData.lastSeen)"
                }
            }
        }
    }

    foreach ($letter in $drivesToRemove) {
        $History.drives.Remove($letter)
    }

    return $History
}

# ============================================================================
# LINEAR REGRESSION (Section 8)
# ============================================================================
function Get-LinearRegression {
    param(
        [System.Collections.ArrayList]$HistoryData
    )

    $n = $HistoryData.Count
    if ($n -lt 2) {
        return @{ Slope = 0; Intercept = 0; RSquared = 0 }
    }

    # Convert timestamps to days from first measurement (Section 8.1) - defensive parsing
    $firstTimestamp = ConvertTo-SafeDateTime -Timestamp $HistoryData[0].timestamp
    if ($null -eq $firstTimestamp) {
        Write-VerboseLog "Linear regression: Cannot parse first timestamp, returning zero slope"
        return @{ Slope = 0; Intercept = 0; RSquared = 0 }
    }

    $sumX = 0.0
    $sumY = 0.0
    $sumXY = 0.0
    $sumX2 = 0.0
    $sumY2 = 0.0
    $validPoints = 0

    foreach ($point in $HistoryData) {
        $pointDate = ConvertTo-SafeDateTime -Timestamp $point.timestamp
        if ($null -eq $pointDate) { continue }

        $x = ($pointDate - $firstTimestamp).TotalDays
        $y = [double]$point.usedGB

        $sumX += $x
        $sumY += $y
        $sumXY += ($x * $y)
        $sumX2 += ($x * $x)
        $sumY2 += ($y * $y)
        $validPoints++
    }

    if ($validPoints -lt 2) {
        return @{ Slope = 0; Intercept = 0; RSquared = 0 }
    }

    # OLS formula (Section 8.3)
    $denominator = ($validPoints * $sumX2) - ($sumX * $sumX)
    if ([math]::Abs($denominator) -lt 1e-10) {
        return @{ Slope = 0; Intercept = $sumY / $validPoints; RSquared = 0 }
    }

    $slope = (($validPoints * $sumXY) - ($sumX * $sumY)) / $denominator
    $intercept = ($sumY - ($slope * $sumX)) / $validPoints

    # Calculate R-squared for trend confidence
    $meanY = $sumY / $validPoints
    $ssTot = $sumY2 - ($validPoints * $meanY * $meanY)
    $ssRes = 0.0
    foreach ($point in $HistoryData) {
        $pointDate = ConvertTo-SafeDateTime -Timestamp $point.timestamp
        if ($null -eq $pointDate) { continue }

        $x = ($pointDate - $firstTimestamp).TotalDays
        $y = [double]$point.usedGB
        $predicted = $slope * $x + $intercept
        $ssRes += ($y - $predicted) * ($y - $predicted)
    }
    $rSquared = if ($ssTot -gt 0) { 1 - ($ssRes / $ssTot) } else { 0 }

    return @{
        Slope     = $slope       # GB per day
        Intercept = $intercept
        RSquared  = [math]::Round($rSquared, 2)
    }
}

# ============================================================================
# TREND CALCULATION & STATUS CLASSIFICATION (Sections 8, 9)
# ============================================================================
function Get-DriveAnalysis {
    param(
        [hashtable]$DriveData,
        [string]$DriveLetter
    )

    $result = @{
        Letter          = $DriveLetter
        VolumeLabel     = $DriveData.volumeLabel
        TotalSizeGB     = $DriveData.totalSizeGB
        DriveType       = $DriveData.driveType
        Status          = ""
        GBPerMonth      = ""
        DaysUntilFull   = ""
        AlertSent       = $DriveData.alertSent
        DriveStatus     = $DriveData.status
        IsLimited       = $false
        NumericDays     = $null
        RawGrowthPerDay = 0
        CurrentUsedGB   = 0
        CurrentFreeGB   = 0
        CurrentPercent  = 0
    }

    # Handle offline drives (Section 7.2)
    if ($DriveData.status -eq "Offline") {
        $result.Status = "Offline"
        $result.GBPerMonth = "OFFLINE"
        $result.DaysUntilFull = "OFFLINE"
        return $result
    }

    $pointCount = $DriveData.history.Count

    # Populate current metrics from latest data point if available
    if ($pointCount -gt 0) {
        $latest = $DriveData.history[$pointCount - 1]
        $result.CurrentUsedGB = [double]$latest.usedGB
        $result.CurrentFreeGB = [double]$latest.freeGB
        $result.CurrentPercent = [double]$latest.usagePercent
    }

    # Check minimum data points (Section 8.2)
    if ($pointCount -lt $Script:MIN_DATA_POINTS) {
        $result.Status = "Insufficient Data"
        $result.GBPerMonth = "Insufficient Data"
        $result.DaysUntilFull = "Insufficient Data"
        Write-VerboseLog "Drive ${DriveLetter}: $pointCount data points - Insufficient Data"
        return $result
    }

    $isLimited = $pointCount -lt $Script:FULL_CONFIDENCE_POINTS
    $result.IsLimited = $isLimited

    # Run linear regression (Section 8.1)
    $regression = Get-LinearRegression -HistoryData $DriveData.history
    $dailyGrowth = $regression.Slope
    $monthlyGrowth = [math]::Round($dailyGrowth * 30, 3)
    $result.RawGrowthPerDay = $dailyGrowth

    Write-VerboseLog "Drive ${DriveLetter}: Regression - slope=$([math]::Round($dailyGrowth, 4)) GB/day, R`u{00B2}=$($regression.RSquared)"

    $result.GBPerMonth = $monthlyGrowth.ToString("F3")

    # Get current free space for days-until-full calculation
    $currentFreeGB = $result.CurrentFreeGB
    $currentUsagePercent = $result.CurrentPercent

    # Calculate days until full (Section 8.4, 9.1)
    if ($dailyGrowth -le 0) {
        if ($dailyGrowth -eq 0) {
            $result.DaysUntilFull = "No Growth"
        } else {
            $result.DaysUntilFull = "Declining"
        }
    } else {
        $daysUntilFull = $currentFreeGB / $dailyGrowth
        if ($daysUntilFull -gt $Script:DAYS_CAP) {
            $daysUntilFull = $Script:DAYS_CAP
        }
        $daysUntilFull = [math]::Round($daysUntilFull, 2)
        $result.DaysUntilFull = $daysUntilFull.ToString("F2")
        $result.NumericDays = $daysUntilFull
    }

    # Status classification - first match wins (Section 9.2)
    # Priority 3: Critical - Days < 30 OR usage > 95%
    $isCritical = $false
    if ($currentUsagePercent -gt $Script:CRITICAL_USAGE_PERCENT) {
        $isCritical = $true
    }
    if ($null -ne $result.NumericDays -and $result.NumericDays -lt $Script:CRITICAL_DAYS) {
        $isCritical = $true
    }

    if ($isCritical) {
        $result.Status = "Critical"
    }
    # Priority 4: Attention - Days 30-90 inclusive
    elseif ($null -ne $result.NumericDays -and $result.NumericDays -ge $Script:ATTENTION_DAYS_LOW -and $result.NumericDays -le $Script:ATTENTION_DAYS_HIGH) {
        $result.Status = "Attention"
    }
    # Priority 5: Declining - negative growth rate
    elseif ($dailyGrowth -lt 0) {
        $result.Status = "Declining"
    }
    # Priority 6: Growing - >= 0.1 GB/day AND days > 90
    elseif ($dailyGrowth -ge $Script:GROWING_THRESHOLD_GB_DAY -and ($null -eq $result.NumericDays -or $result.NumericDays -gt $Script:ATTENTION_DAYS_HIGH)) {
        $result.Status = "Growing"
    }
    # Priority 7: Stable - < 0.1 GB/day OR zero growth
    else {
        $result.Status = "Stable"
    }

    # Append (Limited) indicator if 7-30 data points (Section 9.4)
    if ($isLimited) {
        $result.Status = "$($result.Status) (Limited)"
    }

    Write-VerboseLog "Drive ${DriveLetter}: Data point count: $pointCount, Status: $($result.Status)"

    return $result
}

# ============================================================================
# PRIORITY RANKING (Section 9.5)
# ============================================================================
function Get-StatusSortPriority {
    param([string]$Status)
    $baseStatus = $Status -replace '\s*\(Limited\)', ''
    switch ($baseStatus) {
        "Critical"          { return 1 }
        "Attention"         { return 2 }
        "Growing"           { return 3 }
        "Stable"            { return 4 }
        "Declining"         { return 5 }
        "Insufficient Data" { return 6 }
        "Offline"           { return 7 }
        default             { return 8 }
    }
}

function Get-ServerStatusSeverity {
    param([string]$Status)
    # Section 9.7: Critical > Attention > Growing > Stable > Declining > Insufficient Data
    $baseStatus = $Status -replace '\s*\(Limited\)', ''
    switch ($baseStatus) {
        "Critical"          { return 6 }
        "Attention"         { return 5 }
        "Growing"           { return 4 }
        "Stable"            { return 3 }
        "Declining"         { return 2 }
        "Insufficient Data" { return 1 }
        default             { return 0 }
    }
}

function Sort-DataDrives {
    param([array]$Analyses)

    # Separate online and offline (Section 9.5)
    $online = @($Analyses | Where-Object { $_.DriveStatus -ne "Offline" })
    $offline = @($Analyses | Where-Object { $_.DriveStatus -eq "Offline" })

    # Sort online drives by: status priority, then numeric days-until-full, then letter
    $sorted = @($online | Sort-Object -Property @(
        @{ Expression = { Get-StatusSortPriority $_.Status }; Ascending = $true },
        @{ Expression = {
            if ($null -ne $_.NumericDays) { $_.NumericDays }
            else { [double]::MaxValue }
        }; Ascending = $true },
        @{ Expression = { $_.Letter }; Ascending = $true }
    ))

    # Append offline sorted alphabetically
    $offlineSorted = @($offline | Sort-Object -Property Letter)

    $result = @()
    if ($sorted.Count -gt 0) { $result += $sorted }
    if ($offlineSorted.Count -gt 0) { $result += $offlineSorted }

    return $result
}

# ============================================================================
# ALERTING (Section 11)
# ============================================================================
function Initialize-EventSource {
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($Script:EVENT_SOURCE)) {
            New-EventLog -LogName Application -Source $Script:EVENT_SOURCE -ErrorAction Stop
            Write-VerboseLog "Event log source '$($Script:EVENT_SOURCE)' registered"
        }
    }
    catch {
        Write-Log "WARNING: Could not register event log source: $_"
        Write-Log "WARNING: Event log writing will be skipped"
        return $false
    }
    return $true
}

function Write-CriticalAlert {
    param(
        [array]$CriticalDrives,
        [string]$Hostname
    )

    if ($CriticalDrives.Count -eq 0) { return }

    # Section 11.4 message formats
    if ($CriticalDrives.Count -eq 1) {
        $d = $CriticalDrives[0]
        $daysText = if ($d.DaysUntilFull -match '^\d') { "$($d.DaysUntilFull) days until full" } else { $d.DaysUntilFull }
        $message = "STORAGE CRITICAL: Server $Hostname - Drive $($d.Letter) has $daysText ($($d.GBPerMonth) GB/month growth rate). Immediate attention required."
    }
    else {
        $lines = "STORAGE CRITICAL: Server $Hostname - Multiple drives require attention:`r`n"
        foreach ($d in $CriticalDrives) {
            $daysText = if ($d.DaysUntilFull -match '^\d') { "$($d.DaysUntilFull) days until full" } else { $d.DaysUntilFull }
            $lines += "- Drive $($d.Letter): $daysText ($($d.GBPerMonth) GB/month)`r`n"
        }
        $message = $lines + "Immediate attention required."
    }

    try {
        Write-EventLog -LogName Application -Source $Script:EVENT_SOURCE -EventId 5001 -EntryType Warning -Message $message -ErrorAction Stop
        Write-Log "! Critical alert written to Event Log (ID 5001)"
    }
    catch {
        Write-Log "ERROR: Failed to write Event 5001: $_"
    }
}

function Write-ExcessDriveAlert {
    param(
        [int]$DriveCount,
        [array]$ExcludedDrives,
        [string]$Hostname
    )

    $excludedList = ($ExcludedDrives | ForEach-Object { $_.Letter }) -join ", "
    $message = "STORAGE MONITORING: Server $Hostname has $DriveCount data drives but only 3 can be reported. Excluded drives: $excludedList. Script update may be required."

    try {
        Write-EventLog -LogName Application -Source $Script:EVENT_SOURCE -EventId 5002 -EntryType Warning -Message $message -ErrorAction Stop
        Write-Log "! Excess drive alert written to Event Log (ID 5002)"
    }
    catch {
        Write-Log "ERROR: Failed to write Event 5002: $_"
    }
}

# ============================================================================
# NINJA RMM INTEGRATION (Section 10)
# ============================================================================
function Update-NinjaFields {
    param(
        [string]$ServerStatus,
        [hashtable]$OSAnalysis,
        [array]$DataDriveSlots
    )

    $runningInNinja = $null -ne (Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue)
    if (-not $runningInNinja) { return $false }

    try {
        # Overall Status (Section 10.1)
        Ninja-Property-Set $Script:FIELD_SERVER_STATUS $ServerStatus

        # OS Drive fields
        if ($OSAnalysis) {
            Ninja-Property-Set $Script:FIELD_OS_STATUS $OSAnalysis.Status
            Ninja-Property-Set $Script:FIELD_OS_GROWTH $OSAnalysis.GBPerMonth
            Ninja-Property-Set $Script:FIELD_OS_DAYS $OSAnalysis.DaysUntilFull
        }
        else {
            Ninja-Property-Set $Script:FIELD_OS_STATUS "NO DRIVE"
            Ninja-Property-Set $Script:FIELD_OS_GROWTH "NO DRIVE"
            Ninja-Property-Set $Script:FIELD_OS_DAYS "NO DRIVE"
        }

        # Data Drive 1-3 fields (Section 10.4)
        for ($i = 0; $i -lt $Script:MAX_DATA_DRIVES; $i++) {
            $slotNum = $i + 1
            $slot = if ($i -lt $DataDriveSlots.Count) { $DataDriveSlots[$i] } else { $null }

            $letterField = $Script:FIELD_DATA_LETTER -f $slotNum
            $statusField = $Script:FIELD_DATA_STATUS -f $slotNum
            $growthField = $Script:FIELD_DATA_GROWTH -f $slotNum
            $daysField   = $Script:FIELD_DATA_DAYS -f $slotNum

            if ($null -ne $slot -and $slot.Status -ne "NO DRIVE") {
                # Letter display: strip colon for Ninja, add (OFFLINE) if offline
                $letterDisplay = if ($slot.DriveStatus -eq "Offline") {
                    "$($slot.Letter -replace ':$', '') (OFFLINE)"
                } else {
                    $slot.Letter -replace ':$', ''
                }

                Ninja-Property-Set $letterField $letterDisplay
                Ninja-Property-Set $statusField $slot.Status
                Ninja-Property-Set $growthField $slot.GBPerMonth
                Ninja-Property-Set $daysField $slot.DaysUntilFull
            }
            else {
                # Empty slot (Section 10.2)
                Ninja-Property-Set $letterField "NO DRIVE"
                Ninja-Property-Set $statusField "NO DRIVE"
                Ninja-Property-Set $growthField "NO DRIVE"
                Ninja-Property-Set $daysField "NO DRIVE"
            }
        }

        return $true
    }
    catch {
        Write-Log "ERROR: Failed to update Ninja fields: $_"
        return $false
    }
}

# ============================================================================
# CONSOLE OUTPUT (Section 19)
# ============================================================================
function Write-Summary {
    param(
        [string]$Hostname,
        [hashtable]$OSAnalysis,
        [array]$DataDriveSlots,
        [string]$ServerStatus,
        [bool]$IsNinja,
        [array]$NewCriticalDrives
    )

    Write-Log "Storage Growth Analysis - $Hostname"
    Write-Log ([char]0x2550 * 63)
    Write-Log ""

    # OS Drive section
    if ($OSAnalysis) {
        Write-Log "OS DRIVE (Auto-detected: $($OSAnalysis.Letter))"
        $labelDisplay = if ($OSAnalysis.VolumeLabel) { $OSAnalysis.VolumeLabel } else { $OSAnalysis.Letter }
        Write-Log "  Drive $($OSAnalysis.Letter) ($labelDisplay)"

        # Show current usage if we have data points
        if ($OSAnalysis.CurrentUsedGB -gt 0 -or $OSAnalysis.CurrentFreeGB -gt 0) {
            $usedStr = $OSAnalysis.CurrentUsedGB.ToString("F3")
            $totalStr = $OSAnalysis.TotalSizeGB.ToString("F3")
            $pctStr = $OSAnalysis.CurrentPercent.ToString("F2")
            Write-Log "  Current: $usedStr GB / $totalStr GB ($pctStr%)"
        }

        $baseStatus = $OSAnalysis.Status -replace '\s*\(Limited\)', ''
        if ($baseStatus -ne "Insufficient Data" -and $baseStatus -ne "Offline") {
            if ($OSAnalysis.GBPerMonth -ne "Insufficient Data" -and $OSAnalysis.GBPerMonth -ne "OFFLINE") {
                Write-Log "  Growth:  $($OSAnalysis.GBPerMonth) GB/month"

                $daysDisplay = $OSAnalysis.DaysUntilFull
                if ($daysDisplay -eq "1825.00") {
                    $daysDisplay = "1825.00 days until full - capped"
                } elseif ($daysDisplay -match '^\d') {
                    $daysDisplay = "$daysDisplay days until full"
                }
                Write-Log "  Status:  $($OSAnalysis.Status) ($daysDisplay)"
            }
        }
        else {
            Write-Log "  Status:  $($OSAnalysis.Status)"
        }
    }

    Write-Log ""
    Write-Log "DATA DRIVES (Ranked by Criticality)"
    Write-Log ([char]0x2500 * 63)

    for ($i = 0; $i -lt $Script:MAX_DATA_DRIVES; $i++) {
        $slotNum = $i + 1
        $slot = if ($i -lt $DataDriveSlots.Count) { $DataDriveSlots[$i] } else { $null }

        if ($null -ne $slot -and $slot.Status -ne "NO DRIVE") {
            $labelDisplay = if ($slot.VolumeLabel) { $slot.VolumeLabel } else { $slot.Letter }
            Write-Log "  [$slotNum] Drive $($slot.Letter) ($labelDisplay)"

            if ($slot.DriveStatus -eq "Offline") {
                Write-Log "      Status:  OFFLINE"
            }
            elseif (($slot.Status -replace '\s*\(Limited\)', '') -eq "Insufficient Data") {
                Write-Log "      Status:  $($slot.Status)"
            }
            else {
                # Show current usage
                if ($slot.CurrentUsedGB -gt 0 -or $slot.CurrentFreeGB -gt 0) {
                    $usedStr = ([double]$slot.CurrentUsedGB).ToString("F3")
                    $totalStr = ([double]$slot.TotalSizeGB).ToString("F3")
                    $pctStr = ([double]$slot.CurrentPercent).ToString("F2")
                    Write-Log "      Current: $usedStr GB / $totalStr GB ($pctStr%)"
                }

                Write-Log "      Growth:  $($slot.GBPerMonth) GB/month"

                $statusUpper = ($slot.Status -replace '\s*\(Limited\)', '').ToUpper()
                $limitedTag = if ($slot.IsLimited) { " (Limited)" } else { "" }
                $daysDisplay = $slot.DaysUntilFull
                if ($daysDisplay -eq "1825.00") {
                    $daysDisplay = "1825.00 days until full - capped"
                } elseif ($daysDisplay -match '^\d') {
                    $daysDisplay = "$daysDisplay days until full"
                }
                Write-Log "      Status:  $statusUpper$limitedTag ($daysDisplay)"

                # Alert indicator for newly critical drives
                $baseSlotStatus = $slot.Status -replace '\s*\(Limited\)', ''
                if ($baseSlotStatus -eq "Critical" -and $NewCriticalDrives) {
                    $isNewCritical = $slot.Letter -in @($NewCriticalDrives | ForEach-Object { $_.Letter })
                    if ($isNewCritical) {
                        Write-Log "      Alert:   NEW - Event 5001 written"
                    }
                }
            }
        }
        else {
            Write-Log "  [$slotNum] NO DRIVE"
        }
        Write-Log ""
    }

    Write-Log ([char]0x2550 * 63)
    Write-Log "SERVER STATUS: $($ServerStatus.ToUpper())"
    Write-Log ""
}

# ============================================================================
# MAIN EXECUTION (Section 12)
# ============================================================================
function Main {
    $hostname = $env:COMPUTERNAME
    $runningInNinja = $null -ne (Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue)

    # ── Step 1: Initialize ───────────────────────────────────────────────────

    # Test mode banner (Section 13)
    if (-not $runningInNinja) {
        Write-Log "*** TEST MODE - Not running in Ninja context ***"
        Write-Log "Ninja custom field updates will be skipped."
        Write-Log ""
    }

    # Verbose initialization info (Section 14.4)
    Write-VerboseLog "PowerShell Version: $($PSVersionTable.PSVersion.ToString())"
    Write-VerboseLog "Script Version: $($Script:VERSION)"
    Write-VerboseLog "Storage Path: $($Script:STORAGE_PATH)"

    # Create storage folder (exit 1 on failure - Section 15.2)
    if (-not (Test-Path $Script:STORAGE_PATH)) {
        try {
            New-Item -Path $Script:STORAGE_PATH -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-VerboseLog "Created storage folder: $($Script:STORAGE_PATH)"
        }
        catch {
            Write-Log "CRITICAL: Cannot create storage folder: $_"
            Write-Log "Script cannot proceed. Exiting."
            Save-LogFile
            exit 1
        }
    }

    # Register event log source (Section 11.3)
    $eventLogAvailable = Initialize-EventSource

    # Load existing history
    $history = Load-History

    # Capture previous excess-drive alert state for fire-once logic (Section 11.2)
    $previousExcessAlertSent = [bool]$history.excessDriveAlertSent

    # ── Step 2: Discover & Collect ───────────────────────────────────────────

    $currentDrives = $null
    try {
        $currentDrives = @(Get-FilteredDrives)
    }
    catch {
        Write-Log "ERROR: Drive enumeration failed: $_"
        Write-Log "Preserving existing data, skipping collection."
        Save-History -History $history
        Save-LogFile
        exit 0
    }

    if ($currentDrives.Count -eq 0) {
        Write-Log "WARNING: No qualifying drives found."
    }

    # ── Step 3: Update Drive Status ──────────────────────────────────────────

    $history = Update-History -History $history -CurrentDrives $currentDrives

    # ── Step 4: Calculate Trends ─────────────────────────────────────────────

    $osAnalysis = $null
    $dataAnalyses = [System.Collections.ArrayList]::new()

    foreach ($letter in @($history.drives.Keys)) {
        $driveData = $history.drives[$letter]
        $analysis = Get-DriveAnalysis -DriveData $driveData -DriveLetter $letter

        if ($driveData.driveType -eq "OS") {
            $osAnalysis = $analysis
        }
        else {
            [void]$dataAnalyses.Add($analysis)
        }
    }

    # ── Step 5: Rank & Organize ──────────────────────────────────────────────

    $sortedDataDrives = @(Sort-DataDrives -Analyses $dataAnalyses)

    # ── Step 6: Check Drive Count (Section 10.3) ────────────────────────────

    $onlineDataCount = @($dataAnalyses | Where-Object { $_.DriveStatus -ne "Offline" }).Count
    $excludedDrives = @()
    $reportedDataDrives = $sortedDataDrives

    if ($sortedDataDrives.Count -gt $Script:MAX_DATA_DRIVES) {
        $reportedDataDrives = @($sortedDataDrives[0..($Script:MAX_DATA_DRIVES - 1)])
        $excludedDrives = @($sortedDataDrives[$Script:MAX_DATA_DRIVES..($sortedDataDrives.Count - 1)])

        Write-Log "NOTE: $($sortedDataDrives.Count) data drives detected, reporting top $($Script:MAX_DATA_DRIVES)"
        foreach ($excl in $excludedDrives) {
            Write-Log "  Excluded: $($excl.Letter)"
        }
    }

    # Update excess-drive alert flag (Section 11.2 - Event 5002 fire-once)
    if ($onlineDataCount -gt $Script:MAX_DATA_DRIVES) {
        $history.excessDriveAlertSent = $true
    }
    else {
        $history.excessDriveAlertSent = $false
    }

    # Fire Event 5002 only on NEW transition (was false, now true)
    if ($onlineDataCount -gt $Script:MAX_DATA_DRIVES -and -not $previousExcessAlertSent -and $eventLogAvailable) {
        Write-ExcessDriveAlert -DriveCount $onlineDataCount -ExcludedDrives $excludedDrives -Hostname $hostname
    }

    # Pad data drive slots to 3 (Section 10.2)
    $dataSlots = [System.Collections.ArrayList]::new()
    foreach ($d in $reportedDataDrives) {
        [void]$dataSlots.Add($d)
    }
    while ($dataSlots.Count -lt $Script:MAX_DATA_DRIVES) {
        [void]$dataSlots.Add(@{
            Letter        = "NO DRIVE"
            VolumeLabel   = ""
            Status        = "NO DRIVE"
            GBPerMonth    = "NO DRIVE"
            DaysUntilFull = "NO DRIVE"
            DriveStatus   = "NO DRIVE"
            IsLimited     = $false
            CurrentUsedGB = 0
            CurrentFreeGB = 0
            CurrentPercent = 0
            TotalSizeGB   = 0
        })
    }

    # Determine overall server status - worst case among online drives (Section 9.7)
    $worstSeverity = 0
    $serverStatus = "Insufficient Data"

    $allOnlineAnalyses = @()
    if ($osAnalysis -and $osAnalysis.DriveStatus -ne "Offline") { $allOnlineAnalyses += $osAnalysis }
    $allOnlineAnalyses += @($dataAnalyses | Where-Object { $_.DriveStatus -ne "Offline" })

    foreach ($analysis in $allOnlineAnalyses) {
        $severity = Get-ServerStatusSeverity -Status $analysis.Status
        if ($severity -gt $worstSeverity) {
            $worstSeverity = $severity
            $serverStatus = $analysis.Status -replace '\s*\(Limited\)', ''
        }
    }

    # ── Step 7: Check Critical - Fire-Once Logic (Section 11.2) ─────────────

    $newCriticalDrives = [System.Collections.ArrayList]::new()

    foreach ($letter in @($history.drives.Keys)) {
        $driveData = $history.drives[$letter]

        # Find matching analysis result
        $analysis = $null
        if ($osAnalysis -and $osAnalysis.Letter -eq $letter) {
            $analysis = $osAnalysis
        }
        else {
            $analysis = $dataAnalyses | Where-Object { $_.Letter -eq $letter } | Select-Object -First 1
        }

        if (-not $analysis) { continue }

        $baseStatus = $analysis.Status -replace '\s*\(Limited\)', ''

        if ($baseStatus -eq "Critical") {
            if (-not $driveData.alertSent) {
                # Transition TO Critical - fire alert
                [void]$newCriticalDrives.Add($analysis)
                $driveData.alertSent = $true
                Write-VerboseLog "Drive ${letter}: alertSent was FALSE, setting to TRUE, writing Event 5001"
            }
            else {
                # Already alerted - skip
                Write-VerboseLog "Drive ${letter}: alertSent was TRUE, skipping Event 5001"
            }
        }
        else {
            # No longer Critical - reset flag for next incident
            if ($driveData.alertSent) {
                $driveData.alertSent = $false
                Write-VerboseLog "Drive ${letter}: No longer Critical, resetting alertSent to FALSE"
            }
        }
    }

    # Write combined Event 5001 if any drives transitioned to Critical (Section 11.4)
    if ($newCriticalDrives.Count -gt 0 -and $eventLogAvailable) {
        Write-CriticalAlert -CriticalDrives $newCriticalDrives -Hostname $hostname
    }

    # ── Step 8: Persist & Report ─────────────────────────────────────────────

    # Console output summary
    Write-Summary -Hostname $hostname -OSAnalysis $osAnalysis -DataDriveSlots $dataSlots `
                  -ServerStatus $serverStatus -IsNinja $runningInNinja -NewCriticalDrives $newCriticalDrives

    # Update Ninja custom fields or show test mode message
    if ($runningInNinja) {
        $ninjaSuccess = Update-NinjaFields -ServerStatus $serverStatus -OSAnalysis $osAnalysis -DataDriveSlots $dataSlots
        if ($ninjaSuccess) {
            Write-Log ([char]0x2713 + " CUSTOM FIELDS FILLED")
            Write-Log "  - OS Drive: $(if ($osAnalysis) { $osAnalysis.Letter } else { 'NO DRIVE' })"
            for ($i = 0; $i -lt $Script:MAX_DATA_DRIVES; $i++) {
                $slot = $dataSlots[$i]
                $display = if ($slot.Status -eq "NO DRIVE") { "NO DRIVE" } else { $slot.Letter }
                Write-Log "  - Data Drive $($i + 1): $display"
            }
        }
    }
    else {
        Write-Log "*** TEST MODE - Ninja fields not updated ***"
    }

    # Save history JSON
    Save-History -History $history

    # Write log file with rotation
    Save-LogFile

    exit 0
}

# ============================================================================
# ENTRY POINT
# ============================================================================
Main
