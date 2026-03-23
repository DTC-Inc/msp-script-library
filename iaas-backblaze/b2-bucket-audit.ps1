## B2 Bucket Audit - List all Backblaze B2 buckets with storage sizes
## and flag unused ones. Run centrally (not per-device).
##
## Bucket sizes come from Backblaze's daily usage reports stored in
## the b2-reports-{accountId} bucket (generated automatically by B2).
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
    if (Test-Path $RAW -ErrorAction SilentlyContinue) {
        $LINES = Get-Content $RAW | Where-Object { $_.Trim() -ne "" }
        foreach ($L in $LINES) {
            $NAME = ($L -split ',')[0].Trim().Trim('"')
            if ($NAME -and $NAME -ne "BucketName" -and $NAME -ne "bucket_name") {
                $ACTIVE_BUCKETS[$NAME.ToLower()] = $true
            }
        }
    } else {
        foreach ($NAME in ($RAW -split ',')) {
            $TRIMMED = $NAME.Trim()
            if ($TRIMMED) { $ACTIVE_BUCKETS[$TRIMMED.ToLower()] = $true }
        }
    }
}
Write-Host "Active buckets in known-good list: $($ACTIVE_BUCKETS.Count)"

# ============================================================
# B2 API - Try v2 first (most reliable), fall back to v4
# ============================================================

Write-Host ""
Write-Host "=== B2 Bucket Audit ==="
Write-Host ""

Write-Host "Authenticating to Backblaze B2..."
$B2_CREDS = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($env:B2_KEY_ID):$($env:B2_APP_KEY)"))

