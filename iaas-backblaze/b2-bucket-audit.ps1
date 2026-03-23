## B2 Bucket Audit - List all Backblaze B2 buckets and flag unused ones
## Run centrally (not per-device). Compares B2 account buckets against
## a known-good list of active bucket names. Unused buckets show in red.
##
## $env:B2_KEY_ID              - Backblaze B2 application key ID
## $env:B2_APP_KEY             - Backblaze B2 application key
## $env:ACTIVE_BUCKETS_CSV     - Comma-separated list of bucket names in active use
##                                (or path to a .txt/.csv file with one bucket per line)
## $env:CUSTOM_FIELD_B2_AUDIT  - NinjaOne WYSIWYG field for the bucket audit table
## $env:DESCRIPTION            - Ticket # or initials for audit trail
## $env:RMM                    - Set to 1 when running from RMM platform

# ============================================================
# HELPER FUNCTIONS
# ============================================================

function ConvertTo-SafeHtml {
    param([string]$Text)
    if (-not $Text) { return "" }
    return $Text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}

function Format-SizeBytes {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
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
        Write-Host "  [SKIP] Ninja-Property-Set not available."
    }
}

# ============================================================
# INPUT HANDLING
# ============================================================

if ($env:RMM -ne "1") {
    if (-not $env:B2_KEY_ID) {
        $env:B2_KEY_ID = Read-Host "Backblaze B2 application key ID"
    }
    if (-not $env:B2_APP_KEY) {
        $env:B2_APP_KEY = Read-Host "Backblaze B2 application key"
    }
    if (-not $env:ACTIVE_BUCKETS_CSV) {
        $env:ACTIVE_BUCKETS_CSV = Read-Host "Active bucket names (comma-separated, or path to file, or blank to show all)"
    }
    if (-not $env:CUSTOM_FIELD_B2_AUDIT) {
        $env:CUSTOM_FIELD_B2_AUDIT = Read-Host "NinjaOne WYSIWYG field for audit table (blank to skip)"
    }
}

if (-not $env:B2_KEY_ID -or -not $env:B2_APP_KEY) {
    Write-Error "B2_KEY_ID and B2_APP_KEY are required."
    exit 1
}

# Parse active bucket list
$ACTIVE_BUCKETS = @{}
if ($env:ACTIVE_BUCKETS_CSV) {
    $RAW = $env:ACTIVE_BUCKETS_CSV.Trim()
    # Check if it's a file path
    if (Test-Path $RAW -ErrorAction SilentlyContinue) {
        $LINES = Get-Content $RAW | Where-Object { $_.Trim() -ne "" }
        foreach ($L in $LINES) {
            # Handle CSV with headers or plain list
            $NAME = ($L -split ',')[0].Trim().Trim('"')
            if ($NAME -and $NAME -ne "BucketName" -and $NAME -ne "bucket_name") {
                $ACTIVE_BUCKETS[$NAME.ToLower()] = $true
            }
        }
    } else {
        # Comma-separated string
        foreach ($NAME in ($RAW -split ',')) {
            $TRIMMED = $NAME.Trim()
            if ($TRIMMED) { $ACTIVE_BUCKETS[$TRIMMED.ToLower()] = $true }
        }
    }
}
Write-Host "Active buckets in known-good list: $($ACTIVE_BUCKETS.Count)"

# ============================================================
# B2 API
# ============================================================

Write-Host ""
Write-Host "=== B2 Bucket Audit ==="
Write-Host ""

# Authorize
Write-Host "Authenticating to Backblaze B2..."
try {
    $B2_CREDS = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($env:B2_KEY_ID):$($env:B2_APP_KEY)"))

    $AUTH = Invoke-RestMethod -Uri "https://api.backblazeb2.com/b2api/v4/b2_authorize_account" `
        -Method GET `
        -Headers @{ Authorization = "Basic $B2_CREDS" } `
        -ErrorAction Stop

    $API_URL = $AUTH.apiInfo.storageApi.apiUrl
    $AUTH_TOKEN = $AUTH.authorizationToken
    $ACCOUNT_ID = $AUTH.accountId

    Write-Host "  [OK] Account: $ACCOUNT_ID"
} catch {
    Write-Error "B2 authentication failed: $_"
    exit 1
}

# List buckets
Write-Host "Listing buckets..."
try {
    $BUCKET_RESPONSE = Invoke-RestMethod -Uri "$API_URL/b2api/v4/b2_list_buckets" `
        -Method POST `
        -Headers @{ Authorization = $AUTH_TOKEN } `
        -ContentType "application/json" `
        -Body (@{ accountId = $ACCOUNT_ID } | ConvertTo-Json) `
        -ErrorAction Stop

    $BUCKETS = $BUCKET_RESPONSE.buckets
    Write-Host "  [OK] Found $($BUCKETS.Count) buckets."
} catch {
    Write-Error "Failed to list B2 buckets: $_"
    exit 1
}

