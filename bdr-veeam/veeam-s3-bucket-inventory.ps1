## PLEASE SET THE FOLLOWING ENVIRONMENT VARIABLES IN YOUR RMM BEFORE RUNNING
## $env:CUSTOM_FIELD_S3_INVENTORY  - Name of the NinjaOne WYSIWYG custom field to write the HTML inventory table to
## $env:DESCRIPTION                - Ticket # or initials for audit trail
## $env:RMM                        - Set to 1 when running from RMM platform
## $env:RMM_SCRIPT_PATH            - Script path provided by RMM (used for log location)

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

function Build-HtmlInventoryTable {
    param(
        [System.Collections.Generic.List[hashtable]]$Rows,
        [string]$ScanTimestamp
    )

    $DATA_ROWS = ""

    if ($Rows.Count -eq 0) {
        $DATA_ROWS = @"
        <tr>
            <td colspan="4" style="text-align:center;color:#6b7280;font-style:italic;padding:16px 12px;">
                No S3-compatible object storage repositories found.
            </td>
        </tr>
"@
    } else {
        $ROW_INDEX = 0
        foreach ($ROW in $Rows) {
            $BG = if ($ROW_INDEX % 2 -eq 0) { "#ffffff" } else { "#f9fafb" }
            $DATA_ROWS += @"
        <tr style="background-color:$BG;">
            <td style="padding:8px 12px;border-bottom:1px solid #e5e7eb;">$(ConvertTo-SafeHtml $ROW.BucketName)</td>
            <td style="padding:8px 12px;border-bottom:1px solid #e5e7eb;">$(ConvertTo-SafeHtml $ROW.RepoName)</td>
            <td style="padding:8px 12px;border-bottom:1px solid #e5e7eb;">$(ConvertTo-SafeHtml $ROW.RepoType)</td>
            <td style="padding:8px 12px;border-bottom:1px solid #e5e7eb;">$(ConvertTo-SafeHtml $ROW.UsedSpace)</td>
        </tr>
"@
            $ROW_INDEX++
        }
    }

    return @"
<div style="font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#111827;">
    <table style="width:100%;border-collapse:collapse;border:1px solid #d1d5db;border-radius:4px;overflow:hidden;">
        <thead>
            <tr style="background-color:#f3f4f6;">
                <th style="padding:10px 12px;text-align:left;font-weight:600;color:#374151;border-bottom:2px solid #d1d5db;">Bucket Name</th>
                <th style="padding:10px 12px;text-align:left;font-weight:600;color:#374151;border-bottom:2px solid #d1d5db;">Repository Name</th>
                <th style="padding:10px 12px;text-align:left;font-weight:600;color:#374151;border-bottom:2px solid #d1d5db;">Type</th>
                <th style="padding:10px 12px;text-align:left;font-weight:600;color:#374151;border-bottom:2px solid #d1d5db;">Used Space</th>
            </tr>
        </thead>
        <tbody>
$DATA_ROWS        </tbody>
    </table>
    <p style="margin:8px 0 0;font-size:11px;color:#6b7280;">Last scanned: $ScanTimestamp</p>
</div>
"@
}

# ============================================================
# SECTION 1: RMM VARIABLE DECLARATION
# ============================================================

$SCRIPT_LOG_NAME = "veeam-s3-bucket-inventory.log"

# ============================================================
# SECTION 2: INPUT HANDLING
# ============================================================

