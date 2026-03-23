## Creates a Backblaze B2 bucket, generates a scoped application key with
## read/write access to only that bucket, registers the Veeam S3 repository
## using the scoped key, and stores credentials in NinjaRMM device fields.
##
## Bucket naming: {ORG_UUID_no_dashes}-{time_based_short_id}-veeam
## Veeam repository name = bucket name
##
## ADMIN CREDENTIALS (org-level in NinjaRMM, used to create bucket + scoped key):
## $env:B2_ADMIN_KEY_ID               - Master/admin B2 application key ID
## $env:B2_ADMIN_APP_KEY              - Master/admin B2 application key
##
## CONFIGURATION:
## $env:CUSTOM_FIELD_ORG_UUID          - NinjaOne text field containing the organization UUID (REQUIRED)
## $env:B2_ENDPOINT                   - S3 endpoint (e.g. https://s3.us-west-002.backblazeb2.com)
## $env:B2_REGION                     - S3 region ID (e.g. us-west-002)
## $env:IMMUTABILITY_DAYS             - Object lock immutability period in days (default: 14)
##
## OUTPUT FIELDS (device-level, written after creation):
## $env:CUSTOM_FIELD_S3_BUCKET_NAME   - Text: bucket name
## $env:CUSTOM_FIELD_S3_KEY_ID        - Text: scoped B2 key ID (bucket-only access)
## $env:CUSTOM_FIELD_S3_APP_KEY       - Text: scoped B2 app key (bucket-only access)
##
## $env:DESCRIPTION                   - Ticket # or initials for audit trail
## $env:RMM                           - Set to 1 when running from RMM platform
## $env:RMM_SCRIPT_PATH               - Script path provided by RMM (used for log location)

# ============================================================
# PS7 BOOTSTRAP
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
        Write-Warning "PowerShell 7 (pwsh.exe) not found. Veeam module may fail to load."
    }
}

# ============================================================
# HELPER FUNCTIONS
# ============================================================

function New-TimeBasedShortId {
    # Generates a short time-based ID from a UUIDv7-style timestamp.
    # Uses milliseconds since Unix epoch encoded in base36 for compactness.
    # 8 chars of base36 = ~2.8 trillion values, unique to the millisecond.
    $MS = [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    $CHARS = "0123456789abcdefghijklmnopqrstuvwxyz"
    $RESULT = ""
    while ($MS -gt 0) {
        $RESULT = $CHARS[$MS % 36] + $RESULT
        $MS = [Math]::Floor($MS / 36)
    }
    # Pad to 8 chars or truncate
    return $RESULT.PadLeft(8, '0').Substring(0, 8)
}

function Invoke-B2Api {
    # Wrapper for B2 API calls that handles PowerShell's strict header validation.
    # The B2 auth token contains = characters which Invoke-RestMethod rejects.
    param(
        [string]$Uri,
        [string]$Method = "POST",
        [string]$AuthToken,
        [string]$Body
    )
    $PARAMS = @{
        Uri                  = $Uri
        Method               = $Method
        ContentType          = "application/json"
        SkipHeaderValidation = $true
        Headers              = @{ Authorization = $AuthToken }
        ErrorAction          = "Stop"
    }
    if ($Body) { $PARAMS['Body'] = $Body }
    return Invoke-RestMethod @PARAMS
}

function Set-NinjaField {
    param([string]$FieldName, [string]$Value)
    if (-not $FieldName) { return }
    $NINJA_CMD = Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue
    if ($NINJA_CMD) {
        try {
            Ninja-Property-Set $FieldName $Value
            Write-Host "  [OK] $FieldName = $Value"
        } catch {
            Write-Warning "  Failed to write $FieldName : $_"
        }
    } else {
        Write-Host "  [SKIP] Ninja-Property-Set not available. $FieldName = $Value"
    }
}

# ============================================================
# INPUT HANDLING
# ============================================================

$SCRIPT_LOG_NAME = "veeam-create-s3-repo.log"

if ($env:RMM -ne "1") {
    # Interactive mode
    $VALID_INPUT = 0
    while ($VALID_INPUT -ne 1) {
        $env:DESCRIPTION = Read-Host "Ticket # or initials for audit trail"
        if ($env:DESCRIPTION) { $VALID_INPUT = 1 } else { Write-Host "Required." }
    }
    if (-not $env:CUSTOM_FIELD_ORG_UUID) { $env:CUSTOM_FIELD_ORG_UUID = Read-Host "Organization UUID (REQUIRED)" }
    if (-not $env:B2_ADMIN_KEY_ID) { $env:B2_ADMIN_KEY_ID = Read-Host "B2 admin key ID (master key)" }
    if (-not $env:B2_ADMIN_APP_KEY) { $env:B2_ADMIN_APP_KEY = Read-Host "B2 admin app key (master key)" }
    if (-not $env:B2_ENDPOINT) { $env:B2_ENDPOINT = Read-Host "B2 S3 endpoint (e.g. https://s3.us-west-002.backblazeb2.com)" }
    if (-not $env:B2_REGION) { $env:B2_REGION = Read-Host "B2 region (e.g. us-west-002)" }
    if (-not $env:IMMUTABILITY_DAYS) { $env:IMMUTABILITY_DAYS = Read-Host "Immutability period in days (default 14)" }

    $LOG_PATH = "$env:WINDIR\logs\$SCRIPT_LOG_NAME"
} else {
    if ($env:RMM_SCRIPT_PATH) {
        $LOG_DIR = "$env:RMM_SCRIPT_PATH\logs"
        if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null }
        $LOG_PATH = "$LOG_DIR\$SCRIPT_LOG_NAME"
    } else {
        $LOG_PATH = "$env:WINDIR\logs\$SCRIPT_LOG_NAME"
    }
    if (-not $env:DESCRIPTION) { $env:DESCRIPTION = "No Description" }
}

