## PLEASE SET THE FOLLOWING ENVIRONMENT VARIABLES IN YOUR RMM BEFORE RUNNING
## $env:CUSTOM_FIELD_S3_BUCKET_NAME  - Text field: last used S3 bucket name
## $env:CUSTOM_FIELD_S3_BUCKET_SIZE  - Text field: last used S3 bucket size (human readable)
## $env:CUSTOM_FIELD_S3_ORPHANS_FOUND - Integer field: 1 if orphaned backups found, 0 if not
## $env:CUSTOM_FIELD_S3_INVENTORY    - WYSIWYG field: HTML table of all S3 repos
## $env:CUSTOM_FIELD_S3_ORPHANS      - WYSIWYG field: HTML table of orphaned backup data
## $env:ORPHAN_DAYS_THRESHOLD        - Days since last backup to consider orphaned (default: 30)
## $env:DESCRIPTION                  - Ticket # or initials for audit trail
## $env:RMM                          - Set to 1 when running from RMM platform
## $env:RMM_SCRIPT_PATH              - Script path provided by RMM (used for log location)

# ============================================================
# PS7 BOOTSTRAP
# Veeam.Backup.PowerShell in Veeam 12.x requires PowerShell 7+.
# If running under PS5, re-launch this script in pwsh.exe.
# ============================================================
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $PWSH_CANDIDATE = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    $PWSH_PATH = if ($PWSH_CANDIDATE) { $PWSH_CANDIDATE.Source } else { $null }
    if (-not $PWSH_PATH) {
        $PWSH_PATH = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    }
    if (Test-Path $PWSH_PATH) {
        Write-Host "PowerShell $($PSVersionTable.PSVersion) detected. Re-launching in PowerShell 7 at: $PWSH_PATH"
        $PS_ARGS = @('-NonInteractive', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path)
        & $PWSH_PATH @PS_ARGS
        exit $LASTEXITCODE
    } else {
        Write-Warning "PowerShell 7 (pwsh.exe) not found. Attempting to continue in PS$($PSVersionTable.PSVersion.Major), but Veeam module load may fail."
    }
}

# ============================================================
# HELPER FUNCTIONS
# ============================================================

