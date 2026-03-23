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
            <td colspan="5" style="text-align:center;color:#6b7280;font-style:italic;padding:16px 12px;">
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
            <td style="padding:8px 12px;border-bottom:1px solid #e5e7eb;">$(ConvertTo-SafeHtml $ROW.TotalSpace)</td>
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
                <th style="padding:10px 12px;text-align:left;font-weight:600;color:#374151;border-bottom:2px solid #d1d5db;">Total Capacity</th>
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
    # Interactive mode
    $VALID_INPUT = 0
    while ($VALID_INPUT -ne 1) {
        $DESCRIPTION = Read-Host "Please enter the ticket # and/or your initials (used for audit trail)"
        if ($DESCRIPTION) {
            $VALID_INPUT = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }

    $CUSTOM_FIELD_S3_INVENTORY = Read-Host "Enter the NinjaOne WYSIWYG custom field name to write the inventory table to (leave blank to skip)"

    $LOG_PATH = "$env:WINDIR\logs\$SCRIPT_LOG_NAME"

} else {
    # RMM mode
    $DESCRIPTION               = $env:DESCRIPTION
    $CUSTOM_FIELD_S3_INVENTORY = $env:CUSTOM_FIELD_S3_INVENTORY
    $RMM_SCRIPT_PATH           = $env:RMM_SCRIPT_PATH

    if ($RMM_SCRIPT_PATH) {
        $LOG_DIR = "$RMM_SCRIPT_PATH\logs"
        if (-not (Test-Path $LOG_DIR)) {
            New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
        }
        $LOG_PATH = "$LOG_DIR\$SCRIPT_LOG_NAME"
    } else {
        $LOG_PATH = "$env:WINDIR\logs\$SCRIPT_LOG_NAME"
    }

    if (-not $DESCRIPTION) {
        Write-Host "DESCRIPTION is null. This was most likely run automatically from the RMM with no description passed."
        $DESCRIPTION = "No Description"
    }
}

# ============================================================
# SECTION 3: SCRIPT LOGIC
# ============================================================

Start-Transcript -Path $LOG_PATH

Write-Host "=== Veeam S3 Bucket Inventory ==="
Write-Host "Description:  $DESCRIPTION"
Write-Host "Log path:     $LOG_PATH"
Write-Host "RMM mode:     $($env:RMM -eq '1')"
Write-Host "PS version:   $($PSVersionTable.PSVersion)"
Write-Host "Custom field: $CUSTOM_FIELD_S3_INVENTORY"
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
# Connect to local VBR server
# ------------------------------------------------------------
Write-Host "Connecting to local VBR server..."
try {
    Connect-VBRServer -Server localhost -ErrorAction Stop
    Write-Host "  [OK] Connected to VBR server."
} catch {
    Stop-Transcript
    throw "Failed to connect to VBR server: $_"
}

# ------------------------------------------------------------
# Collect S3-compatible object storage repositories
# ------------------------------------------------------------
Write-Host ""
Write-Host "Querying S3-compatible object storage repositories..."

$REPO_ROWS = [System.Collections.Generic.List[hashtable]]::new()
$SCAN_TIMESTAMP = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Primary method: Get-VBRObjectStorageRepository (Veeam 12+)
$OBJECT_STORAGE_REPOS = $null
try {
    $OBJECT_STORAGE_REPOS = Get-VBRObjectStorageRepository -ErrorAction Stop
    Write-Host "  [OK] Get-VBRObjectStorageRepository returned $($OBJECT_STORAGE_REPOS.Count) repositories."
} catch {
    Write-Warning "  Get-VBRObjectStorageRepository not available or failed: $_"
    Write-Host "  Falling back to Get-VBRBackupRepository filter..."
}

# Fallback: filter all repos for S3-compatible types
$FALLBACK_REPOS = $null
if (-not $OBJECT_STORAGE_REPOS) {
    try {
        $FALLBACK_REPOS = Get-VBRBackupRepository | Where-Object {
            $_.Type -like "AmazonS3*" -or $_.Type -eq "S3Compatible"
        }
        Write-Host "  [OK] Fallback found $($FALLBACK_REPOS.Count) S3-compatible repositories."
    } catch {
        Write-Warning "  Fallback repository query failed: $_"
    }
}

