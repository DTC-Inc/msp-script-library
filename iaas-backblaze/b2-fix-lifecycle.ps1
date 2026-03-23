## Apply lifecycle rule to existing B2 buckets to purge hidden (old) file versions.
## Fixes the storage bloat where B2 keeps all versions forever.
##
## $env:B2_ADMIN_KEY_ID   - Master B2 application key ID
## $env:B2_ADMIN_APP_KEY  - Master B2 application key
## $env:BUCKET_NAME       - Target bucket name (or "ALL" to apply to all *-veeam buckets)
## $env:PURGE_DAYS        - Days after hiding before deletion (default: 15)

function Invoke-B2Api {
    param([string]$Uri, [string]$Method = "POST", [string]$AuthToken, [string]$Body)
    $PARAMS = @{
        Uri = $Uri; Method = $Method; ContentType = "application/json"
        SkipHeaderValidation = $true; Headers = @{ Authorization = $AuthToken }; ErrorAction = "Stop"
    }
    if ($Body) { $PARAMS['Body'] = $Body }
    return Invoke-RestMethod @PARAMS
}

if (-not $env:B2_ADMIN_KEY_ID) { $env:B2_ADMIN_KEY_ID = Read-Host "B2 admin key ID" }
if (-not $env:B2_ADMIN_APP_KEY) { $env:B2_ADMIN_APP_KEY = Read-Host "B2 admin app key" }
if (-not $env:BUCKET_NAME) { $env:BUCKET_NAME = Read-Host "Bucket name (or ALL for all *-veeam buckets)" }

$PURGE_DAYS = 15
if ($env:PURGE_DAYS) { try { $PURGE_DAYS = [int]$env:PURGE_DAYS } catch {} }

# Auth
$B2_SECURE_KEY = ConvertTo-SecureString $env:B2_ADMIN_APP_KEY -AsPlainText -Force
$B2_CREDENTIAL = [PSCredential]::new($env:B2_ADMIN_KEY_ID, $B2_SECURE_KEY)

$B2_AUTH = $null
foreach ($VER in @("v2", "v4")) {
    try {
        $B2_AUTH = Invoke-RestMethod -Uri "https://api.backblazeb2.com/b2api/$VER/b2_authorize_account" `
            -Method GET -Authentication Basic -Credential $B2_CREDENTIAL -ErrorAction Stop
        $B2_API_VER = $VER
        break
    } catch { }
}
if (-not $B2_AUTH) { Write-Error "Auth failed."; exit 1 }

$B2_API_URL = $B2_AUTH.apiUrl
if (-not $B2_API_URL) { $B2_API_URL = $B2_AUTH.apiInfo.storageApi.apiUrl }
$B2_AUTH_TOKEN = $B2_AUTH.authorizationToken
$B2_ACCOUNT_ID = $B2_AUTH.accountId

Write-Host "Authenticated: $B2_ACCOUNT_ID"

# List buckets
$BUCKET_RESPONSE = Invoke-B2Api -Uri "$B2_API_URL/b2api/$B2_API_VER/b2_list_buckets" `
    -AuthToken $B2_AUTH_TOKEN -Body (@{ accountId = $B2_ACCOUNT_ID } | ConvertTo-Json)

$BUCKETS = $BUCKET_RESPONSE.buckets

if ($env:BUCKET_NAME -eq "ALL") {
    $TARGET_BUCKETS = $BUCKETS | Where-Object { $_.bucketName -like "*-veeam" }
} else {
    $TARGET_BUCKETS = $BUCKETS | Where-Object { $_.bucketName -eq $env:BUCKET_NAME }
}

Write-Host "Targeting $($TARGET_BUCKETS.Count) bucket(s)`n"

foreach ($BUCKET in $TARGET_BUCKETS) {
    Write-Host "--- $($BUCKET.bucketName) ---"

    # Show current lifecycle rules
    $CURRENT_RULES = $BUCKET.lifecycleRules
    if ($CURRENT_RULES -and $CURRENT_RULES.Count -gt 0) {
        Write-Host "  Current lifecycle rules:"
        foreach ($R in $CURRENT_RULES) {
            Write-Host "    prefix='$($R.fileNamePrefix)' hideAfter=$($R.daysFromUploadingToHiding) deleteAfter=$($R.daysFromHidingToDeleting)"
        }
    } else {
        Write-Host "  No lifecycle rules (hidden versions kept forever!)"
    }

    # Apply the fix
    try {
        $UPDATE_BODY = @{
            accountId      = $B2_ACCOUNT_ID
            bucketId       = $BUCKET.bucketId
            lifecycleRules = @(
                @{
                    daysFromHidingToDeleting  = $PURGE_DAYS
                    daysFromUploadingToHiding = $null
                    fileNamePrefix            = ""
                }
            )
        } | ConvertTo-Json -Depth 5

        Invoke-B2Api -Uri "$B2_API_URL/b2api/$B2_API_VER/b2_update_bucket" `
            -AuthToken $B2_AUTH_TOKEN -Body $UPDATE_BODY | Out-Null

        Write-Host "  [OK] Lifecycle rule applied: delete hidden versions after $PURGE_DAYS days"
    } catch {
        Write-Warning "  FAILED: $_"
    }
    Write-Host ""
}

Write-Host "Done. Hidden file versions older than $PURGE_DAYS days will be automatically purged by B2."
Write-Host "Note: existing hidden versions won't be deleted instantly. B2 processes lifecycle rules daily."
