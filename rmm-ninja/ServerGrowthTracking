<#
.SYNOPSIS
    Storage Growth Monitor v2.0 - SQLite Edition
    Tracks server storage growth trends and reports via Ninja RMM.

.DESCRIPTION
    Collects daily storage metrics from servers (physical Hyper-V hosts and VMs),
    persists to a shared SQLite database at %PROGRAMDATA%\dtc-inc\rmm\dtc-rmm.db,
    calculates growth trends using linear regression, and generates a visual HTML
    storage report written to a single Ninja RMM WYSIWYG custom field.

    The SQLite database is designed as a shared data store that other scripts and
    tools can query. Schema uses PostgreSQL-compatible conventions for future
    migration to a centralized API service backed by PostgreSQL.

    Technical Design Document: Ticket 1123004 - DTC Internal
    Version: 2.0 (SQLite Edition)

    Ninja RMM Setup:
    - Create ONE WYSIWYG custom field named "storageReport"
    - The script populates it with an HTML dashboard including SVG line chart

    Limitation: device_id is derived from $env:COMPUTERNAME. A hostname rename
    will create a new device row and orphan historical data under the old name.
    If stable identity across renames is required, consider switching to a
    hardware identifier (e.g. Win32_ComputerSystemProduct.UUID).

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
$Script:VERSION = "2.0"
$Script:STORAGE_PATH = Join-Path $env:ProgramData "dtc-inc\rmm"
$Script:DB_PATH = Join-Path $Script:STORAGE_PATH "dtc-rmm.db"
$Script:LOG_FILE = Join-Path $Script:STORAGE_PATH "storage_monitor.log"
$Script:EVENT_SOURCE = "StorageGrowthMonitor"

# Retention & thresholds
$Script:RETENTION_DAYS = 65
$Script:LOG_RETENTION_DAYS = 90
$Script:LOG_PRUNE_THRESHOLD_KB = 256
$Script:OFFLINE_REMOVAL_DAYS = 30
$Script:MIN_DATA_POINTS = 7
$Script:FULL_CONFIDENCE_POINTS = 30
$Script:DAYS_CAP = 1825
$Script:MIN_DRIVE_SIZE_GB = 1
$Script:CRITICAL_DAYS = 30
$Script:ATTENTION_DAYS_LOW = 30
$Script:ATTENTION_DAYS_HIGH = 90
$Script:CRITICAL_USAGE_PERCENT = 95
$Script:GROWING_THRESHOLD_GB_DAY = 0.1
$Script:EXCLUDED_LABELS = @("Recovery", "EFI", "System Reserved", "SYSTEM", "Windows RE")
$Script:EXCLUDED_FILESYSTEMS = @("FAT", "FAT32", "RAW")

# Ninja RMM field (single WYSIWYG field)
$Script:FIELD_STORAGE_REPORT = "storageReport"

# Legacy JSON paths (for migration)
$Script:LEGACY_JSON_PATH = Join-Path $env:ProgramData "NinjaRMM\StorageMetrics\storage_history.json"

# Chart color palette (colorblind-friendly)
$Script:CHART_COLORS = @('#2563eb', '#16a34a', '#ea580c', '#9333ea', '#0d9488', '#dc2626', '#ca8a04', '#be185d')

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
# LOG FILE MANAGEMENT
# ============================================================================
function Save-LogFile {
    try {
        if ($Script:LogBuffer.Count -gt 0) {
            $Script:LogBuffer | Add-Content -Path $Script:LOG_FILE -Encoding UTF8 -ErrorAction Stop
        }

        $fileInfo = Get-Item $Script:LOG_FILE -ErrorAction SilentlyContinue
        if ($fileInfo -and ($fileInfo.Length / 1KB) -gt $Script:LOG_PRUNE_THRESHOLD_KB) {
            $cutoff = (Get-Date).AddDays(-$Script:LOG_RETENTION_DAYS)
            $existingLines = @(Get-Content -Path $Script:LOG_FILE -ErrorAction Stop)
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
                [void]$prunedLines.Add($line)
            }

            if ($removedCount -gt 0) {
                $prunedLines | Set-Content -Path $Script:LOG_FILE -Encoding UTF8 -ErrorAction Stop
                Write-VerboseLog "Log pruning: $removedCount entries removed (older than $($Script:LOG_RETENTION_DAYS) days)"
            }
        }
    }
    catch {
        Write-Host "$(Get-TimestampString) ERROR: Failed to write log file: $_"
    }
}

# ============================================================================
# SAFE TIMESTAMP PARSING
# ============================================================================
function ConvertTo-SafeDateTime {
    param([string]$Timestamp)

    $parsed = $null
    if ([DateTime]::TryParse($Timestamp, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

# ============================================================================
# SQLITE MODULE MANAGEMENT
# ============================================================================
function Initialize-SQLiteModule {
    <#
    .SYNOPSIS
        Ensures the PSSQLite module is available. Installs from PSGallery if needed.
    #>

    # Check if already available
    if (Get-Module -Name PSSQLite -ErrorAction SilentlyContinue) {
        Write-VerboseLog "PSSQLite module: Already loaded"
        return $true
    }

    if (Get-Module -ListAvailable -Name PSSQLite -ErrorAction SilentlyContinue) {
        try {
            Import-Module PSSQLite -ErrorAction Stop
            Write-VerboseLog "PSSQLite module: Imported successfully"
            return $true
        }
        catch {
            Write-Log "WARNING: PSSQLite found but failed to import: $_"
        }
    }

    # Install from PSGallery
    Write-Log "PSSQLite module not found - installing from PSGallery..."
    try {
        # Add TLS 1.2 without removing existing protocols (preserves TLS 1.3 on .NET 5+)
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        # Ensure NuGet provider is available
        $nuget = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $nuget -or $nuget.Version -lt [Version]"2.8.5.201") {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
        }

        Install-Module -Name PSSQLite -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
        Import-Module PSSQLite -ErrorAction Stop
        Write-Log ([char]0x2713 + " PSSQLite module installed and loaded")
        return $true
    }
    catch {
        Write-Log "ERROR: Cannot install PSSQLite module: $_"
        Write-Log "Install manually: Install-Module -Name PSSQLite -Force -Scope AllUsers"
        return $false
    }
}

# ============================================================================
# DATABASE SCHEMA & INITIALIZATION
# ============================================================================
function Initialize-Database {
    <#
    .SYNOPSIS
        Creates the SQLite database and tables if they don't exist.
        Schema uses PostgreSQL-compatible conventions for future migration.
    #>

    try {
        # Enable WAL mode for better concurrent access
        Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query "PRAGMA journal_mode=WAL" -ErrorAction Stop | Out-Null

        # Device table - one row per monitored machine
        Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query @"
            CREATE TABLE IF NOT EXISTS device (
                device_id       TEXT PRIMARY KEY,
                hostname        TEXT NOT NULL,
                os_version      TEXT,
                created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%S', 'now', 'localtime')),
                updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%S', 'now', 'localtime'))
            )
"@ -ErrorAction Stop | Out-Null

        # Drive table - one row per drive per device
        Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query @"
            CREATE TABLE IF NOT EXISTS drive (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                device_id       TEXT NOT NULL REFERENCES device(device_id),
                drive_letter    TEXT NOT NULL,
                volume_label    TEXT DEFAULT '',
                total_size_gb   REAL NOT NULL,
                drive_type      TEXT NOT NULL CHECK(drive_type IN ('OS', 'Data')),
                status          TEXT NOT NULL DEFAULT 'Online' CHECK(status IN ('Online', 'Offline')),
                last_seen       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%S', 'now', 'localtime')),
                alert_sent      INTEGER NOT NULL DEFAULT 0,
                created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%S', 'now', 'localtime')),
                UNIQUE(device_id, drive_letter)
            )
"@ -ErrorAction Stop | Out-Null

        # Metric table - time-series storage data points
        Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query @"
            CREATE TABLE IF NOT EXISTS metric (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                drive_id        INTEGER NOT NULL REFERENCES drive(id),
                timestamp       TEXT NOT NULL,
                used_gb         REAL NOT NULL,
                free_gb         REAL NOT NULL,
                usage_percent   REAL NOT NULL
            )
"@ -ErrorAction Stop | Out-Null

        # Alert state table - scaffolding for future centralized alerting service.
        # Not consumed by this script; fire-once logic uses drive.alert_sent instead.
        # TODO: Wire up when centralized API is available (see Ticket 1123004 roadmap).
        Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query @"
            CREATE TABLE IF NOT EXISTS alert_state (
                device_id       TEXT NOT NULL REFERENCES device(device_id),
                alert_type      TEXT NOT NULL,
                is_active       INTEGER NOT NULL DEFAULT 0,
                last_triggered  TEXT,
                PRIMARY KEY (device_id, alert_type)
            )
"@ -ErrorAction Stop | Out-Null

        # Indexes for efficient queries
        Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query "CREATE INDEX IF NOT EXISTS idx_metric_drive_ts ON metric(drive_id, timestamp)" -ErrorAction Stop | Out-Null
        Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query "CREATE INDEX IF NOT EXISTS idx_drive_device ON drive(device_id)" -ErrorAction Stop | Out-Null

        Write-VerboseLog "Database initialized: $($Script:DB_PATH)"
        return $true
    }
    catch {
        Write-Log "ERROR: Failed to initialize database: $_"
        return $false
    }
}

# ============================================================================
# DATABASE OPERATIONS (CRUD)
# ============================================================================
function Get-DeviceRecord {
    <#
    .SYNOPSIS
        Gets or creates the device record for the current machine.
    #>
    param([string]$DeviceId, [string]$Hostname)

    $now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    $osVersion = ""
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) { $osVersion = "$($os.Caption) $($os.Version)" }
    }
    catch { }

    $existing = Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query "SELECT device_id FROM device WHERE device_id = @id" -SqlParameters @{ id = $DeviceId }

    if ($existing) {
        Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query "UPDATE device SET hostname = @hostname, os_version = @os, updated_at = @now WHERE device_id = @id" -SqlParameters @{
            id       = $DeviceId
            hostname = $Hostname
            os       = $osVersion
            now      = $now
        } | Out-Null
    }
    else {
        Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query "INSERT INTO device (device_id, hostname, os_version, created_at, updated_at) VALUES (@id, @hostname, @os, @now, @now)" -SqlParameters @{
            id       = $DeviceId
            hostname = $Hostname
            os       = $osVersion
            now      = $now
        } | Out-Null
    }
}