function Format-SizeBytes {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function ConvertTo-SafeHtml {
    param([string]$Text)
    if (-not $Text) { return "" }
    return $Text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}

function Build-HtmlTable {
    param(
        [string[]]$Headers,
        [System.Collections.Generic.List[string[]]]$Rows,
        [string]$ScanTimestamp,
        [string]$EmptyMessage = "No data found."
    )

    $HEADER_CELLS = ""
    foreach ($H in $Headers) {
        $HEADER_CELLS += "                <th style=`"padding:10px 12px;text-align:left;font-weight:600;color:#374151;border-bottom:2px solid #d1d5db;`">$(ConvertTo-SafeHtml $H)</th>`n"
    }

    $DATA_ROWS = ""
    if ($Rows.Count -eq 0) {
        $DATA_ROWS = @"
        <tr>
            <td colspan="$($Headers.Count)" style="text-align:center;color:#6b7280;font-style:italic;padding:16px 12px;">
                $EmptyMessage
            </td>
        </tr>
"@
    } else {
        $ROW_INDEX = 0
        foreach ($ROW in $Rows) {
            $BG = if ($ROW_INDEX % 2 -eq 0) { "#ffffff" } else { "#f9fafb" }
            $CELLS = ""
            foreach ($CELL in $ROW) {
                $CELLS += "            <td style=`"padding:8px 12px;border-bottom:1px solid #e5e7eb;`">$(ConvertTo-SafeHtml $CELL)</td>`n"
            }
            $DATA_ROWS += @"
        <tr style="background-color:$BG;">
$CELLS        </tr>
"@
            $ROW_INDEX++
        }
    }

    return @"
<div style="font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#111827;">
    <table style="width:100%;border-collapse:collapse;border:1px solid #d1d5db;border-radius:4px;overflow:hidden;">
        <thead>
            <tr style="background-color:#f3f4f6;">
$HEADER_CELLS            </tr>
        </thead>
        <tbody>
$DATA_ROWS        </tbody>
    </table>
    <p style="margin:8px 0 0;font-size:11px;color:#6b7280;">Last scanned: $ScanTimestamp</p>
</div>
"@
}

function Set-NinjaField {
    param([string]$FieldName, [string]$Value)
    if (-not $FieldName) { return }
    $NINJA_CMD = Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue
    if ($NINJA_CMD) {
        try {
            Ninja-Property-Set $FieldName $Value
            Write-Host "  [OK] $FieldName updated."
        } catch {
            Write-Warning "  Failed to write $FieldName : $_"
        }
    } else {
        Write-Host "  [SKIP] Ninja-Property-Set not available. $FieldName = $($Value.Substring(0, [Math]::Min(100, $Value.Length)))..."
    }
}

# ============================================================
# SECTION 1: RMM VARIABLE DECLARATION
# ============================================================

$SCRIPT_LOG_NAME = "veeam-s3-bucket-inventory.log"

# ============================================================
# SECTION 2: INPUT HANDLING
# ============================================================

if ($env:RMM -ne "1") {
    # Interactive mode
    $VALID_INPUT = 0
    while ($VALID_INPUT -ne 1) {
        $env:DESCRIPTION = Read-Host "Please enter the ticket # and/or your initials (used for audit trail)"
        if ($env:DESCRIPTION) {
            $VALID_INPUT = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }

    $env:CUSTOM_FIELD_S3_BUCKET_NAME = Read-Host "NinjaOne text field for S3 bucket name (blank to skip)"
    $env:CUSTOM_FIELD_S3_BUCKET_SIZE = Read-Host "NinjaOne text field for S3 bucket size (blank to skip)"
    $env:CUSTOM_FIELD_S3_ORPHANS_FOUND = Read-Host "NinjaOne integer field for orphans found flag (blank to skip)"
    $env:CUSTOM_FIELD_S3_INVENTORY = Read-Host "NinjaOne WYSIWYG field for S3 inventory table (blank to skip)"
    $env:CUSTOM_FIELD_S3_ORPHANS = Read-Host "NinjaOne WYSIWYG field for orphaned backups table (blank to skip)"

    $LOG_PATH = "$env:WINDIR\logs\$SCRIPT_LOG_NAME"

} else {
    # RMM mode
    if ($env:RMM_SCRIPT_PATH) {
        $LOG_DIR = "$env:RMM_SCRIPT_PATH\logs"
        if (-not (Test-Path $LOG_DIR)) {
            New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
        }
        $LOG_PATH = "$LOG_DIR\$SCRIPT_LOG_NAME"
    } else {
        $LOG_PATH = "$env:WINDIR\logs\$SCRIPT_LOG_NAME"
    }

    if (-not $env:DESCRIPTION) {
        Write-Host "DESCRIPTION is null. This was most likely run automatically from the RMM with no description passed."
        $env:DESCRIPTION = "No Description"
    }
}

# ============================================================
# SECTION 3: SCRIPT LOGIC
# ============================================================

Start-Transcript -Path $LOG_PATH

Write-Host "=== Veeam S3 Bucket Inventory ==="
Write-Host "Description:  $env:DESCRIPTION"
Write-Host "Log path:     $LOG_PATH"
Write-Host "RMM mode:     $($env:RMM -eq '1')"
Write-Host "PS version:   $($PSVersionTable.PSVersion)"
Write-Host ""

# ------------------------------------------------------------
# Load Veeam PowerShell module
# ------------------------------------------------------------
Write-Host "Loading Veeam PowerShell module..."
$MY_MODULE_PATH = "C:\Program Files\Veeam\Backup and Replication\Console\"
$env:PSModulePath = $env:PSModulePath + "$([System.IO.Path]::PathSeparator)$MY_MODULE_PATH"

if ($VBR_MODULES = Get-Module -ListAvailable -Name Veeam.Backup.PowerShell) {
    try {
        $VBR_MODULES | Import-Module -WarningAction SilentlyContinue
        Write-Host "  [OK] Veeam module loaded."
    } catch {
        Stop-Transcript
        throw "Failed to load Veeam modules: $_"
    }
} else {
    Stop-Transcript
    throw "Veeam.Backup.PowerShell module not found. Is the Veeam console installed on this machine?"
}

# ------------------------------------------------------------
# Collect data from Veeam
# ------------------------------------------------------------
Write-Host ""
Write-Host "Querying Veeam data..."

$SCAN_TIMESTAMP = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Get object storage repos
$OBJECT_STORAGE_REPOS = $null
try {
    $OBJECT_STORAGE_REPOS = Get-VBRObjectStorageRepository -ErrorAction Stop
    Write-Host "  [OK] Found $($OBJECT_STORAGE_REPOS.Count) object storage repositories."
} catch {
    Write-Warning "  Get-VBRObjectStorageRepository failed: $_"
}
if (-not $OBJECT_STORAGE_REPOS) {
    try {
        $OBJECT_STORAGE_REPOS = Get-VBRBackupRepository | Where-Object {
            $_.Type -like "AmazonS3*" -or $_.Type -eq "S3Compatible" -or $_.Type -match "S3"
        }
        Write-Host "  [OK] Fallback found $($OBJECT_STORAGE_REPOS.Count) S3-compatible repositories."
    } catch {
        Write-Warning "  Fallback query failed: $_"
    }
}

# Get backup copy jobs (TargetRepository has populated AmazonCompatibleOptions)
Write-Host "  Querying backup copy jobs..."
$COPY_JOBS = @()
$COPY_JOB_REPOS = @{}
try {
    $COPY_JOBS = @(Get-VBRBackupCopyJob -ErrorAction Stop)
    foreach ($CJ in $COPY_JOBS) {
        if ($null -ne $CJ.TargetRepository) {
            $TR = $CJ.TargetRepository
            $COPY_JOB_REPOS[$TR.Id.ToString()] = $TR
        }
    }
    Write-Host "  [OK] Found $($COPY_JOBS.Count) backup copy jobs."
} catch {
    Write-Warning "  Get-VBRBackupCopyJob failed: $_"
}

# Get all backups and enumerate child backups for S3 repos
Write-Host "  Enumerating backups and child backups..."
$ALL_BACKUPS = @()
try { $ALL_BACKUPS = @(Get-VBRBackup) } catch { Write-Warning "  Get-VBRBackup failed: $_" }

# Orphan threshold: child backups with no new data in this many days are stale
$ORPHAN_DAYS = 30
if ($env:ORPHAN_DAYS_THRESHOLD) {
    try { $ORPHAN_DAYS = [int]$env:ORPHAN_DAYS_THRESHOLD } catch {}
}
$ORPHAN_CUTOFF = (Get-Date).AddDays(-$ORPHAN_DAYS)
Write-Host "  Orphan threshold: $ORPHAN_DAYS days (before $($ORPHAN_CUTOFF.ToString('yyyy-MM-dd')))"

# Build a set of active copy job IDs targeting S3 repos
$SIZE_BY_REPO_ID = @{}
$CHILDREN_BY_REPO_ID = @{}
$S3_REPO_IDS = @{}
foreach ($REPO in $OBJECT_STORAGE_REPOS) {
    $S3_REPO_IDS[$REPO.Id.ToString()] = $true
}
$ACTIVE_COPY_JOB_IDS = @{}
foreach ($CJ in $COPY_JOBS) {
    if ($null -ne $CJ.TargetRepository -and $S3_REPO_IDS.ContainsKey($CJ.TargetRepository.Id.ToString())) {
        $ACTIVE_COPY_JOB_IDS[$CJ.Id.ToString()] = $true
    }
}

# Enumerate S3-targeted backups for size + child details
foreach ($BACKUP in $ALL_BACKUPS) {
    $RID = $BACKUP.RepositoryId.ToString()
    if (-not $S3_REPO_IDS.ContainsKey($RID)) { continue }

    if (-not $SIZE_BY_REPO_ID.ContainsKey($RID)) { $SIZE_BY_REPO_ID[$RID] = [long]0 }
    if (-not $CHILDREN_BY_REPO_ID.ContainsKey($RID)) { $CHILDREN_BY_REPO_ID[$RID] = [System.Collections.Generic.List[hashtable]]::new() }

    $BACKUPS_TO_CHECK = @($BACKUP)
    try {
        if ($BACKUP.IsTruePerVmContainer) {
            $CHILDREN = $BACKUP.FindChildBackups()
            if ($CHILDREN) { $BACKUPS_TO_CHECK = @($CHILDREN) }
        }
    } catch { }

    foreach ($B in $BACKUPS_TO_CHECK) {
        $CHILD_SIZE = [long]0
        $LAST_POINT_TIME = $null
        try {
            $STORAGES = $B.GetAllStorages()
            foreach ($ST in $STORAGES) {
                $ST_SIZE = [long]0
                try { if ($ST.Stats -and $ST.Stats.BackupSize -gt 0) { $ST_SIZE = [long]$ST.Stats.BackupSize } } catch {}
                if ($ST_SIZE -eq 0) { try { if ($ST.BackupSize -gt 0) { $ST_SIZE = [long]$ST.BackupSize } } catch {} }
                $CHILD_SIZE += $ST_SIZE
            }
            # Get most recent storage creation time as proxy for last restore point
            $LATEST_STORAGE = $STORAGES | Sort-Object CreationTime -Descending | Select-Object -First 1
            if ($LATEST_STORAGE) { $LAST_POINT_TIME = $LATEST_STORAGE.CreationTime }
        } catch { }

        $SIZE_BY_REPO_ID[$RID] += $CHILD_SIZE

        # Extract machine name from child backup name (e.g. "S3 Copy 1686654096\workstations01 - BUS2")
        $MACHINE_NAME = "Unknown"
        $BACKUP_DISPLAY_NAME = $B.Name
        if ($BACKUP_DISPLAY_NAME -match '\\(.+?) - (.+)$') {
            $MACHINE_NAME = $Matches[2].Trim()
        } elseif ($BACKUP_DISPLAY_NAME -match ' - (.+)$') {
            $MACHINE_NAME = $Matches[1].Trim()
        }

        # Check if this backup's parent job is an active copy job
        $PARENT_JOB_ID = $BACKUP.JobId.ToString()
        $IS_JOB_LINKED = $ACTIVE_COPY_JOB_IDS.ContainsKey($PARENT_JOB_ID)

        $CHILDREN_BY_REPO_ID[$RID].Add(@{
            Name         = $BACKUP_DISPLAY_NAME
            MachineName  = $MACHINE_NAME
            Size         = $CHILD_SIZE
            SizeDisplay  = if ($CHILD_SIZE -gt 0) { Format-SizeBytes -Bytes $CHILD_SIZE } else { "N/A" }
            LastPoint    = $LAST_POINT_TIME
            LastPointStr = if ($LAST_POINT_TIME) { $LAST_POINT_TIME.ToString("yyyy-MM-dd") } else { "N/A" }
            IsJobLinked  = $IS_JOB_LINKED
        })
    }
}

# ------------------------------------------------------------
# Build inventory rows + find the "last used" S3 bucket
# ------------------------------------------------------------
Write-Host ""
Write-Host "Processing repositories..."

$REPO_ROWS = [System.Collections.Generic.List[string[]]]::new()
$ORPHAN_ROWS = [System.Collections.Generic.List[string[]]]::new()
$ORPHAN_COUNT = 0

$LAST_USED_BUCKET = "N/A"
$LAST_USED_SIZE = "N/A"
$LAST_USED_SIZE_BYTES = [long]0
$LAST_USED_TIME = [datetime]::MinValue

foreach ($REPO in $OBJECT_STORAGE_REPOS) {
    $REPO_ID = $REPO.Id.ToString()
    Write-Host "  Processing: $($REPO.Name)"

    # --- BUCKET NAME ---
    $BUCKET_NAME = "N/A"
    if ($COPY_JOB_REPOS.ContainsKey($REPO_ID)) {
        $CJ_TR = $COPY_JOB_REPOS[$REPO_ID]
        try {
            $CJ_OPTS = $CJ_TR.AmazonCompatibleOptions
            if ($null -eq $CJ_OPTS) { $CJ_OPTS = $CJ_TR.Options }
            if ($null -ne $CJ_OPTS -and $CJ_OPTS.BucketName) {
                $BUCKET_NAME = $CJ_OPTS.BucketName
            }
        } catch { }
    }
    if ($BUCKET_NAME -eq "N/A") {
        try {
            $OPTS = $REPO.AmazonCompatibleOptions
            if ($null -eq $OPTS) { $OPTS = $REPO.AmazonOptions }
            if ($null -eq $OPTS) { $OPTS = $REPO.Options }
            if ($null -ne $OPTS -and $OPTS.BucketName) { $BUCKET_NAME = $OPTS.BucketName }
        } catch { }
    }
    if ($BUCKET_NAME -eq "N/A") {
        try { if ($REPO.BucketName) { $BUCKET_NAME = $REPO.BucketName } } catch {}
    }

    # --- USED SPACE ---
    $USED_SPACE_DISPLAY = "N/A"
    $USED_SPACE_BYTES = [long]0
    try { if ($null -ne $REPO.UsedSpace -and $REPO.UsedSpace -gt 0) { $USED_SPACE_BYTES = [long]$REPO.UsedSpace; $USED_SPACE_DISPLAY = Format-SizeBytes -Bytes $USED_SPACE_BYTES } } catch {}
    if ($USED_SPACE_DISPLAY -eq "N/A" -and $SIZE_BY_REPO_ID.ContainsKey($REPO_ID) -and $SIZE_BY_REPO_ID[$REPO_ID] -gt 0) {
        $USED_SPACE_BYTES = $SIZE_BY_REPO_ID[$REPO_ID]
        $USED_SPACE_DISPLAY = Format-SizeBytes -Bytes $USED_SPACE_BYTES
    }

    # --- REPO TYPE ---
    $REPO_TYPE = "N/A"
    try { if ($REPO.Type) { $REPO_TYPE = $REPO.Type.ToString() } } catch {}
    try { if ($REPO_TYPE -eq "N/A" -and $REPO.TypeDisplay) { $REPO_TYPE = $REPO.TypeDisplay } } catch {}

    $REPO_ROWS.Add(@($BUCKET_NAME, $REPO.Name, $REPO_TYPE, $USED_SPACE_DISPLAY))

    # --- LAST USED tracking ---
    # Find the most recent restore point time across all children in this repo
    $REPO_LATEST_TIME = [datetime]::MinValue
    if ($CHILDREN_BY_REPO_ID.ContainsKey($REPO_ID)) {
        foreach ($CHILD in $CHILDREN_BY_REPO_ID[$REPO_ID]) {
            if ($null -ne $CHILD.LastPoint -and $CHILD.LastPoint -gt $REPO_LATEST_TIME) {
                $REPO_LATEST_TIME = $CHILD.LastPoint
            }
        }
    }
    if ($REPO_LATEST_TIME -gt $LAST_USED_TIME) {
        $LAST_USED_TIME = $REPO_LATEST_TIME
        $LAST_USED_BUCKET = $BUCKET_NAME
        $LAST_USED_SIZE = $USED_SPACE_DISPLAY
        $LAST_USED_SIZE_BYTES = $USED_SPACE_BYTES
    }

    # --- ORPHAN DETECTION ---
    # Two cases:
    # 1. Unlinked: backup data in S3 not associated with any active copy job
    # 2. Stale: last backup older than threshold (machine removed from job)
    if ($CHILDREN_BY_REPO_ID.ContainsKey($REPO_ID)) {
        foreach ($CHILD in $CHILDREN_BY_REPO_ID[$REPO_ID]) {
            $REASON = $null

            if (-not $CHILD.IsJobLinked) {
                $REASON = "No active job"
            } elseif ($null -ne $CHILD.LastPoint -and $CHILD.LastPoint -lt $ORPHAN_CUTOFF) {
                $DAYS_AGO = [int]((Get-Date) - $CHILD.LastPoint).TotalDays
                $REASON = "Stale ($DAYS_AGO days)"
            }

            if ($REASON) {
                $ORPHAN_ROWS.Add(@($CHILD.MachineName, $CHILD.SizeDisplay, $CHILD.LastPointStr, $REASON, $BUCKET_NAME))
                $ORPHAN_COUNT++
            }
        }
    }
}

# If only one S3 repo exists and last-used tracking didn't match via time, use it directly
if ($LAST_USED_BUCKET -eq "N/A" -and $REPO_ROWS.Count -eq 1) {
    $LAST_USED_BUCKET = $REPO_ROWS[0][0]
    $LAST_USED_SIZE = $REPO_ROWS[0][3]
}

# ------------------------------------------------------------
# Log summary
# ------------------------------------------------------------
Write-Host ""
Write-Host "=== Results ==="
Write-Host "  Last used S3 bucket: $LAST_USED_BUCKET"
Write-Host "  Last used S3 size:   $LAST_USED_SIZE"
Write-Host "  S3 repos found:      $($REPO_ROWS.Count)"
Write-Host "  Orphaned backups:    $ORPHAN_COUNT"
Write-Host ""

if ($REPO_ROWS.Count -gt 0) {
    Write-Host "=== Inventory ==="
    foreach ($ROW in $REPO_ROWS) {
        Write-Host "  Bucket: $($ROW[0]) | Repo: $($ROW[1]) | Type: $($ROW[2]) | Size: $($ROW[3])"
    }
    Write-Host ""
}

if ($ORPHAN_COUNT -gt 0) {
    Write-Host "=== Orphaned Backups ==="
    foreach ($ROW in $ORPHAN_ROWS) {
        Write-Host "  Machine: $($ROW[0]) | Size: $($ROW[1]) | Last: $($ROW[2]) | Reason: $($ROW[3]) | Bucket: $($ROW[4])"
    }
    Write-Host ""
}

# ------------------------------------------------------------
# Build HTML tables
# ------------------------------------------------------------
$HTML_INVENTORY = Build-HtmlTable `
    -Headers @("Bucket Name", "Repository Name", "Type", "Used Space") `
    -Rows $REPO_ROWS `
    -ScanTimestamp $SCAN_TIMESTAMP `
    -EmptyMessage "No S3-compatible object storage repositories found."

$HTML_ORPHANS = Build-HtmlTable `
    -Headers @("Machine", "Size", "Last Backup", "Reason", "Bucket") `
    -Rows $ORPHAN_ROWS `
    -ScanTimestamp $SCAN_TIMESTAMP `
    -EmptyMessage "No orphaned backups detected."

# ------------------------------------------------------------
# Write to NinjaOne custom fields
# ------------------------------------------------------------
Write-Host "Writing to NinjaOne custom fields..."

Set-NinjaField $env:CUSTOM_FIELD_S3_BUCKET_NAME $LAST_USED_BUCKET
Set-NinjaField $env:CUSTOM_FIELD_S3_BUCKET_SIZE $LAST_USED_SIZE
Set-NinjaField $env:CUSTOM_FIELD_S3_ORPHANS_FOUND "$([int]($ORPHAN_COUNT -gt 0))"
Set-NinjaField $env:CUSTOM_FIELD_S3_INVENTORY $HTML_INVENTORY
Set-NinjaField $env:CUSTOM_FIELD_S3_ORPHANS $HTML_ORPHANS

# If no Ninja available and no fields set, dump HTML to console
if (-not (Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue)) {
    if (-not $env:CUSTOM_FIELD_S3_INVENTORY -and -not $env:CUSTOM_FIELD_S3_ORPHANS) {
        Write-Host ""
        Write-Host "=== Inventory HTML ==="
        Write-Host $HTML_INVENTORY
        Write-Host ""
        Write-Host "=== Orphans HTML ==="
        Write-Host $HTML_ORPHANS
    }
}

Write-Host ""
Write-Host "=== Script complete ==="

Stop-Transcript