if ($env:RMM -ne "1") {
    # Interactive mode - prompt and store directly in env vars
    $VALID_INPUT = 0
    while ($VALID_INPUT -ne 1) {
        $env:DESCRIPTION = Read-Host "Please enter the ticket # and/or your initials (used for audit trail)"
        if ($env:DESCRIPTION) {
            $VALID_INPUT = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }

    $env:CUSTOM_FIELD_S3_INVENTORY = Read-Host "Enter the NinjaOne WYSIWYG custom field name to write the inventory table to (leave blank to skip)"

    $LOG_PATH = "$env:WINDIR\logs\$SCRIPT_LOG_NAME"

} else {
    # RMM mode - env vars are already set by the RMM platform
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
Write-Host "Custom field: $env:CUSTOM_FIELD_S3_INVENTORY"
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
# Collect S3-compatible object storage repositories
# ------------------------------------------------------------
Write-Host ""
Write-Host "Querying S3-compatible object storage repositories..."

$REPO_ROWS = [System.Collections.Generic.List[hashtable]]::new()
$SCAN_TIMESTAMP = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Get object storage repos (for the list of S3 repos + their IDs)
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

# Get backup copy jobs - their TargetRepository has populated sub-objects
# (Get-VBRObjectStorageRepository returns skeleton objects with null sub-objects,
# but Get-VBRBackupCopyJob TargetRepository has AmazonCompatibleOptions.BucketName etc.)
Write-Host "  Querying backup copy jobs for bucket details..."
$COPY_JOB_REPOS = @{}
try {
    $COPY_JOBS = Get-VBRBackupCopyJob -ErrorAction Stop
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

# Calculate storage sizes per repo by summing backup storages
# Parent backups with IsTruePerVmContainer have 0 storages, so we
# enumerate child backups via FindChildBackups() to get actual data
Write-Host "  Calculating storage sizes from backup objects..."
$SIZE_BY_REPO_ID = @{}
try {
    $ALL_BACKUPS = Get-VBRBackup
    foreach ($BACKUP in $ALL_BACKUPS) {
        $RID = $BACKUP.RepositoryId.ToString()
        if (-not $SIZE_BY_REPO_ID.ContainsKey($RID)) {
            $SIZE_BY_REPO_ID[$RID] = [long]0
        }

        # Collect backups to check: the backup itself + any child backups
        $BACKUPS_TO_CHECK = @($BACKUP)
        try {
            if ($BACKUP.IsTruePerVmContainer) {
                $CHILDREN = $BACKUP.FindChildBackups()
                if ($CHILDREN) { $BACKUPS_TO_CHECK += $CHILDREN }
            }
        } catch { }

        foreach ($B in $BACKUPS_TO_CHECK) {
            try {
                $STORAGES = $B.GetAllStorages()
                foreach ($ST in $STORAGES) {
                    $ST_SIZE = [long]0
                    try { if ($ST.Stats -and $ST.Stats.BackupSize -gt 0) { $ST_SIZE = [long]$ST.Stats.BackupSize } } catch {}
                    if ($ST_SIZE -eq 0) { try { if ($ST.BackupSize -gt 0) { $ST_SIZE = [long]$ST.BackupSize } } catch {} }
                    if ($ST_SIZE -eq 0) { try { if ($ST.DataSize -gt 0) { $ST_SIZE = [long]$ST.DataSize } } catch {} }
                    $SIZE_BY_REPO_ID[$RID] += $ST_SIZE
                }
            } catch { }
        }
    }
} catch {
    Write-Warning "  Could not enumerate backups for size calculation: $_"
}

# Process each S3 repo
foreach ($REPO in $OBJECT_STORAGE_REPOS) {
    Write-Host "  Processing: $($REPO.Name)"
    $REPO_ID = $REPO.Id.ToString()

    # --- BUCKET NAME ---
    $BUCKET_NAME = "N/A"

    # Primary: copy job TargetRepository (confirmed working on Veeam 12)
    # AmazonCompatibleOptions.BucketName is populated here but NOT on
    # objects from Get-VBRObjectStorageRepository (those are skeleton/null)
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

    # Fallback: try direct repo sub-objects (may work on other Veeam versions)
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

    # Try direct repo properties
    try { if ($null -ne $REPO.UsedSpace -and $REPO.UsedSpace -gt 0) { $USED_SPACE_DISPLAY = Format-SizeBytes -Bytes $REPO.UsedSpace } } catch {}

    # Fall back to summed storage sizes from backup objects
    if ($USED_SPACE_DISPLAY -eq "N/A" -and $SIZE_BY_REPO_ID.ContainsKey($REPO_ID) -and $SIZE_BY_REPO_ID[$REPO_ID] -gt 0) {
        $USED_SPACE_DISPLAY = Format-SizeBytes -Bytes $SIZE_BY_REPO_ID[$REPO_ID]
    }

    # --- REPO TYPE ---
    $REPO_TYPE = "N/A"
    try { if ($REPO.Type) { $REPO_TYPE = $REPO.Type.ToString() } } catch {}
    try { if ($REPO_TYPE -eq "N/A" -and $REPO.TypeDisplay) { $REPO_TYPE = $REPO.TypeDisplay } } catch {}

    $REPO_ROWS.Add(@{
        RepoName   = $REPO.Name
        BucketName = $BUCKET_NAME
        RepoType   = $REPO_TYPE
        UsedSpace  = $USED_SPACE_DISPLAY
    })
}


Write-Host ""
Write-Host "Found $($REPO_ROWS.Count) S3-compatible repositories."
Write-Host ""

# Log plain-text summary to transcript
if ($REPO_ROWS.Count -eq 0) {
    Write-Host "No S3-compatible object storage repositories found."
} else {
    Write-Host "=== Repository Summary ==="
    foreach ($ROW in $REPO_ROWS) {
        Write-Host "  Repo:       $($ROW.RepoName)"
        Write-Host "  Bucket:     $($ROW.BucketName)"
        Write-Host "  Type:       $($ROW.RepoType)"
        Write-Host "  Used Space: $($ROW.UsedSpace)"
        Write-Host ""
    }
}

# ------------------------------------------------------------
# Build HTML table
# ------------------------------------------------------------
Write-Host "Building HTML table..."

$HTML_TABLE = Build-HtmlInventoryTable -Rows $REPO_ROWS -ScanTimestamp $SCAN_TIMESTAMP

Write-Host "HTML table built ($($HTML_TABLE.Length) characters)."

# ------------------------------------------------------------
# Write to NinjaOne WYSIWYG custom field
# ------------------------------------------------------------
if ($env:CUSTOM_FIELD_S3_INVENTORY) {
    Write-Host ""
    Write-Host "Writing to NinjaOne custom field: $env:CUSTOM_FIELD_S3_INVENTORY"

    $NINJA_CMD = Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue
    if ($NINJA_CMD) {
        try {
            Ninja-Property-Set $env:CUSTOM_FIELD_S3_INVENTORY $HTML_TABLE
            Write-Host "  [OK] Custom field updated successfully."
        } catch {
            Write-Warning "  Failed to write to NinjaOne custom field: $_"
        }
    } else {
        Write-Warning "  Ninja-Property-Set command not found. Skipping custom field write."
        Write-Host "  HTML content that would have been written:"
        Write-Host $HTML_TABLE
    }
} else {
    Write-Host "No NinjaOne custom field specified. Skipping field write."
    Write-Host ""
    Write-Host "=== Generated HTML ==="
    Write-Host $HTML_TABLE
}

Write-Host ""
Write-Host "=== Script complete ==="

Stop-Transcript