function Get-DriveRecord {
    <#
    .SYNOPSIS
        Gets a drive record by device_id and drive_letter.
    #>
    param([string]$DeviceId, [string]$DriveLetter)

    return Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query "SELECT * FROM drive WHERE device_id = @did AND drive_letter = @letter" -SqlParameters @{
        did    = $DeviceId
        letter = $DriveLetter
    }
}

function Save-DriveRecord {
    <#
    .SYNOPSIS
        Upserts a drive record (insert or update).
    #>
    param(
        [string]$DeviceId,
        [string]$DriveLetter,
        [string]$VolumeLabel,
        [double]$TotalSizeGB,
        [string]$DriveType,
        [string]$Status = "Online"
    )

    $now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    $existing = Get-DriveRecord -DeviceId $DeviceId -DriveLetter $DriveLetter

    if ($existing) {
        # Detect disk resize
        if ([math]::Abs($existing.total_size_gb - $TotalSizeGB) -gt 0.01) {
            Write-Log "Drive ${DriveLetter}: disk size changed from $($existing.total_size_gb) GB to $TotalSizeGB GB"
        }

        Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query @"
            UPDATE drive SET volume_label = @label, total_size_gb = @size, drive_type = @type,
                             status = @status, last_seen = @now
            WHERE device_id = @did AND drive_letter = @letter
"@ -SqlParameters @{
            did    = $DeviceId
            letter = $DriveLetter
            label  = $VolumeLabel
            size   = $TotalSizeGB
            type   = $DriveType
            status = $Status
            now    = $now
        } | Out-Null
        return $existing.id
    }
    else {
        Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query @"
            INSERT INTO drive (device_id, drive_letter, volume_label, total_size_gb, drive_type, status, last_seen, created_at)
            VALUES (@did, @letter, @label, @size, @type, @status, @now, @now)
"@ -SqlParameters @{
            did    = $DeviceId
            letter = $DriveLetter
            label  = $VolumeLabel
            size   = $TotalSizeGB
            type   = $DriveType
            status = $Status
            now    = $now
        } | Out-Null

        $newDrive = Get-DriveRecord -DeviceId $DeviceId -DriveLetter $DriveLetter
        if (-not $newDrive) {
            throw "Failed to retrieve newly inserted drive record for ${DeviceId}:${DriveLetter}"
        }
        return $newDrive.id
    }
}

function Add-MetricRecord {
    <#
    .SYNOPSIS
        Inserts a new metric data point for a drive.
    #>
    param(
        [int]$DriveId,
        [string]$Timestamp,
        [double]$UsedGB,
        [double]$FreeGB,
        [double]$UsagePercent
    )

    Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query @"
        INSERT INTO metric (drive_id, timestamp, used_gb, free_gb, usage_percent)
        VALUES (@driveId, @ts, @used, @free, @pct)
"@ -SqlParameters @{
        driveId = $DriveId
        ts      = $Timestamp
        used    = $UsedGB
        free    = $FreeGB
        pct     = $UsagePercent
    } | Out-Null
}

function Set-DailyMetric {
    <#
    .SYNOPSIS
        Inserts or updates the metric for a drive for the current calendar day.
        Prevents duplicate rows when the script runs more than once per day.
        Uses atomic DELETE+INSERT in a single batch to avoid TOCTOU races.
    #>
    param(
        [int]$DriveId,
        [string]$Timestamp,
        [double]$UsedGB,
        [double]$FreeGB,
        [double]$UsagePercent
    )

    $parsed = ConvertTo-SafeDateTime $Timestamp
    if ($null -eq $parsed) {
        Add-MetricRecord -DriveId $DriveId -Timestamp $Timestamp -UsedGB $UsedGB -FreeGB $FreeGB -UsagePercent $UsagePercent
        return
    }

    $dayStart = $parsed.ToString("yyyy-MM-dd") + "T00:00:00"
    $dayEnd = $parsed.AddDays(1).ToString("yyyy-MM-dd") + "T00:00:00"

    # Atomic: delete any existing same-day row then insert the new one, in a single statement batch.
    # This runs within a single PSSQLite connection so both statements share one implicit transaction.
    Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query @"
        DELETE FROM metric
        WHERE drive_id = @driveId AND timestamp >= @dayStart AND timestamp < @dayEnd;
        INSERT INTO metric (drive_id, timestamp, used_gb, free_gb, usage_percent)
        VALUES (@driveId, @ts, @used, @free, @pct);
"@ -SqlParameters @{
        driveId  = $DriveId
        dayStart = $dayStart
        dayEnd   = $dayEnd
        ts       = $Timestamp
        used     = $UsedGB
        free     = $FreeGB
        pct      = $UsagePercent
    } | Out-Null
}