# Build table rows
$SCAN_TIMESTAMP = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$TABLE_ROWS = ""
$ROW_INDEX = 0
$UNUSED_COUNT = 0
$USED_COUNT = 0

# Sort: unused first (so they're at the top), then alphabetical
$SORTED_BUCKETS = $BUCKETS | Sort-Object @{
    Expression = { $ACTIVE_BUCKETS.ContainsKey($_.bucketName.ToLower()) }
}, bucketName

foreach ($BUCKET in $SORTED_BUCKETS) {
    $BNAME = $BUCKET.bucketName
    $BTYPE = $BUCKET.bucketType
    $BNAME_LOWER = $BNAME.ToLower()

    if ($ACTIVE_BUCKETS.Count -gt 0) {
        $IS_USED = $ACTIVE_BUCKETS.ContainsKey($BNAME_LOWER)
    } else {
        # No active list provided, mark all as unknown
        $IS_USED = $null
    }

    if ($IS_USED -eq $false) {
        $STATUS = "Unused"
        $ROW_BG = "#fef2f2"
        $ROW_COLOR = "color:#991b1b;font-weight:600;"
        $UNUSED_COUNT++
    } elseif ($IS_USED -eq $true) {
        $STATUS = "In Use"
        $ROW_BG = if ($ROW_INDEX % 2 -eq 0) { "#ffffff" } else { "#f9fafb" }
        $ROW_COLOR = ""
        $USED_COUNT++
    } else {
        $STATUS = "Unknown"
        $ROW_BG = if ($ROW_INDEX % 2 -eq 0) { "#ffffff" } else { "#f9fafb" }
        $ROW_COLOR = "color:#6b7280;"
    }

    $MARKER = if ($IS_USED -eq $false) { "[!]" } elseif ($IS_USED) { "[OK]" } else { "[?]" }
    Write-Host "  $MARKER $BNAME ($BTYPE) - $STATUS"

    $TABLE_ROWS += @"
        <tr style="background-color:$ROW_BG;$ROW_COLOR">
            <td style="padding:8px 12px;border-bottom:1px solid #e5e7eb;">$(ConvertTo-SafeHtml $BNAME)</td>
            <td style="padding:8px 12px;border-bottom:1px solid #e5e7eb;">$(ConvertTo-SafeHtml $BTYPE)</td>
            <td style="padding:8px 12px;border-bottom:1px solid #e5e7eb;">$(ConvertTo-SafeHtml $STATUS)</td>
        </tr>
"@
    $ROW_INDEX++
}

# Summary
Write-Host ""
Write-Host "=== Summary ==="
Write-Host "  Total buckets: $($BUCKETS.Count)"
if ($ACTIVE_BUCKETS.Count -gt 0) {
    Write-Host "  In use:        $USED_COUNT"
    Write-Host "  Unused:        $UNUSED_COUNT"
}

# Build HTML
$HTML = @"
<div style="font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#111827;">
    <table style="width:100%;border-collapse:collapse;border:1px solid #d1d5db;border-radius:4px;overflow:hidden;">
        <thead>
            <tr style="background-color:#f3f4f6;">
                <th style="padding:10px 12px;text-align:left;font-weight:600;color:#374151;border-bottom:2px solid #d1d5db;">Bucket Name</th>
                <th style="padding:10px 12px;text-align:left;font-weight:600;color:#374151;border-bottom:2px solid #d1d5db;">Type</th>
                <th style="padding:10px 12px;text-align:left;font-weight:600;color:#374151;border-bottom:2px solid #d1d5db;">Status</th>
            </tr>
        </thead>
        <tbody>
$TABLE_ROWS        </tbody>
    </table>
    <p style="margin:8px 0 0;font-size:11px;color:#6b7280;">Last scanned: $SCAN_TIMESTAMP | Total: $($BUCKETS.Count) | In Use: $USED_COUNT | Unused: $UNUSED_COUNT</p>
</div>
"@

# Write to NinjaOne
Set-NinjaField $env:CUSTOM_FIELD_B2_AUDIT $HTML

# Dump HTML if no Ninja and no field set
if (-not (Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue) -and -not $env:CUSTOM_FIELD_B2_AUDIT) {
    Write-Host ""
    Write-Host "=== HTML Output ==="
    Write-Host $HTML
}

Write-Host ""
Write-Host "=== Script complete ==="