# Validate required inputs
if (-not $env:B2_ADMIN_KEY_ID -or -not $env:B2_ADMIN_APP_KEY) {
    Write-Error "B2_ADMIN_KEY_ID and B2_ADMIN_APP_KEY are required."
    exit 1
}
if (-not $env:B2_ENDPOINT) {
    Write-Error "B2_ENDPOINT is required."
    exit 1
}
if (-not $env:B2_REGION) {
    Write-Error "B2_REGION is required."
    exit 1
}

# Defaults
$IMMUTABILITY_DAYS = 14
if ($env:IMMUTABILITY_DAYS) {
    try { $IMMUTABILITY_DAYS = [int]$env:IMMUTABILITY_DAYS } catch {}
}

# ============================================================
# GENERATE BUCKET NAME
# ============================================================

Start-Transcript -Path $LOG_PATH

Write-Host "=== Veeam S3 Repository Creation ==="
Write-Host "Description: $env:DESCRIPTION"
Write-Host ""

# Org UUID: CUSTOM_FIELD_ORG_UUID contains the NinjaOne field NAME (e.g. "dtcOrgGuid").
# We pass that to Ninja-Property-Get to read the actual UUID value.
$ORG_UUID = $null
if ($env:CUSTOM_FIELD_ORG_UUID) {
    try {
        $ORG_UUID = Ninja-Property-Get $env:CUSTOM_FIELD_ORG_UUID 2>$null
    } catch { }
}
if (-not $ORG_UUID) {
    Write-Error "CUSTOM_FIELD_ORG_UUID is empty. Set the org UUID field in NinjaRMM."
    Stop-Transcript
    exit 1
}
# Validate it's actually a UUID, not a field name or garbage
if ($ORG_UUID -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    Write-Error "CUSTOM_FIELD_ORG_UUID value '$ORG_UUID' is not a valid UUID. Expected format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    Stop-Transcript
    exit 1
}
Write-Host "Org UUID: $ORG_UUID"
$ORG_PREFIX = $ORG_UUID.Replace("-", "").ToLower()

# Generate time-based short ID for this bucket
$BUCKET_SHORT_ID = New-TimeBasedShortId
$BUCKET_NAME = "$ORG_PREFIX-$BUCKET_SHORT_ID-veeam"

# S3 bucket name validation: lowercase alphanumeric + hyphens, 3-50 chars
$BUCKET_NAME = $BUCKET_NAME -replace '[^a-z0-9\-]', ''
if ($BUCKET_NAME.Length -gt 50) {
    # Truncate org prefix to fit
    $MAX_ORG = 50 - 1 - 8 - 1 - 5  # dash + shortid + dash + "veeam"
    $ORG_PREFIX = $ORG_PREFIX.Substring(0, $MAX_ORG)
    $BUCKET_NAME = "$ORG_PREFIX-$BUCKET_SHORT_ID-veeam"
}