# Process Get-VBRObjectStorageRepository results (preferred path)
if ($OBJECT_STORAGE_REPOS) {
    foreach ($REPO in $OBJECT_STORAGE_REPOS) {
        Write-Host "  Processing: $($REPO.Name)"

        $BUCKET_NAME = "N/A"
        try {
            if ($REPO.BucketName)    { $BUCKET_NAME = $REPO.BucketName }
            elseif ($REPO.Bucket)    { $BUCKET_NAME = $REPO.Bucket }
            elseif ($REPO.AmazonS3Folder -and $REPO.AmazonS3Folder.BucketName) { $BUCKET_NAME = $REPO.AmazonS3Folder.BucketName }
        } catch { }

        $ENDPOINT = "N/A"
        try {
            if ($REPO.ConnectionInfo -and $REPO.ConnectionInfo.Endpoint) { $ENDPOINT = $REPO.ConnectionInfo.Endpoint }
            elseif ($REPO.ServicePoint)  { $ENDPOINT = $REPO.ServicePoint }
            elseif ($REPO.Endpoint)      { $ENDPOINT = $REPO.Endpoint }
        } catch { }

        $USED_SPACE_DISPLAY = "N/A"
        try {
            if ($null -ne $REPO.UsedSpace -and $REPO.UsedSpace -gt 0) {
                $USED_SPACE_DISPLAY = Format-SizeBytes -Bytes $REPO.UsedSpace
            } elseif ($null -ne $REPO.UsedSpaceGB -and $REPO.UsedSpaceGB -gt 0) {
                $USED_SPACE_DISPLAY = "{0:N2} GB" -f $REPO.UsedSpaceGB
            }
        } catch { }

        $TOTAL_SPACE_DISPLAY = "N/A"
        try {
            if ($null -ne $REPO.TotalSpace -and $REPO.TotalSpace -gt 0) {
                $TOTAL_SPACE_DISPLAY = Format-SizeBytes -Bytes $REPO.TotalSpace
            }
        } catch { }

        $REPO_TYPE = "N/A"
        try {
            if ($REPO.Type) { $REPO_TYPE = $REPO.Type.ToString() }
        } catch { }

        $REPO_ROWS.Add(@{
            RepoName    = $REPO.Name
            BucketName  = $BUCKET_NAME
            Endpoint    = $ENDPOINT
            RepoType    = $REPO_TYPE
            UsedSpace   = $USED_SPACE_DISPLAY
            TotalSpace  = $TOTAL_SPACE_DISPLAY
        })
    }
}

# Process fallback results (Get-VBRBackupRepository filtered)
if ($FALLBACK_REPOS) {
    foreach ($REPO in $FALLBACK_REPOS) {
        Write-Host "  Processing (fallback): $($REPO.Name)"

        $BUCKET_NAME = "N/A"
        try {
            $EXTENTS = $null
            if ($REPO.PSObject.Methods.Name -contains 'GetExtentList') {
                $EXTENTS = $REPO.GetExtentList()
            }
            if ($EXTENTS) {
                $FIRST_EXTENT = $EXTENTS | Select-Object -First 1
                if ($FIRST_EXTENT.AmazonS3Folder -and $FIRST_EXTENT.AmazonS3Folder.BucketName) {
                    $BUCKET_NAME = $FIRST_EXTENT.AmazonS3Folder.BucketName
                }
            }

            if ($BUCKET_NAME -eq "N/A") {
                if ($REPO.AmazonS3Folder -and $REPO.AmazonS3Folder.BucketName) { $BUCKET_NAME = $REPO.AmazonS3Folder.BucketName }
                elseif ($REPO.Info -and $REPO.Info.BucketName)                 { $BUCKET_NAME = $REPO.Info.BucketName }
                elseif ($REPO.BucketName)                                       { $BUCKET_NAME = $REPO.BucketName }
            }
        } catch { }

        $ENDPOINT = "N/A"
        try {
            if ($REPO.ServicePoint)                        { $ENDPOINT = $REPO.ServicePoint }
            elseif ($REPO.Info -and $REPO.Info.Endpoint)  { $ENDPOINT = $REPO.Info.Endpoint }
        } catch { }

        $USED_SPACE_DISPLAY = "N/A"
        $TOTAL_SPACE_DISPLAY = "N/A"
        try {
            $CACHED_TOTAL = $REPO.Info.CachedTotalSpace
            $CACHED_FREE  = $REPO.Info.CachedFreeSpace
            if ($null -ne $CACHED_TOTAL -and $CACHED_TOTAL -gt 0) {
                $TOTAL_SPACE_DISPLAY = Format-SizeBytes -Bytes $CACHED_TOTAL
                if ($null -ne $CACHED_FREE) {
                    $USED_BYTES = $CACHED_TOTAL - $CACHED_FREE
                    if ($USED_BYTES -ge 0) {
                        $USED_SPACE_DISPLAY = Format-SizeBytes -Bytes $USED_BYTES
                    }
                }
            }
        } catch { }

        $REPO_TYPE = "N/A"
        try {
            if ($REPO.Type) { $REPO_TYPE = $REPO.Type.ToString() }
        } catch { }

        $REPO_ROWS.Add(@{
            RepoName    = $REPO.Name
            BucketName  = $BUCKET_NAME
            Endpoint    = $ENDPOINT
            RepoType    = $REPO_TYPE
            UsedSpace   = $USED_SPACE_DISPLAY
            TotalSpace  = $TOTAL_SPACE_DISPLAY
        })
    }
}

# Disconnect from VBR
try { Disconnect-VBRServer } catch { }

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
        Write-Host "  Endpoint:   $($ROW.Endpoint)"
        Write-Host "  Used Space: $($ROW.UsedSpace)"
        Write-Host "  Total:      $($ROW.TotalSpace)"
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
if ($CUSTOM_FIELD_S3_INVENTORY) {
    Write-Host ""
    Write-Host "Writing to NinjaOne custom field: $CUSTOM_FIELD_S3_INVENTORY"

    $NINJA_CMD = Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue
    if ($NINJA_CMD) {
        try {
            Ninja-Property-Set $CUSTOM_FIELD_S3_INVENTORY $HTML_TABLE
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