function Get-DriveMetrics {
    <#
    .SYNOPSIS
        Gets metric history for a drive within the retention window.
        Returns objects with: timestamp, usedGB, freeGB, usagePercent
    #>
    param([int]$DriveId)

    $cutoff = (Get-Date).AddDays(-$Script:RETENTION_DAYS).ToString("yyyy-MM-ddTHH:mm:ss")

    $results = Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query @"
        SELECT timestamp, used_gb AS usedGB, free_gb AS freeGB, usage_percent AS usagePercent
        FROM metric
        WHERE drive_id = @driveId AND timestamp >= @cutoff
        ORDER BY timestamp
"@ -SqlParameters @{
        driveId = $DriveId
        cutoff  = $cutoff
    }
    if ($null -eq $results) { return @() }
    return @($results | Where-Object { $null -ne $_ })
}

function Get-AllDeviceDrives {
    <#
    .SYNOPSIS
        Gets all drive records for a device.
    #>
    param([string]$DeviceId)

    $results = Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query "SELECT * FROM drive WHERE device_id = @did ORDER BY drive_letter" -SqlParameters @{
        did = $DeviceId
    }
    if ($null -eq $results) { return @() }
    return @($results | Where-Object { $null -ne $_ })
}

function Set-DriveAlertSent {
    param([int]$DriveId, [bool]$AlertSent)

    $val = if ($AlertSent) { 1 } else { 0 }
    Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query "UPDATE drive SET alert_sent = @val WHERE id = @id" -SqlParameters @{
        id  = $DriveId
        val = $val
    } | Out-Null
}

function Set-DriveOffline {
    param([int]$DriveId)

    Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query "UPDATE drive SET status = 'Offline' WHERE id = @id" -SqlParameters @{
        id = $DriveId
    } | Out-Null
}

function Remove-StaleDrives {
    <#
    .SYNOPSIS
        Removes drives that have been offline longer than the threshold, along with their metrics.
    #>
    param([string]$DeviceId)

    $cutoff = (Get-Date).AddDays(-$Script:OFFLINE_REMOVAL_DAYS).ToString("yyyy-MM-ddTHH:mm:ss")

    $rawResults = Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query @"
        SELECT id, drive_letter, last_seen FROM drive
        WHERE device_id = @did AND status = 'Offline' AND last_seen < @cutoff
"@ -SqlParameters @{
        did    = $DeviceId
        cutoff = $cutoff
    }
    $staleDrives = if ($null -eq $rawResults) { @() } else { @($rawResults | Where-Object { $null -ne $_ }) }

    foreach ($drive in $staleDrives) {
        $parsedLastSeen = ConvertTo-SafeDateTime $drive.last_seen
        if ($null -eq $parsedLastSeen) { $parsedLastSeen = Get-Date }
        $daysOffline = [math]::Round(((Get-Date) - $parsedLastSeen).TotalDays, 0)
        Write-Log "Drive $($drive.drive_letter): Offline for $daysOffline days - removing from database"

        Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query "DELETE FROM metric WHERE drive_id = @id" -SqlParameters @{ id = $drive.id } | Out-Null
        Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query "DELETE FROM drive WHERE id = @id" -SqlParameters @{ id = $drive.id } | Out-Null
    }

    return $staleDrives.Count
}

function Remove-OldMetrics {
    <#
    .SYNOPSIS
        Prunes metric data points older than the retention window.
    #>

    $cutoff = (Get-Date).AddDays(-$Script:RETENTION_DAYS).ToString("yyyy-MM-ddTHH:mm:ss")

    $result = Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query "SELECT COUNT(*) AS cnt FROM metric WHERE timestamp < @cutoff" -SqlParameters @{ cutoff = $cutoff }
    $count = if ($result) { $result.cnt } else { 0 }

    if ($count -gt 0) {
        Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query "DELETE FROM metric WHERE timestamp < @cutoff" -SqlParameters @{ cutoff = $cutoff } | Out-Null
        Write-VerboseLog "Pruned $count metric records older than $($Script:RETENTION_DAYS) days"
    }
}