Write-Host "Bucket name:       $BUCKET_NAME"
Write-Host "Org UUID:          $ORG_UUID"
Write-Host "Org prefix:        $ORG_PREFIX"
Write-Host "Bucket short ID:   $BUCKET_SHORT_ID"
Write-Host "Endpoint:          $env:B2_ENDPOINT"
Write-Host "Region:            $env:B2_REGION"
Write-Host "Immutability:      $IMMUTABILITY_DAYS days"
Write-Host ""

# ============================================================
# LOAD VEEAM MODULE
# ============================================================

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
    throw "Veeam.Backup.PowerShell module not found."
}

# ============================================================
# CHECK IF BUCKET + KEYS ALREADY EXIST (idempotency)
# ============================================================

# Try reading existing bucket name and scoped keys from NinjaOne
$EXISTING_BUCKET = $null
$EXISTING_KEY_ID = $null
$EXISTING_APP_KEY = $null
try {
    if ($env:CUSTOM_FIELD_S3_BUCKET_NAME) { $EXISTING_BUCKET = Ninja-Property-Get $env:CUSTOM_FIELD_S3_BUCKET_NAME 2>$null }
    if ($env:CUSTOM_FIELD_S3_KEY_ID) { $EXISTING_KEY_ID = Ninja-Property-Get $env:CUSTOM_FIELD_S3_KEY_ID 2>$null }
    if ($env:CUSTOM_FIELD_S3_APP_KEY) { $EXISTING_APP_KEY = Ninja-Property-Get $env:CUSTOM_FIELD_S3_APP_KEY 2>$null }
} catch { }

$SKIP_B2_CREATION = $false
if ($EXISTING_BUCKET -and $EXISTING_KEY_ID -and $EXISTING_APP_KEY) {
    Write-Host "Existing B2 bucket and keys found in RMM:"
    Write-Host "  Bucket:    $EXISTING_BUCKET"
    Write-Host "  Key ID:    $EXISTING_KEY_ID"
    Write-Host "  Skipping B2 bucket/key creation. Will create Veeam repo only."
    Write-Host ""
    $BUCKET_NAME = $EXISTING_BUCKET
    $SCOPED_KEY_ID = $EXISTING_KEY_ID
    $SCOPED_APP_KEY = $EXISTING_APP_KEY
    # Extract short ID from existing bucket name for folder creation
    if ($BUCKET_NAME -match '-([a-z0-9]{8})-veeam$') {
        $BUCKET_SHORT_ID = $Matches[1]
    }
    $SKIP_B2_CREATION = $true
}

$SCOPED_KEY_ID_OUT = $null
$SCOPED_APP_KEY_OUT = $null