$AUTH = $null
foreach ($API_VER in @("v2", "v4", "v3")) {
    try {
        $AUTH = Invoke-RestMethod -Uri "https://api.backblazeb2.com/b2api/$API_VER/b2_authorize_account" `
            -Method GET `
            -Headers @{ Authorization = "Basic $B2_CREDS" } `
            -ErrorAction Stop
        Write-Host "  [OK] Authenticated via $API_VER"
        break
    } catch {
        Write-Host "  [$API_VER] Failed: $($_.Exception.Message)"
    }
}

if (-not $AUTH) {
    Write-Error "B2 authentication failed on all API versions. Check B2_KEY_ID and B2_APP_KEY."
    exit 1
}

$API_URL = $AUTH.apiUrl
if (-not $API_URL) { $API_URL = $AUTH.apiInfo.storageApi.apiUrl }
$AUTH_TOKEN = $AUTH.authorizationToken
$ACCOUNT_ID = $AUTH.accountId
$DOWNLOAD_URL = $AUTH.downloadUrl
if (-not $DOWNLOAD_URL) { $DOWNLOAD_URL = $AUTH.apiInfo.storageApi.downloadUrl }

# Determine which API version worked for subsequent calls
$B2_VER = "v2"
if ($API_URL -match '/b2api/(v\d+)') { $B2_VER = $Matches[1] }

Write-Host "  Account: $ACCOUNT_ID"
Write-Host "  API URL: $API_URL"
Write-Host "  Download URL: $DOWNLOAD_URL"

# ============================================================
# List all buckets
# ============================================================
Write-Host ""
Write-Host "Listing buckets..."
try {
    $BUCKET_RESPONSE = Invoke-RestMethod -Uri "$API_URL/b2api/$B2_VER/b2_list_buckets" `
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

# Build bucket ID -> name lookup
$BUCKET_ID_TO_NAME = @{}
foreach ($B in $BUCKETS) {
    $BUCKET_ID_TO_NAME[$B.bucketId] = $B.bucketName
}

# ============================================================
# Pull daily usage report for bucket sizes
# ============================================================
Write-Host ""
Write-Host "Fetching daily usage report from b2-reports-$ACCOUNT_ID..."
$BUCKET_SIZES = @{}  # bucketId -> stored_gb

$REPORTS_BUCKET_NAME = "b2-reports-$ACCOUNT_ID"
# Find the reports bucket ID
$REPORTS_BUCKET_ID = $null
foreach ($B in $BUCKETS) {
    if ($B.bucketName -eq $REPORTS_BUCKET_NAME) {
        $REPORTS_BUCKET_ID = $B.bucketId
        break
    }
}

if ($REPORTS_BUCKET_ID) {
    try {
        # List recent files in the reports bucket to find the latest daily report
        $FILES_RESPONSE = Invoke-RestMethod -Uri "$API_URL/b2api/$B2_VER/b2_list_file_names" `
            -Method POST `
            -Headers @{ Authorization = $AUTH_TOKEN } `
            -ContentType "application/json" `
            -Body (@{
                bucketId = $REPORTS_BUCKET_ID
                maxFileCount = 100
            } | ConvertTo-Json) `
            -ErrorAction Stop

        # Find the most recent audit CSV
        $REPORT_FILE = $FILES_RESPONSE.files |
            Where-Object { $_.fileName -match "audit" -and $_.fileName -match "\.csv$" } |
            Sort-Object fileName -Descending |
            Select-Object -First 1

        if ($REPORT_FILE) {
            Write-Host "  Found report: $($REPORT_FILE.fileName)"

            # Download the CSV
            $CSV_URL = "$DOWNLOAD_URL/file/$REPORTS_BUCKET_NAME/$($REPORT_FILE.fileName)"
            $CSV_CONTENT = Invoke-RestMethod -Uri $CSV_URL `
                -Method GET `
                -Headers @{ Authorization = $AUTH_TOKEN } `
                -ErrorAction Stop

            # Parse CSV - columns vary but we need bucketId and stored bytes/GB
            $CSV_LINES = $CSV_CONTENT -split "`n" | Where-Object { $_.Trim() -ne "" }
            if ($CSV_LINES.Count -gt 1) {
                $HEADERS = ($CSV_LINES[0] -split ',') | ForEach-Object { $_.Trim().Trim('"') }

                # Find column indices
                $IDX_BUCKET_ID = [array]::IndexOf($HEADERS, "bucketId")
                if ($IDX_BUCKET_ID -eq -1) { $IDX_BUCKET_ID = [array]::IndexOf($HEADERS, "bucket_id") }
                $IDX_STORED = -1
                foreach ($COL in @("storageByteCount", "stored_bytes", "storedBytes", "bytesStored")) {
                    $IDX_STORED = [array]::IndexOf($HEADERS, $COL)
                    if ($IDX_STORED -ne -1) { break }
                }

                if ($IDX_BUCKET_ID -ne -1 -and $IDX_STORED -ne -1) {
                    Write-Host "  Parsing report (bucketId col=$IDX_BUCKET_ID, bytes col=$IDX_STORED)..."
                    for ($I = 1; $I -lt $CSV_LINES.Count; $I++) {
                        $FIELDS = ($CSV_LINES[$I] -split ',') | ForEach-Object { $_.Trim().Trim('"') }
                        if ($FIELDS.Count -gt [Math]::Max($IDX_BUCKET_ID, $IDX_STORED)) {
                            $BID = $FIELDS[$IDX_BUCKET_ID]
                            $BYTES = [long]0
                            try { $BYTES = [long]$FIELDS[$IDX_STORED] } catch {}
                            if ($BID) { $BUCKET_SIZES[$BID] = $BYTES }
                        }
                    }
                    Write-Host "  [OK] Parsed sizes for $($BUCKET_SIZES.Count) buckets."
                } else {
                    Write-Warning "  Could not find expected columns in report. Headers: $($HEADERS -join ', ')"
                    Write-Host "  Dumping first 3 lines for debugging:"
                    for ($I = 0; $I -lt [Math]::Min(3, $CSV_LINES.Count); $I++) {
                        Write-Host "    $($CSV_LINES[$I])"
                    }
                }
            }
        } else {
            Write-Warning "  No audit CSV found in reports bucket."
            Write-Host "  Files found:"
            foreach ($F in $FILES_RESPONSE.files | Select-Object -First 10) {
                Write-Host "    $($F.fileName)"
            }
        }
    } catch {
        Write-Warning "  Failed to fetch usage report: $_"
    }
} else {
    Write-Warning "  Reports bucket ($REPORTS_BUCKET_NAME) not found. Size data unavailable."
}

# ============================================================
# Build output table
# ============================================================
$SCAN_TIMESTAMP = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$TABLE_ROWS = ""
$ROW_INDEX = 0
$UNUSED_COUNT = 0
$USED_COUNT = 0

# Sort: unused first, then alphabetical
$SORTED_BUCKETS = $BUCKETS | Where-Object { $_.bucketName -ne $REPORTS_BUCKET_NAME } | Sort-Object @{
    Expression = { $ACTIVE_BUCKETS.ContainsKey($_.bucketName.ToLower()) }
}, bucketName

foreach ($BUCKET in $SORTED_BUCKETS) {
    $BNAME = $BUCKET.bucketName
    $BTYPE = $BUCKET.bucketType
    $BID = $BUCKET.bucketId

    # Size from daily report
    $SIZE_DISPLAY = "N/A"
    if ($BUCKET_SIZES.ContainsKey($BID)) {
        $BYTES = $BUCKET_SIZES[$BID]
        if ($BYTES -ge 1TB) { $SIZE_DISPLAY = "{0:N2} TB" -f ($BYTES / 1TB) }
        elseif ($BYTES -ge 1GB) { $SIZE_DISPLAY = "{0:N2} GB" -f ($BYTES / 1GB) }
        elseif ($BYTES -ge 1MB) { $SIZE_DISPLAY = "{0:N2} MB" -f ($BYTES / 1MB) }
        elseif ($BYTES -gt 0) { $SIZE_DISPLAY = "{0:N2} KB" -f ($BYTES / 1KB) }
        else { $SIZE_DISPLAY = "0 B" }
    }

    # Status
    if ($ACTIVE_BUCKETS.Count -gt 0) {
        $IS_USED = $ACTIVE_BUCKETS.ContainsKey($BNAME.ToLower())
    } else {
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
        $STATUS = ""
        $ROW_BG = if ($ROW_INDEX % 2 -eq 0) { "#ffffff" } else { "#f9fafb" }
        $ROW_COLOR = ""
    }

    $MARKER = if ($IS_USED -eq $false) { "[!]" } elseif ($IS_USED) { "[OK]" } else { "   " }
    Write-Host "  $MARKER $BNAME | $BTYPE | $SIZE_DISPLAY | $STATUS"

    $TABLE_ROWS += @"
        <tr style="background-color:$ROW_BG;$ROW_COLOR">
            <td style="padding:8px 12px;border-bottom:1px solid #e5e7eb;">$(ConvertTo-SafeHtml $BNAME)</td>
            <td style="padding:8px 12px;border-bottom:1px solid #e5e7eb;">$(ConvertTo-SafeHtml $BTYPE)</td>
            <td style="padding:8px 12px;border-bottom:1px solid #e5e7eb;">$(ConvertTo-SafeHtml $SIZE_DISPLAY)</td>
            <td style="padding:8px 12px;border-bottom:1px solid #e5e7eb;">$(ConvertTo-SafeHtml $STATUS)</td>
        </tr>
"@
    $ROW_INDEX++
}

# Summary
Write-Host ""
Write-Host "=== Summary ==="
Write-Host "  Total buckets: $($SORTED_BUCKETS.Count)"
if ($ACTIVE_BUCKETS.Count -gt 0) {
    Write-Host "  In use:        $USED_COUNT"
    Write-Host "  Unused:        $UNUSED_COUNT"
}

# Build HTML
$SUMMARY_LINE = "Last scanned: $SCAN_TIMESTAMP | Total: $($SORTED_BUCKETS.Count)"
if ($ACTIVE_BUCKETS.Count -gt 0) {
    $SUMMARY_LINE += " | In Use: $USED_COUNT | Unused: $UNUSED_COUNT"
}

$HTML = @"
<div style="font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#111827;">
    <table style="width:100%;border-collapse:collapse;border:1px solid #d1d5db;border-radius:4px;overflow:hidden;">
        <thead>
            <tr style="background-color:#f3f4f6;">
                <th style="padding:10px 12px;text-align:left;font-weight:600;color:#374151;border-bottom:2px solid #d1d5db;">Bucket Name</th>
                <th style="padding:10px 12px;text-align:left;font-weight:600;color:#374151;border-bottom:2px solid #d1d5db;">Type</th>
                <th style="padding:10px 12px;text-align:left;font-weight:600;color:#374151;border-bottom:2px solid #d1d5db;">Size</th>
                <th style="padding:10px 12px;text-align:left;font-weight:600;color:#374151;border-bottom:2px solid #d1d5db;">Status</th>
            </tr>
        </thead>
        <tbody>
$TABLE_ROWS        </tbody>
    </table>
    <p style="margin:8px 0 0;font-size:11px;color:#6b7280;">$SUMMARY_LINE</p>
</div>
"@

# Write to NinjaOne
Set-NinjaField $env:CUSTOM_FIELD_B2_AUDIT $HTML

# Dump if no Ninja
if (-not (Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue) -and -not $env:CUSTOM_FIELD_B2_AUDIT) {
    Write-Host ""
    Write-Host "=== HTML Output ==="
    Write-Host $HTML
}

Write-Host ""
Write-Host "=== Script complete ==="