# ============================================================================
# LEGACY JSON MIGRATION (one-time)
# ============================================================================
function Import-LegacyJsonHistory {
    <#
    .SYNOPSIS
        Migrates existing JSON history data to the SQLite database.
        Runs once, then renames the JSON file to .migrated.
    #>
    param([string]$DeviceId)

    if (-not (Test-Path $Script:LEGACY_JSON_PATH)) { return $false }

    Write-Log "Found legacy JSON history - migrating to SQLite..."

    try {
        $content = Get-Content -Path $Script:LEGACY_JSON_PATH -Raw -Encoding UTF8 -ErrorAction Stop
        $data = $content | ConvertFrom-Json -ErrorAction Stop

        if (-not $data.drives) {
            Write-Log "WARNING: Legacy JSON has no drives section, skipping migration"
            return $false
        }

        $migratedDrives = 0
        $migratedPoints = 0
        $skippedPoints = 0

        foreach ($prop in $data.drives.PSObject.Properties) {
            $letter = $prop.Name
            $driveData = $prop.Value

            $driveType = if ($driveData.driveType) { $driveData.driveType } else { "Data" }
            $volumeLabel = if ($driveData.volumeLabel) { $driveData.volumeLabel } else { "" }
            $totalSize = if ($driveData.totalSizeGB) { [double]$driveData.totalSizeGB } else { 0 }
            $status = if ($driveData.status) { $driveData.status } else { "Online" }
            $lastSeen = if ($driveData.lastSeen) { $driveData.lastSeen } else { (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss") }
            $alertSent = if ($driveData.alertSent) { [bool]$driveData.alertSent } else { $false }

            # Create drive record
            $driveId = Save-DriveRecord -DeviceId $DeviceId -DriveLetter $letter -VolumeLabel $volumeLabel `
                -TotalSizeGB $totalSize -DriveType $driveType -Status $status

            if ($alertSent) {
                Set-DriveAlertSent -DriveId $driveId -AlertSent $true
            }

            # Migrate history data points
            if ($driveData.history) {
                foreach ($entry in $driveData.history) {
                    if (-not $entry.timestamp) { continue }
                    # Guard against null/missing metric fields that would cast to 0.0 and corrupt regression
                    if ($null -eq $entry.usedGB -or $null -eq $entry.freeGB -or $null -eq $entry.usagePercent) {
                        Write-VerboseLog "Migration: Skipping entry with missing fields (ts=$($entry.timestamp))"
                        $skippedPoints++
                        continue
                    }
                    $ts = $entry.timestamp
                    Add-MetricRecord -DriveId $driveId -Timestamp $ts `
                        -UsedGB ([double]$entry.usedGB) -FreeGB ([double]$entry.freeGB) `
                        -UsagePercent ([double]$entry.usagePercent)
                    $migratedPoints++
                }
            }

            $migratedDrives++
        }

        # Rename the old JSON file
        $migratedPath = $Script:LEGACY_JSON_PATH + ".migrated"
        Move-Item -Path $Script:LEGACY_JSON_PATH -Destination $migratedPath -Force -ErrorAction Stop

        # Also rename backup if it exists
        $backupPath = $Script:LEGACY_JSON_PATH + ".bak"
        if (Test-Path $backupPath) {
            Move-Item -Path $backupPath -Destination ($backupPath + ".migrated") -Force -ErrorAction SilentlyContinue
        }

        $skipMsg = if ($skippedPoints -gt 0) { " ($skippedPoints incomplete entries skipped)" } else { "" }
        Write-Log ([char]0x2713 + " Migration complete: $migratedDrives drives, $migratedPoints data points$skipMsg")
        return $true
    }
    catch {
        Write-Log "WARNING: JSON migration failed: $_"
        Write-Log "Legacy data preserved at $($Script:LEGACY_JSON_PATH)"
        return $false
    }
}

# ============================================================================
# DRIVE DISCOVERY & FILTERING
# ============================================================================
function Get-FilteredDrives {
    # Detect OS drive
    $osDriveLetter = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).SystemDrive
    if (-not $osDriveLetter) {
        Write-Log "WARNING: Could not detect OS drive, falling back to C:"
        $osDriveLetter = "C:"
    }
    Write-VerboseLog "OS Drive detected: $osDriveLetter"

    # Primary source - Win32_LogicalDisk
    $logicalDisks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop)
    Write-VerboseLog "Drive Discovery: $($logicalDisks.Count) drives found"

    # Secondary source - Win32_Volume for filtering metadata
    $volumes = $null
    try {
        $volumes = @(Get-CimInstance -ClassName Win32_Volume -ErrorAction Stop)
        Write-VerboseLog "Win32_Volume query: Success"
    }
    catch {
        Write-Log "WARNING: Win32_Volume query failed - continuing with LogicalDisk only"
    }

    $filteredDrives = [System.Collections.ArrayList]::new()

    foreach ($disk in $logicalDisks) {
        $letter = $disk.DeviceID
        $sizeGB = [math]::Round($disk.Size / 1GB, 3)
        $label = $disk.VolumeName

        $matchingVolume = $null
        if ($volumes) {
            $matchingVolume = $volumes | Where-Object { $_.DriveLetter -eq $letter } | Select-Object -First 1
        }

        $fileSystem = if ($matchingVolume -and $matchingVolume.FileSystem) { $matchingVolume.FileSystem } else { "" }

        if (-not $label -and $matchingVolume -and $matchingVolume.Label) {
            $label = $matchingVolume.Label
        }

        # Exclusion checks
        if ($sizeGB -lt $Script:MIN_DRIVE_SIZE_GB) {
            Write-VerboseLog "  $letter Size=${sizeGB}GB - EXCLUDED (< 1GB)"
            continue
        }

        $labelExcluded = $false
        if ($label) {
            foreach ($excludedLabel in $Script:EXCLUDED_LABELS) {
                if ($label -ieq $excludedLabel) {
                    Write-VerboseLog "  $letter Label=`"$label`" - EXCLUDED ($excludedLabel)"
                    $labelExcluded = $true
                    break
                }
            }
        }
        if ($labelExcluded) { continue }

        if ($fileSystem -and $Script:EXCLUDED_FILESYSTEMS -contains $fileSystem) {
            Write-VerboseLog "  $letter - EXCLUDED (FileSystem: $fileSystem)"
            continue
        }

        # Drive passed all filters
        $isOS = ($letter -eq $osDriveLetter)
        $driveType = if ($isOS) { "OS" } else { "Data" }

        $usedBytes = $disk.Size - $disk.FreeSpace
        $usedGB = [math]::Round($usedBytes / 1GB, 3)
        $freeGB = [math]::Round($disk.FreeSpace / 1GB, 3)
        $usagePercent = if ($disk.Size -gt 0) { [math]::Round(($usedBytes / $disk.Size) * 100, 2) } else { 0 }

        Write-VerboseLog "  $letter Size=${sizeGB}GB - INCLUDED ($driveType)"

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
# LINEAR REGRESSION
# ============================================================================
function Get-LinearRegression {
    param([array]$HistoryData)

    $n = $HistoryData.Count
    if ($n -lt 2) {
        return @{ Slope = 0; Intercept = 0; RSquared = 0 }
    }

    $firstTimestamp = ConvertTo-SafeDateTime -Timestamp $HistoryData[0].timestamp
    if ($null -eq $firstTimestamp) {
        return @{ Slope = 0; Intercept = 0; RSquared = 0 }
    }

    $sumX = 0.0; $sumY = 0.0; $sumXY = 0.0; $sumX2 = 0.0; $sumY2 = 0.0
    $validPoints = 0

    foreach ($point in $HistoryData) {
        $pointDate = ConvertTo-SafeDateTime -Timestamp $point.timestamp
        if ($null -eq $pointDate) { continue }

        $x = ($pointDate - $firstTimestamp).TotalDays
        $y = [double]$point.usedGB

        $sumX += $x; $sumY += $y; $sumXY += ($x * $y); $sumX2 += ($x * $x); $sumY2 += ($y * $y)
        $validPoints++
    }

    if ($validPoints -lt 2) {
        return @{ Slope = 0; Intercept = 0; RSquared = 0 }
    }

    $denominator = ($validPoints * $sumX2) - ($sumX * $sumX)
    if ([math]::Abs($denominator) -lt 1e-10) {
        return @{ Slope = 0; Intercept = $sumY / $validPoints; RSquared = 0 }
    }

    $slope = (($validPoints * $sumXY) - ($sumX * $sumY)) / $denominator
    $intercept = ($sumY - ($slope * $sumX)) / $validPoints

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
        Slope     = $slope
        Intercept = $intercept
        RSquared  = [math]::Round($rSquared, 2)
    }
}

# ============================================================================
# TREND ANALYSIS & STATUS CLASSIFICATION
# ============================================================================
function Get-DriveAnalysis {
    <#
    .SYNOPSIS
        Analyzes a drive's metrics and classifies its status.
    #>
    param(
        [object]$DriveRecord,
        [array]$Metrics
    )

    $result = @{
        Letter          = $DriveRecord.drive_letter
        VolumeLabel     = $DriveRecord.volume_label
        TotalSizeGB     = $DriveRecord.total_size_gb
        DriveType       = $DriveRecord.drive_type
        DriveId         = $DriveRecord.id
        Status          = ""
        GBPerMonth      = ""
        DaysUntilFull   = ""
        AlertSent       = [bool]$DriveRecord.alert_sent
        DriveStatus     = $DriveRecord.status
        IsLimited       = $false
        NumericDays     = $null
        RawGrowthPerDay = 0
        CurrentUsedGB   = 0
        CurrentFreeGB   = 0
        CurrentPercent  = 0
        Metrics         = $Metrics
        DataPoints      = $Metrics.Count
    }

    # Handle offline drives
    if ($DriveRecord.status -eq "Offline") {
        $result.Status = "Offline"
        $result.GBPerMonth = "OFFLINE"
        $result.DaysUntilFull = "OFFLINE"
        return $result
    }

    $pointCount = $Metrics.Count

    # Current metrics from latest data point
    if ($pointCount -gt 0) {
        $latest = $Metrics[$pointCount - 1]
        $result.CurrentUsedGB = [double]$latest.usedGB
        $result.CurrentFreeGB = [double]$latest.freeGB
        $result.CurrentPercent = [double]$latest.usagePercent
    }

    # Minimum data points check
    if ($pointCount -lt $Script:MIN_DATA_POINTS) {
        $result.Status = "Insufficient Data"
        $result.GBPerMonth = "Insufficient Data"
        $result.DaysUntilFull = "Insufficient Data"
        Write-VerboseLog "Drive $($DriveRecord.drive_letter): $pointCount data points - Insufficient Data"
        return $result
    }

    $isLimited = $pointCount -lt $Script:FULL_CONFIDENCE_POINTS
    $result.IsLimited = $isLimited

    # Linear regression
    $regression = Get-LinearRegression -HistoryData $Metrics
    $dailyGrowth = $regression.Slope
    $monthlyGrowth = [math]::Round($dailyGrowth * 30, 3)
    $result.RawGrowthPerDay = $dailyGrowth

    Write-VerboseLog "Drive $($DriveRecord.drive_letter): slope=$([math]::Round($dailyGrowth, 4)) GB/day, R$([char]0x00B2)=$($regression.RSquared)"

    $result.GBPerMonth = $monthlyGrowth.ToString("F3", [System.Globalization.CultureInfo]::InvariantCulture)

    $currentFreeGB = $result.CurrentFreeGB
    $currentUsagePercent = $result.CurrentPercent

    # Days until full
    if ($dailyGrowth -le 0) {
        $result.DaysUntilFull = if ($dailyGrowth -eq 0) { "No Growth" } else { "Declining" }
    }
    else {
        $daysUntilFull = $currentFreeGB / $dailyGrowth
        if ($daysUntilFull -gt $Script:DAYS_CAP) { $daysUntilFull = $Script:DAYS_CAP }
        $daysUntilFull = [math]::Round($daysUntilFull, 2)
        $result.DaysUntilFull = $daysUntilFull.ToString("F2", [System.Globalization.CultureInfo]::InvariantCulture)
        $result.NumericDays = $daysUntilFull
    }

    # Status classification - first match wins
    $isCritical = $false
    if ($currentUsagePercent -gt $Script:CRITICAL_USAGE_PERCENT) { $isCritical = $true }
    if ($null -ne $result.NumericDays -and $result.NumericDays -lt $Script:CRITICAL_DAYS) { $isCritical = $true }

    if ($isCritical) {
        $result.Status = "Critical"
    }
    elseif ($null -ne $result.NumericDays -and $result.NumericDays -ge $Script:ATTENTION_DAYS_LOW -and $result.NumericDays -le $Script:ATTENTION_DAYS_HIGH) {
        $result.Status = "Attention"
    }
    elseif ($dailyGrowth -lt 0) {
        $result.Status = "Declining"
    }
    elseif ($dailyGrowth -ge $Script:GROWING_THRESHOLD_GB_DAY -and ($null -eq $result.NumericDays -or $result.NumericDays -gt $Script:ATTENTION_DAYS_HIGH)) {
        $result.Status = "Growing"
    }
    else {
        $result.Status = "Stable"
    }

    if ($isLimited) {
        $result.Status = "$($result.Status) (Limited)"
    }

    Write-VerboseLog "Drive $($DriveRecord.drive_letter): $pointCount points, Status: $($result.Status)"
    return $result
}

# ============================================================================
# PRIORITY RANKING
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

function Sort-DriveAnalyses {
    param([array]$Analyses)

    $online = @($Analyses | Where-Object { $_.DriveStatus -ne "Offline" })
    $offline = @($Analyses | Where-Object { $_.DriveStatus -eq "Offline" })

    $sorted = @($online | Sort-Object -Property @(
        @{ Expression = { Get-StatusSortPriority $_.Status }; Ascending = $true },
        @{ Expression = { if ($null -ne $_.NumericDays) { $_.NumericDays } else { [double]::MaxValue } }; Ascending = $true },
        @{ Expression = { $_.Letter }; Ascending = $true }
    ))

    $offlineSorted = @($offline | Sort-Object -Property Letter)

    $result = @()
    if ($sorted.Count -gt 0) { $result += $sorted }
    if ($offlineSorted.Count -gt 0) { $result += $offlineSorted }
    return $result
}

# ============================================================================
# SVG LINE CHART GENERATION
# ============================================================================
function Build-SvgChart {
    <#
    .SYNOPSIS
        Generates an inline SVG line chart of storage usage trends for all drives.
        Dynamically sizes the viewBox to accommodate the legend without clipping.
    #>
    param([array]$DriveAnalyses)

    $chartWidth = 680
    $mLeft = 52
    $mRight = 12
    $mTop = 8
    $plotH = 192
    $plotW = $chartWidth - $mLeft - $mRight

    # Pre-build legend items to calculate required SVG height
    $legendItems = [System.Collections.ArrayList]::new()
    foreach ($analysis in $DriveAnalyses) {
        $color = $Script:CHART_COLORS[$legendItems.Count % $Script:CHART_COLORS.Count]
        $rawLabel = ($analysis.Letter -replace ':$', '')
        if ($analysis.DriveType -eq 'OS') { $rawLabel += " (OS)" }
        $label = [System.Net.WebUtility]::HtmlEncode($rawLabel)
        [void]$legendItems.Add(@{ Label = $label; Color = $color })
    }

    # Calculate legend row count to size the SVG dynamically
    if ($legendItems.Count -gt 0) {
        $legendRows = 1
        $testX = $mLeft
        foreach ($item in $legendItems) {
            $testX += 28 + ($item.Label.Length * 6)
            if ($testX -gt ($chartWidth - 20)) {
                $testX = $mLeft
                $legendRows++
            }
        }
        $mBottom = 30 + ($legendRows * 16) + 6
    }
    else {
        $mBottom = 40
    }
    $chartHeight = $mTop + $plotH + $mBottom

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<svg width=`"100%`" viewBox=`"0 0 $chartWidth $chartHeight`" xmlns=`"http://www.w3.org/2000/svg`" style=`"font-family:'Segoe UI',system-ui,sans-serif`">")

    # Background
    [void]$sb.Append("<rect width=`"$chartWidth`" height=`"$chartHeight`" fill=`"#fff`" rx=`"4`"/>")

    # Collect all dates for global range
    $allDates = [System.Collections.ArrayList]::new()
    foreach ($analysis in $DriveAnalyses) {
        if (-not $analysis.Metrics) { continue }
        foreach ($m in $analysis.Metrics) {
            $d = ConvertTo-SafeDateTime $m.timestamp
            if ($d) { [void]$allDates.Add($d) }
        }
    }

    if ($allDates.Count -eq 0) {
        [void]$sb.Append("<text x=`"$([math]::Round($chartWidth/2))`" y=`"$([math]::Round($chartHeight/2))`" text-anchor=`"middle`" fill=`"#94a3b8`" font-size=`"13`">Collecting data...</text>")
        [void]$sb.Append("</svg>")
        return $sb.ToString()
    }

    $sortedDates = $allDates | Sort-Object
    $minDate = $sortedDates[0]
    $maxDate = $sortedDates[-1]
    $dateRange = [math]::Max(1, ($maxDate - $minDate).TotalDays)

    # Horizontal gridlines at 0%, 25%, 50%, 75%, 100%
    foreach ($pct in @(0, 25, 50, 75, 100)) {
        $y = [math]::Round($mTop + $plotH - ($pct / 100 * $plotH), 1)
        $gridColor = if ($pct -eq 0 -or $pct -eq 100) { '#cbd5e1' } else { '#f1f5f9' }
        [void]$sb.Append("<line x1=`"$mLeft`" y1=`"$y`" x2=`"$($mLeft + $plotW)`" y2=`"$y`" stroke=`"$gridColor`" stroke-width=`".5`"/>")
        [void]$sb.Append("<text x=`"$($mLeft - 4)`" y=`"$($y + 3)`" text-anchor=`"end`" fill=`"#94a3b8`" font-size=`"9`">${pct}%</text>")
    }

    # X-axis date labels (up to 7 labels)
    $labelCount = [math]::Min(7, [math]::Max(2, [math]::Floor($dateRange)))
    $labelInterval = $dateRange / ($labelCount - 1)
    for ($i = 0; $i -lt $labelCount; $i++) {
        $dayOffset = $i * $labelInterval
        $x = [math]::Round($mLeft + ($dayOffset / $dateRange * $plotW), 1)
        $dateLabel = $minDate.AddDays($dayOffset).ToString("MM/dd")
        [void]$sb.Append("<text x=`"$x`" y=`"$($mTop + $plotH + 14)`" text-anchor=`"middle`" fill=`"#94a3b8`" font-size=`"9`">$dateLabel</text>")
    }

    # Plot lines for each drive (using pre-built legend items for consistent colors)
    $colorIdx = 0
    foreach ($analysis in $DriveAnalyses) {
        $color = $legendItems[$colorIdx].Color
        $colorIdx++

        if (-not $analysis.Metrics -or $analysis.Metrics.Count -eq 0) { continue }

        $points = [System.Collections.ArrayList]::new()
        foreach ($m in ($analysis.Metrics | Sort-Object timestamp)) {
            $d = ConvertTo-SafeDateTime $m.timestamp
            if (-not $d) { continue }

            $x = [math]::Round($mLeft + (($d - $minDate).TotalDays / $dateRange * $plotW), 1)
            $y = [math]::Round($mTop + $plotH - ([double]$m.usagePercent / 100 * $plotH), 1)
            [void]$points.Add("$x,$y")
        }

        if ($points.Count -gt 1) {
            [void]$sb.Append("<polyline points=`"$($points -join ' ')`" fill=`"none`" stroke=`"$color`" stroke-width=`"2`" stroke-linejoin=`"round`" stroke-linecap=`"round`"/>")
        }
        elseif ($points.Count -eq 1) {
            $coords = $points[0] -split ','
            [void]$sb.Append("<circle cx=`"$($coords[0])`" cy=`"$($coords[1])`" r=`"3`" fill=`"$color`"/>")
        }
    }

    # Legend row at bottom
    $legendY = $mTop + $plotH + 30
    $legendX = $mLeft
    foreach ($item in $legendItems) {
        [void]$sb.Append("<line x1=`"$legendX`" y1=`"$legendY`" x2=`"$($legendX + 16)`" y2=`"$legendY`" stroke=`"$($item.Color)`" stroke-width=`"2.5`" stroke-linecap=`"round`"/>")
        [void]$sb.Append("<text x=`"$($legendX + 20)`" y=`"$($legendY + 3)`" fill=`"#475569`" font-size=`"10`">$($item.Label)</text>")

        $legendX += 28 + ($item.Label.Length * 6)
        if ($legendX -gt ($chartWidth - 20)) {
            $legendX = $mLeft
            $legendY += 16
        }
    }

    [void]$sb.Append("</svg>")
    return $sb.ToString()
}

# ============================================================================
# HTML STORAGE REPORT
# ============================================================================
function Build-StorageReport {
    <#
    .SYNOPSIS
        Generates a complete HTML storage report with SVG chart and summary table.
        Designed for Ninja RMM WYSIWYG custom field.
    #>
    param(
        [string]$Hostname,
        [string]$ServerStatus,
        [array]$AllAnalyses
    )

    # Status color mapping
    $statusColors = @{
        "Critical"          = @{ bg = '#dc2626'; grad = 'linear-gradient(135deg,#dc2626,#991b1b)' }
        "Attention"         = @{ bg = '#ea580c'; grad = 'linear-gradient(135deg,#ea580c,#c2410c)' }
        "Growing"           = @{ bg = '#d97706'; grad = 'linear-gradient(135deg,#d97706,#b45309)' }
        "Stable"            = @{ bg = '#16a34a'; grad = 'linear-gradient(135deg,#16a34a,#15803d)' }
        "Declining"         = @{ bg = '#2563eb'; grad = 'linear-gradient(135deg,#2563eb,#1d4ed8)' }
        "Insufficient Data" = @{ bg = '#64748b'; grad = 'linear-gradient(135deg,#64748b,#475569)' }
    }
    $statusBadgeColors = @{
        "Critical"          = @{ bg = '#fef2f2'; fg = '#dc2626'; border = '#fecaca' }
        "Attention"         = @{ bg = '#fff7ed'; fg = '#ea580c'; border = '#fed7aa' }
        "Growing"           = @{ bg = '#fffbeb'; fg = '#d97706'; border = '#fde68a' }
        "Stable"            = @{ bg = '#f0fdf4'; fg = '#16a34a'; border = '#bbf7d0' }
        "Declining"         = @{ bg = '#eff6ff'; fg = '#2563eb'; border = '#bfdbfe' }
        "Insufficient Data" = @{ bg = '#f8fafc'; fg = '#64748b'; border = '#e2e8f0' }
        "Offline"           = @{ bg = '#f8fafc'; fg = '#94a3b8'; border = '#e2e8f0' }
    }

    $headerColor = $statusColors[$ServerStatus]
    if (-not $headerColor) { $headerColor = $statusColors["Insufficient Data"] }

    $now = (Get-Date).ToString("yyyy-MM-dd HH:mm")
    $driveCount = $AllAnalyses.Count
    $measureResult = ($AllAnalyses | ForEach-Object { $_.DataPoints } | Measure-Object -Sum)
    $totalPoints = if ($null -ne $measureResult.Sum) { [int]$measureResult.Sum } else { 0 }

    # Build SVG chart
    $svgChart = Build-SvgChart -DriveAnalyses $AllAnalyses

    # HTML-encode interpolated values to prevent injection via volume labels, hostname, or status
    $safeHostname = [System.Net.WebUtility]::HtmlEncode($Hostname)
    $safeServerStatus = [System.Net.WebUtility]::HtmlEncode($ServerStatus)

    # Build summary table rows
    $tableRows = [System.Text.StringBuilder]::new()
    $rowIndex = 0
    foreach ($a in $AllAnalyses) {
        $color = $Script:CHART_COLORS[$rowIndex % $Script:CHART_COLORS.Count]

        $letterDisplay = [System.Net.WebUtility]::HtmlEncode(($a.Letter -replace ':$', ''))
        $typeTag = if ($a.DriveType -eq 'OS') { ' <span style="font-size:9px;color:#64748b">(OS)</span>' } else { '' }
        $safeLabel = if ($a.VolumeLabel) { [System.Net.WebUtility]::HtmlEncode($a.VolumeLabel) } else { '' }
        $labelDisplay = if ($safeLabel) { " <span style=`"color:#94a3b8`">$safeLabel</span>" } else { '' }

        $baseStatus = $a.Status -replace '\s*\(Limited\)', ''
        $badge = $statusBadgeColors[$baseStatus]
        if (-not $badge) { $badge = $statusBadgeColors["Offline"] }
        $statusDisplay = [System.Net.WebUtility]::HtmlEncode($a.Status)
        $statusHtml = "<span style=`"display:inline-block;padding:1px 7px;border-radius:10px;font-size:10px;font-weight:500;background:$($badge.bg);color:$($badge.fg);border:1px solid $($badge.border)`">$statusDisplay</span>"

        $sizeStr = if ($a.TotalSizeGB -gt 0) { "$([math]::Round($a.TotalSizeGB, 0)) GB" } else { '-' }
        $usedStr = if ($a.CurrentUsedGB -gt 0) { "$([math]::Round($a.CurrentUsedGB, 1)) GB" } else { '-' }
        $freeStr = if ($a.CurrentFreeGB -gt 0) { "$([math]::Round($a.CurrentFreeGB, 1)) GB" } else { '-' }

        $growthStr = $a.GBPerMonth

        $daysStr = $a.DaysUntilFull
        $capStr = ([double]$Script:DAYS_CAP).ToString("F2", [System.Globalization.CultureInfo]::InvariantCulture)
        if ($daysStr -eq $capStr) {
            $capYears = [math]::Round($Script:DAYS_CAP / 365, 0)
            $daysStr = "${capYears}yr+"
        }
        elseif ($daysStr -match '^\d+\.\d+$') {
            $daysVal = [double]$daysStr
            if ($daysVal -ge 365) { $daysStr = "$([math]::Round($daysVal / 365, 1))yr" }
            elseif ($daysVal -ge 30) { $daysStr = "$([math]::Round($daysVal / 30, 1))mo" }
            else { $daysStr = "$([math]::Round($daysVal, 0))d" }
        }

        $rowBg = if ($rowIndex % 2 -eq 0) { '#ffffff' } else { '#f8fafc' }

        [void]$tableRows.Append(@"
<tr style="background:$rowBg;border-bottom:1px solid #f1f5f9">
<td style="padding:5px 6px"><span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:$color;margin-right:4px;vertical-align:middle"></span><strong>$letterDisplay</strong>$typeTag$labelDisplay</td>
<td style="padding:5px 6px;text-align:right">$sizeStr</td>
<td style="padding:5px 6px;text-align:right">$usedStr</td>
<td style="padding:5px 6px;text-align:right">$freeStr</td>
<td style="padding:5px 6px;text-align:right">$growthStr</td>
<td style="padding:5px 6px;text-align:right">$daysStr</td>
<td style="padding:5px 6px;text-align:center">$statusHtml</td>
</tr>
"@)
        $rowIndex++
    }

    # Assemble full HTML report
    $html = @"
<div style="font-family:'Segoe UI',system-ui,-apple-system,sans-serif;max-width:720px;background:#fff;border:1px solid #e2e8f0;border-radius:8px;overflow:hidden">
<div style="background:$($headerColor.grad);padding:10px 14px;color:#fff">
<div style="font-size:14px;font-weight:600">$safeHostname</div>
<div style="font-size:11px;opacity:.85">Storage: $safeServerStatus | $now</div>
</div>
<div style="padding:10px 6px 2px">
$svgChart
</div>
<div style="padding:0 6px 6px">
<table style="width:100%;border-collapse:collapse;font-size:11px">
<thead><tr style="background:#f1f5f9;border-bottom:2px solid #e2e8f0">
<th style="padding:5px 6px;text-align:left">Drive</th>
<th style="padding:5px 6px;text-align:right">Size</th>
<th style="padding:5px 6px;text-align:right">Used</th>
<th style="padding:5px 6px;text-align:right">Free</th>
<th style="padding:5px 6px;text-align:right">GB/Mo</th>
<th style="padding:5px 6px;text-align:right">Full</th>
<th style="padding:5px 6px;text-align:center">Status</th>
</tr></thead>
<tbody>
$($tableRows.ToString())
</tbody>
</table>
</div>
<div style="padding:6px 14px;background:#f8fafc;border-top:1px solid #e2e8f0;font-size:10px;color:#94a3b8">
v$($Script:VERSION) | $driveCount drives | $totalPoints pts | OLS regression | SQLite
</div>
</div>
"@

    return $html
}

# ============================================================================
# ALERTING (Event Log)
# ============================================================================
function Initialize-EventSource {
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($Script:EVENT_SOURCE)) {
            New-EventLog -LogName Application -Source $Script:EVENT_SOURCE -ErrorAction Stop | Out-Null
            Write-VerboseLog "Event log source '$($Script:EVENT_SOURCE)' registered"
        }
    }
    catch {
        Write-Log "WARNING: Could not register event log source: $_"
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

# ============================================================================
# NINJA RMM INTEGRATION (single WYSIWYG field)
# ============================================================================
function Update-NinjaField {
    <#
    .SYNOPSIS
        Writes the HTML storage report to a single Ninja RMM WYSIWYG custom field.
        Requires a WYSIWYG field named 'storageReport' in Ninja RMM.
    #>
    param([string]$HtmlReport)

    $runningInNinja = $null -ne (Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue)
    if (-not $runningInNinja) { return $false }

    try {
        Ninja-Property-Set $Script:FIELD_STORAGE_REPORT $HtmlReport
        return $true
    }
    catch {
        Write-Log "ERROR: Failed to update Ninja field: $_"
        return $false
    }
}

# ============================================================================
# CONSOLE OUTPUT
# ============================================================================
function Write-Summary {
    param(
        [string]$Hostname,
        [string]$ServerStatus,
        [array]$AllAnalyses,
        [array]$NewCriticalDrives,
        [bool]$IsNinja
    )

    Write-Log "Storage Growth Analysis - $Hostname"
    Write-Log ("$([char]0x2550)" * 63)
    Write-Log ""

    # OS Drive first
    $osDrive = $AllAnalyses | Where-Object { $_.DriveType -eq 'OS' } | Select-Object -First 1
    if ($osDrive) {
        Write-Log "OS DRIVE ($($osDrive.Letter))"
        $labelDisplay = if ($osDrive.VolumeLabel) { $osDrive.VolumeLabel } else { $osDrive.Letter }
        Write-Log "  Drive $($osDrive.Letter) ($labelDisplay)"

        if ($osDrive.CurrentUsedGB -gt 0 -or $osDrive.CurrentFreeGB -gt 0) {
            Write-Log "  Current: $($osDrive.CurrentUsedGB.ToString('F1')) / $($osDrive.TotalSizeGB.ToString('F1')) GB ($($osDrive.CurrentPercent.ToString('F1'))%)"
        }

        $baseStatus = $osDrive.Status -replace '\s*\(Limited\)', ''
        if ($baseStatus -ne "Insufficient Data" -and $baseStatus -ne "Offline") {
            Write-Log "  Growth:  $($osDrive.GBPerMonth) GB/month"
            $daysDisplay = $osDrive.DaysUntilFull
            if ($daysDisplay -match '^\d') { $daysDisplay = "$daysDisplay days" }
            Write-Log "  Status:  $($osDrive.Status) ($daysDisplay)"
        }
        else {
            Write-Log "  Status:  $($osDrive.Status)"
        }
    }

    Write-Log ""
    Write-Log "DATA DRIVES"
    Write-Log ("$([char]0x2500)" * 63)

    $dataDrives = @($AllAnalyses | Where-Object { $_.DriveType -ne 'OS' })
    if ($dataDrives.Count -eq 0) {
        Write-Log "  No data drives detected"
    }
    else {
        $idx = 1
        foreach ($d in $dataDrives) {
            $labelDisplay = if ($d.VolumeLabel) { $d.VolumeLabel } else { $d.Letter }
            Write-Log "  [$idx] Drive $($d.Letter) ($labelDisplay)"

            if ($d.DriveStatus -eq "Offline") {
                Write-Log "      Status:  OFFLINE"
            }
            elseif (($d.Status -replace '\s*\(Limited\)', '') -eq "Insufficient Data") {
                Write-Log "      Status:  $($d.Status)"
            }
            else {
                if ($d.CurrentUsedGB -gt 0 -or $d.CurrentFreeGB -gt 0) {
                    Write-Log "      Current: $($d.CurrentUsedGB.ToString('F1')) / $($d.TotalSizeGB.ToString('F1')) GB ($($d.CurrentPercent.ToString('F1'))%)"
                }
                Write-Log "      Growth:  $($d.GBPerMonth) GB/month"
                $daysDisplay = $d.DaysUntilFull
                if ($daysDisplay -match '^\d') { $daysDisplay = "$daysDisplay days" }
                Write-Log "      Status:  $($d.Status) ($daysDisplay)"

                $baseSlotStatus = $d.Status -replace '\s*\(Limited\)', ''
                if ($baseSlotStatus -eq "Critical" -and $NewCriticalDrives) {
                    $isNewCritical = $d.Letter -in @($NewCriticalDrives | ForEach-Object { $_.Letter })
                    if ($isNewCritical) {
                        Write-Log "      Alert:   NEW - Event 5001 written"
                    }
                }
            }

            Write-Log ""
            $idx++
        }
    }

    Write-Log ("$([char]0x2550)" * 63)
    Write-Log "SERVER STATUS: $($ServerStatus.ToUpper())"
    Write-Log "Database: $($Script:DB_PATH)"
    Write-Log ""
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
function Main {
    $hostname = $env:COMPUTERNAME
    $deviceId = $env:COMPUTERNAME
    $runningInNinja = $null -ne (Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue)

    # -- Step 1: Initialize ---------------------------------------------------

    if (-not $runningInNinja) {
        Write-Log "*** TEST MODE - Not running in Ninja context ***"
        Write-Log "Ninja custom field updates will be skipped."
        Write-Log ""
    }

    Write-VerboseLog "PowerShell Version: $($PSVersionTable.PSVersion.ToString())"
    Write-VerboseLog "Script Version: $($Script:VERSION)"
    Write-VerboseLog "Database Path: $($Script:DB_PATH)"

    # Create storage folder
    if (-not (Test-Path $Script:STORAGE_PATH)) {
        try {
            New-Item -Path $Script:STORAGE_PATH -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-VerboseLog "Created storage folder: $($Script:STORAGE_PATH)"
        }
        catch {
            Write-Log "CRITICAL: Cannot create storage folder: $_"
            Save-LogFile
            exit 1
        }
    }

    # Initialize PSSQLite module
    if (-not (Initialize-SQLiteModule)) {
        Write-Log "CRITICAL: PSSQLite module is required. Cannot proceed."
        Save-LogFile
        exit 1
    }

    # Initialize database schema
    if (-not (Initialize-Database)) {
        Write-Log "CRITICAL: Database initialization failed. Cannot proceed."
        Save-LogFile
        exit 1
    }

    # Register event log source
    $eventLogAvailable = Initialize-EventSource

    # Register device
    Get-DeviceRecord -DeviceId $deviceId -Hostname $hostname

    # -- Step 2: Migrate Legacy Data ------------------------------------------

    # Check for existing JSON history and migrate (one-time)
    $existingDrives = @(Get-AllDeviceDrives -DeviceId $deviceId)
    if ($existingDrives.Count -eq 0) {
        Import-LegacyJsonHistory -DeviceId $deviceId
    }

    # -- Step 3: Discover & Collect -------------------------------------------

    $currentDrives = $null
    try {
        $currentDrives = @(Get-FilteredDrives)
    }
    catch {
        Write-Log "ERROR: Drive enumeration failed: $_"
        Save-LogFile
        exit 2
    }

    if ($currentDrives.Count -eq 0) {
        Write-Log "WARNING: No qualifying drives found."
    }

    # -- Step 4: Update Database ----------------------------------------------

    $now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    $visibleLetters = @($currentDrives | ForEach-Object { $_.Letter })

    # Upsert drives and record daily metrics (idempotent per calendar day)
    foreach ($drive in $currentDrives) {
        $driveId = Save-DriveRecord -DeviceId $deviceId -DriveLetter $drive.Letter `
            -VolumeLabel $drive.VolumeLabel -TotalSizeGB $drive.TotalSizeGB `
            -DriveType $drive.DriveType -Status "Online"

        Set-DailyMetric -DriveId $driveId -Timestamp $now `
            -UsedGB $drive.UsedGB -FreeGB $drive.FreeGB -UsagePercent $drive.UsagePercent

        Write-VerboseLog "Drive $($drive.Letter): Metric recorded (Used: $($drive.UsedGB) GB, Free: $($drive.FreeGB) GB)"
    }

    # Mark drives not currently visible as Offline
    $allDrives = @(Get-AllDeviceDrives -DeviceId $deviceId)
    foreach ($dbDrive in $allDrives) {
        if ($dbDrive.drive_letter -notin $visibleLetters -and $dbDrive.status -ne "Offline") {
            Write-VerboseLog "Drive $($dbDrive.drive_letter): No longer visible - marking Offline"
            Set-DriveOffline -DriveId $dbDrive.id
        }
    }

    # Remove drives offline > 30 days
    $removedCount = Remove-StaleDrives -DeviceId $deviceId
    if ($removedCount -gt 0) {
        Write-Log "Removed $removedCount stale drives (offline > $($Script:OFFLINE_REMOVAL_DAYS) days)"
    }

    # Prune old metrics
    Remove-OldMetrics

    # -- Step 5: Analyze All Drives -------------------------------------------

    $allDrives = @(Get-AllDeviceDrives -DeviceId $deviceId)
    $allAnalyses = [System.Collections.ArrayList]::new()

    foreach ($dbDrive in $allDrives) {
        $metrics = @(Get-DriveMetrics -DriveId $dbDrive.id)
        $analysis = Get-DriveAnalysis -DriveRecord $dbDrive -Metrics $metrics
        [void]$allAnalyses.Add($analysis)
    }

    # Sort: OS first, then data drives by criticality
    $osAnalyses = @($allAnalyses | Where-Object { $_.DriveType -eq 'OS' })
    $dataAnalyses = @($allAnalyses | Where-Object { $_.DriveType -ne 'OS' })
    $sortedData = @(Sort-DriveAnalyses -Analyses $dataAnalyses)

    $sortedAll = [System.Collections.ArrayList]::new()
    foreach ($a in $osAnalyses) { [void]$sortedAll.Add($a) }
    foreach ($a in $sortedData) { [void]$sortedAll.Add($a) }

    # -- Step 6: Server Status ------------------------------------------------

    $worstSeverity = 0
    $serverStatus = "Insufficient Data"

    $onlineAnalyses = @($allAnalyses | Where-Object { $_.DriveStatus -ne "Offline" })
    foreach ($analysis in $onlineAnalyses) {
        $severity = Get-ServerStatusSeverity -Status $analysis.Status
        if ($severity -gt $worstSeverity) {
            $worstSeverity = $severity
            $serverStatus = $analysis.Status -replace '\s*\(Limited\)', ''
        }
    }

    # -- Step 7: Critical Drive Alerts (fire-once) ----------------------------

    $newCriticalDrives = [System.Collections.ArrayList]::new()

    foreach ($analysis in $allAnalyses) {
        $baseStatus = $analysis.Status -replace '\s*\(Limited\)', ''

        if ($baseStatus -eq "Critical") {
            if (-not $analysis.AlertSent) {
                [void]$newCriticalDrives.Add($analysis)
                Set-DriveAlertSent -DriveId $analysis.DriveId -AlertSent $true
                Write-VerboseLog "Drive $($analysis.Letter): NEW Critical - writing Event 5001"
            }
        }
        else {
            if ($analysis.AlertSent) {
                Set-DriveAlertSent -DriveId $analysis.DriveId -AlertSent $false
                Write-VerboseLog "Drive $($analysis.Letter): No longer Critical, resetting alert"
            }
        }
    }

    if ($newCriticalDrives.Count -gt 0 -and $eventLogAvailable) {
        Write-CriticalAlert -CriticalDrives $newCriticalDrives -Hostname $hostname
    }

    # -- Step 8: Generate Report & Output -------------------------------------

    # Console summary
    Write-Summary -Hostname $hostname -ServerStatus $serverStatus -AllAnalyses @($sortedAll) `
        -NewCriticalDrives $newCriticalDrives -IsNinja $runningInNinja

    # Build HTML report with SVG chart
    $htmlReport = Build-StorageReport -Hostname $hostname -ServerStatus $serverStatus -AllAnalyses @($sortedAll)

    # Update Ninja WYSIWYG field
    if ($runningInNinja) {
        $ninjaSuccess = Update-NinjaField -HtmlReport $htmlReport
        if ($ninjaSuccess) {
            Write-Log ([char]0x2713 + " WYSIWYG field '$($Script:FIELD_STORAGE_REPORT)' updated")
        }
    }
    else {
        Write-Log "*** TEST MODE - Ninja field not updated ***"
        Write-VerboseLog "HTML report generated ($($htmlReport.Length) chars)"
    }

    # -- Step 9: Finalize -----------------------------------------------------

    # Log database stats
    $totalDrives = $allDrives.Count
    try {
        $totalMetrics = Invoke-SqliteQuery -DataSource $Script:DB_PATH -Query "SELECT COUNT(*) AS cnt FROM metric" -ErrorAction Stop
        $metricCount = if ($totalMetrics) { $totalMetrics.cnt } else { 0 }
    }
    catch { $metricCount = '?' }
    Write-Log ([char]0x2713 + " Database updated ($totalDrives drives, $metricCount data points)")

    # Write log file
    Save-LogFile

    exit 0
}

# ============================================================================
# ENTRY POINT
# ============================================================================
Main