if (-not $SKIP_B2_CREATION) {
    # ============================================================
    # B2 API: AUTH WITH ADMIN KEY
    # ============================================================

    Write-Host ""
    Write-Host "Authenticating to B2 with admin key..."

    $B2_SECURE_KEY = ConvertTo-SecureString $env:B2_ADMIN_APP_KEY -AsPlainText -Force
    $B2_CREDENTIAL = [PSCredential]::new($env:B2_ADMIN_KEY_ID, $B2_SECURE_KEY)

    $B2_AUTH = $null
    $B2_API_VER = "v2"
    foreach ($VER in @("v2", "v4")) {
        try {
            $B2_AUTH = Invoke-RestMethod -Uri "https://api.backblazeb2.com/b2api/$VER/b2_authorize_account" `
                -Method GET `
                -Authentication Basic `
                -Credential $B2_CREDENTIAL `
                -ErrorAction Stop
            $B2_API_VER = $VER
            break
        } catch { }
    }
    if (-not $B2_AUTH) {
        Write-Error "B2 authentication failed. Check B2_ADMIN_KEY_ID and B2_ADMIN_APP_KEY."
        Stop-Transcript
        exit 1
    }

    $B2_API_URL = $B2_AUTH.apiUrl
    if (-not $B2_API_URL) { $B2_API_URL = $B2_AUTH.apiInfo.storageApi.apiUrl }
    $B2_AUTH_TOKEN = $B2_AUTH.authorizationToken
    $B2_ACCOUNT_ID = $B2_AUTH.accountId

    Write-Host "  [OK] Account: $B2_ACCOUNT_ID (api: $B2_API_VER)"

    # ============================================================
    # CREATE B2 BUCKET
    # ============================================================

    Write-Host ""
    Write-Host "Creating B2 bucket: $BUCKET_NAME"

    try {
        $CREATE_BODY = @{
            accountId       = $B2_ACCOUNT_ID
            bucketName      = $BUCKET_NAME
            bucketType      = "allPrivate"
            fileLockEnabled = $true
        } | ConvertTo-Json

        $B2_BUCKET = Invoke-B2Api -Uri "$B2_API_URL/b2api/$B2_API_VER/b2_create_bucket" `
            -AuthToken $B2_AUTH_TOKEN -Body $CREATE_BODY

        Write-Host "  [OK] Bucket created: $($B2_BUCKET.bucketName) (ID: $($B2_BUCKET.bucketId))"
    } catch {
        Write-Error "B2 bucket creation failed: $_"
        Stop-Transcript
        exit 1
    }

    # Set default retention + lifecycle rule to purge hidden versions
    # Hidden files = old versions replaced by newer uploads or deleted by Veeam.
    # Without this rule, B2 keeps ALL versions forever and storage balloons.
    # daysFromHidingToDeleting = immutability + 1 day buffer so locked files
    # are never deleted before retention expires.
    $LIFECYCLE_PURGE_DAYS = $IMMUTABILITY_DAYS + 1

    try {
        $UPDATE_BODY = @{
            accountId        = $B2_ACCOUNT_ID
            bucketId         = $B2_BUCKET.bucketId
            defaultRetention = @{
                mode   = "governance"
                period = @{
                    duration = $IMMUTABILITY_DAYS
                    unit     = "days"
                }
            }
            lifecycleRules   = @(
                @{
                    daysFromHidingToDeleting  = $LIFECYCLE_PURGE_DAYS
                    daysFromUploadingToHiding = $null
                    fileNamePrefix            = ""
                }
            )
        } | ConvertTo-Json -Depth 5

        Invoke-B2Api -Uri "$B2_API_URL/b2api/$B2_API_VER/b2_update_bucket" `
            -AuthToken $B2_AUTH_TOKEN -Body $UPDATE_BODY | Out-Null

        Write-Host "  [OK] Default retention: $IMMUTABILITY_DAYS days (governance mode)"
        Write-Host "  [OK] Lifecycle rule: delete hidden versions after $LIFECYCLE_PURGE_DAYS days"
    } catch {
        Write-Warning "  Failed to set retention/lifecycle: $_"
    }

    # ============================================================
    # CREATE SCOPED APPLICATION KEY (bucket-only access)
    # ============================================================

    Write-Host ""
    Write-Host "Creating scoped application key for bucket: $BUCKET_NAME"

    try {
        $KEY_BODY = @{
            accountId    = $B2_ACCOUNT_ID
            capabilities = @(
                "listBuckets"
                "listAllBucketNames"
                "readBuckets"
                "listFiles"
                "readFiles"
                "writeFiles"
                "deleteFiles"
                "readBucketEncryption"
                "writeBucketEncryption"
                "readBucketRetentions"
                "writeBucketRetentions"
                "readFileRetentions"
                "writeFileRetentions"
                "readFileLegalHolds"
                "writeFileLegalHolds"
                "bypassGovernance"
            )
            keyName      = $BUCKET_NAME
            bucketId     = $B2_BUCKET.bucketId
        } | ConvertTo-Json

        $KEY_RESPONSE = Invoke-B2Api -Uri "$B2_API_URL/b2api/$B2_API_VER/b2_create_key" `
            -AuthToken $B2_AUTH_TOKEN -Body $KEY_BODY

        $SCOPED_KEY_ID = $KEY_RESPONSE.applicationKeyId
        $SCOPED_APP_KEY = $KEY_RESPONSE.applicationKey

        Write-Host "  [OK] Scoped key created: $SCOPED_KEY_ID"
        Write-Host "  Bucket restriction: $($B2_BUCKET.bucketName) ($($B2_BUCKET.bucketId))"
    } catch {
        Write-Error "Failed to create scoped application key: $_"
        Write-Host "  Bucket ($BUCKET_NAME) was created but no scoped key exists."
        Stop-Transcript
        exit 1
    }

    $SCOPED_KEY_ID_OUT = $SCOPED_KEY_ID
    $SCOPED_APP_KEY_OUT = $SCOPED_APP_KEY

    # Save to NinjaOne immediately so credentials aren't lost if Veeam fails
    Write-Host ""
    Write-Host "Saving B2 credentials to NinjaOne..."
    Set-NinjaField $env:CUSTOM_FIELD_S3_BUCKET_NAME $BUCKET_NAME
    Set-NinjaField $env:CUSTOM_FIELD_S3_KEY_ID $SCOPED_KEY_ID_OUT
    Set-NinjaField $env:CUSTOM_FIELD_S3_APP_KEY $SCOPED_APP_KEY_OUT

    # Let the scoped key propagate before Veeam tries to use it
    Write-Host "  Waiting 5 seconds for key propagation..."
    Start-Sleep -Seconds 5
} else {
    $SCOPED_KEY_ID_OUT = $SCOPED_KEY_ID
    $SCOPED_APP_KEY_OUT = $SCOPED_APP_KEY
}

# ============================================================
# CREATE VEEAM S3 REPOSITORY
# ============================================================

Write-Host ""
Write-Host "Creating Veeam S3 repository: $BUCKET_NAME"

try {
    # Add the SCOPED B2 credentials to Veeam (not the admin key)
    $VEEAM_ACCOUNT = Add-VBRAmazonAccount `
        -AccessKey $SCOPED_KEY_ID_OUT `
        -SecretKey $SCOPED_APP_KEY_OUT `
        -Description "$env:DESCRIPTION $BUCKET_NAME"

    Write-Host "  [OK] Veeam account added."

    # Connect to the S3-compatible service
    $VEEAM_CONNECTION = Connect-VBRAmazonS3CompatibleService `
        -Account $VEEAM_ACCOUNT `
        -CustomRegionId $env:B2_REGION `
        -ServicePoint $env:B2_ENDPOINT

    Write-Host "  [OK] Connected to S3 endpoint."

    # Get the bucket
    $VEEAM_BUCKET = Get-VBRAmazonS3Bucket -Connection $VEEAM_CONNECTION -Name $BUCKET_NAME
    Write-Host "  [OK] Bucket found in Veeam."

    # Create a folder inside the bucket (use the short ID as folder name)
    $VEEAM_FOLDER = New-VBRAmazonS3Folder -Name $BUCKET_SHORT_ID -Connection $VEEAM_CONNECTION -Bucket $VEEAM_BUCKET
    Write-Host "  [OK] Folder created: $BUCKET_SHORT_ID"

    # Detect Veeam version for the EnableBucketAutoProvision parameter
    $VEEAM_VERSION = [version](Get-Item 'C:\Program Files\Veeam\Backup and Replication\Backup\Packages\VeeamDeploymentDll.dll').VersionInfo.ProductVersion
    $NEEDS_AUTOPROVISION = $VEEAM_VERSION -ge [version]"12.3.1.1139"

    # Create the repository (name = bucket name)
    $REPO_PARAMS = @{
        AmazonS3Folder          = $VEEAM_FOLDER
        Connection              = $VEEAM_CONNECTION
        Name                    = $BUCKET_NAME
        EnableBackupImmutability = $true
        ImmutabilityPeriod      = $IMMUTABILITY_DAYS
        Description             = "$env:DESCRIPTION $BUCKET_NAME"
    }
    if ($NEEDS_AUTOPROVISION) {
        $REPO_PARAMS['EnableBucketAutoProvision'] = $false
    }

    $VEEAM_REPO = Add-VBRAmazonS3CompatibleRepository @REPO_PARAMS

    Write-Host "  [OK] Veeam repository created: $($VEEAM_REPO.Name)"
} catch {
    Write-Error "Veeam repository creation failed: $_"
    Write-Host "  The B2 bucket ($BUCKET_NAME) was created but the Veeam repo was not."
    Write-Host "  You may need to add it manually in the Veeam console."
    Stop-Transcript
    exit 1
}

# ============================================================
# STORE RESULT
# ============================================================

Write-Host ""
Write-Host "=== Complete ==="
Write-Host "  Bucket:       $BUCKET_NAME"
Write-Host "  Repository:   $BUCKET_NAME"
Write-Host "  Folder:       $BUCKET_SHORT_ID"
Write-Host "  Scoped key:   $SCOPED_KEY_ID_OUT"
Write-Host "  Immutability: $IMMUTABILITY_DAYS days"
Write-Host ""


Write-Host ""
Write-Host "=== Script complete ==="

Stop-Transcript
