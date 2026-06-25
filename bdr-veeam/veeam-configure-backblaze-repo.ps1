## Creates a Backblaze B2 bucket, generates a scoped application key with
## read/write access to only that bucket, registers the Veeam S3 repository
## using the scoped key, and stores credentials in NinjaRMM device fields.
##
## Bucket naming: veeam-{LOCATION_OUID_no_dashes}
## Folder (object prefix) inside the bucket: {device_ouid_dashed}/
## Veeam repository name = bucket name
##
## Isolation is per-LOCATION (not per-org): locations get bought and sold, so the
## storage boundary tracks the location OUID, read at runtime from NinjaOne. The
## per-DEVICE folder (the BDR's device OUID) is the repository root for this BDR.
## A single location bucket can hold more than one BDR while keeping each one's
## data in its own prefix. The device OUID is used (not Veeam's internal instance
## GUID, not a timestamp) because it is recomputable from a stable source: it is
## minted once and persisted on the device (registry + NinjaOne), so re-runs and
## rebuilds resolve to the SAME folder and reclaim existing data. Mint it first
## with rmm-ninja\ninja-ensure-device-guid.ps1.
##
## ADMIN CREDENTIALS (org-level in NinjaRMM, used to create bucket + scoped key):
## $env:B2_ADMIN_KEY_ID               - Master/admin B2 application key ID
## $env:B2_ADMIN_APP_KEY              - Master/admin B2 application key
##
## CONFIGURATION:
## $env:CUSTOM_FIELD_LOCATION_UUID     - NinjaOne text field containing the location OUID (REQUIRED)
## $env:CUSTOM_FIELD_DEVICE_GUID       - NinjaOne device text field containing the device OUID (fallback if registry is empty)
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
    # Always prefer 64-bit PS7. Veeam's native SQLite DLL is x64 only.
    $PWSH_PATH = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    if (-not (Test-Path $PWSH_PATH)) {
        $PWSH_CANDIDATE = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        $PWSH_PATH = if ($PWSH_CANDIDATE) { $PWSH_CANDIDATE.Source } else { $null }
    }
    if (Test-Path $PWSH_PATH) {
        Write-Host "PowerShell $($PSVersionTable.PSVersion) detected. Re-launching in PowerShell 7 at: $PWSH_PATH"
        $PS_ARGS = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path)
        & $PWSH_PATH @PS_ARGS
        exit $LASTEXITCODE
    } else {
        Write-Warning "PowerShell 7 (pwsh.exe) not found. Veeam module may fail to load."
    }
}

# Fix PS7.4+ / Veeam SQLite conflict.
# The type initializer for Microsoft.Data.Sqlite.SqliteConnection fails because
# it can't find the native e_sqlite3 library. Add Veeam's directory to the
# native DLL search path so the managed assembly can find its native dependency.
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $VEEAM_BACKUP_DIR = "$env:ProgramFiles\Veeam\Backup and Replication\Backup"
    $VEEAM_RUNTIMES = "$env:ProgramFiles\Veeam\Backup and Replication\Backup\runtimes\win-x64\native"

    # Add Veeam paths to PATH so native DLLs (e_sqlite3.dll) are found
    foreach ($DIR in @($VEEAM_RUNTIMES, $VEEAM_BACKUP_DIR)) {
        if ((Test-Path $DIR) -and $env:PATH -notlike "*$DIR*") {
            $env:PATH = "$DIR;$env:PATH"
        }
    }

    # Also register assembly resolve for managed DLLs
    if (Test-Path $VEEAM_BACKUP_DIR) {
        $null = [System.AppDomain]::CurrentDomain.add_AssemblyResolve({
            param($sender, $args)
            if (-not $args.Name) { return $null }
            $ASSEMBLY_NAME = [System.Reflection.AssemblyName]::new($args.Name)
            $VEEAM_DLL = Join-Path $VEEAM_BACKUP_DIR "$($ASSEMBLY_NAME.Name).dll"
            if (Test-Path $VEEAM_DLL) {
                return [System.Reflection.Assembly]::LoadFrom($VEEAM_DLL)
            }
            return $null
        })
    }
}

# ============================================================
# HELPER FUNCTIONS
# ============================================================

$GUID_REGEX = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

function Get-DeviceOuid {
    # Returns this device's OUID (the "Device GUID"), used as the repository-root
    # folder name inside the location bucket. Per the DTC OUID Standard, the
    # device OUID is minted once and persisted on the device, so it is
    # recomputable from a stable source: re-runs and rebuilds resolve to the SAME
    # folder and reclaim existing backup data. Mint it with
    # rmm-ninja\ninja-ensure-device-guid.ps1 before running this script.
    #
    # Sources tried in order: (1) on-device registry (authoritative mirror, no
    # network needed), (2) NinjaOne device custom field. Returns $null if neither
    # holds a valid GUID -- caller must handle that.

    # 1. On-device registry: HKLM\SOFTWARE\DTC\DeviceGuid
    try {
        $REG = Get-ItemProperty -Path 'HKLM:\SOFTWARE\DTC' -Name 'DeviceGuid' -ErrorAction Stop
        if ($REG.DeviceGuid -and "$($REG.DeviceGuid)" -match $GUID_REGEX) {
            return "$($REG.DeviceGuid)".ToLower()
        }
    } catch { }

    # 2. NinjaOne device custom field
    if ($env:CUSTOM_FIELD_DEVICE_GUID) {
        try {
            $NINJA_VAL = Ninja-Property-Get $env:CUSTOM_FIELD_DEVICE_GUID 2>$null
            if ($NINJA_VAL -and "$NINJA_VAL" -match $GUID_REGEX) {
                return "$NINJA_VAL".ToLower()
            }
        } catch { }
    }

    return $null
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
    param(
        [string]$FieldName,
        [string]$Value,
        [switch]$Secret
    )
    if (-not $FieldName) { return }
    $DISPLAY = if ($Secret -and $Value.Length -gt 4) { "$($Value.Substring(0, 4))***" } else { $Value }
    $NINJA_CMD = Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue
    if ($NINJA_CMD) {
        try {
            Ninja-Property-Set $FieldName $Value
            Write-Host "  [OK] $FieldName = $DISPLAY"
        } catch {
            Write-Warning "  Failed to write $FieldName : $_"
        }
    } else {
        Write-Host "  [SKIP] Ninja-Property-Set not available. $FieldName = $DISPLAY"
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
    if (-not $env:CUSTOM_FIELD_LOCATION_UUID) { $env:CUSTOM_FIELD_LOCATION_UUID = Read-Host "Location OUID NinjaOne field name (REQUIRED)" }
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

# Location OUID: CUSTOM_FIELD_LOCATION_UUID contains the NinjaOne field NAME
# (e.g. "dtcLocationGuid"). We pass that to Ninja-Property-Get to read the value.
# Isolation is per-location: locations get bought/sold, so the bucket tracks the
# location OUID rather than the org.
$LOCATION_UUID = $null
if ($env:CUSTOM_FIELD_LOCATION_UUID) {
    try {
        $LOCATION_UUID = Ninja-Property-Get $env:CUSTOM_FIELD_LOCATION_UUID 2>$null
    } catch { }
}
if (-not $LOCATION_UUID) {
    Write-Error "CUSTOM_FIELD_LOCATION_UUID is empty. Set the location OUID field in NinjaRMM."
    Stop-Transcript
    exit 1
}
# Validate it's actually a UUID, not a field name or garbage
if ($LOCATION_UUID -notmatch $GUID_REGEX) {
    Write-Error "CUSTOM_FIELD_LOCATION_UUID value '$LOCATION_UUID' is not a valid UUID. Expected format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    Stop-Transcript
    exit 1
}
Write-Host "Location OUID: $LOCATION_UUID"
$LOCATION_PREFIX = $LOCATION_UUID.Replace("-", "").ToLower()

# Bucket name = veeam-{location-ouid-flat}. Deterministic: re-runs compute the
# same name. "veeam-" (6) + 32 hex = 38 chars, within B2's 50-char limit.
$BUCKET_NAME = "veeam-$LOCATION_PREFIX"

# S3 bucket name validation: lowercase alphanumeric + hyphens, 3-50 chars
$BUCKET_NAME = $BUCKET_NAME -replace '[^a-z0-9\-]', ''
if ($BUCKET_NAME.Length -gt 50) {
    $BUCKET_NAME = $BUCKET_NAME.Substring(0, 50)
}

Write-Host "Bucket name:       $BUCKET_NAME"
Write-Host "Location OUID:     $LOCATION_UUID"
Write-Host "Location prefix:   $LOCATION_PREFIX"
Write-Host "Endpoint:          $env:B2_ENDPOINT"
Write-Host "Region:            $env:B2_REGION"
Write-Host "Immutability:      $IMMUTABILITY_DAYS days"
Write-Host ""

# ============================================================
# LOAD VEEAM MODULE
# ============================================================

Write-Host "Loading Veeam PowerShell module..."
$MY_MODULE_PATH = "$env:ProgramFiles\Veeam\Backup and Replication\Console\"
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
# RESOLVE THIS DEVICE'S OUID (repository-root folder name)
# ============================================================

Write-Host ""
Write-Host "Resolving device OUID..."
$DEVICE_GUID = Get-DeviceOuid
if (-not $DEVICE_GUID) {
    Write-Error "Could not resolve a device OUID. Run rmm-ninja\ninja-ensure-device-guid.ps1 on this device first (mints + persists the Device GUID), then re-run."
    Stop-Transcript
    exit 1
}
Write-Host "  [OK] Device OUID: $DEVICE_GUID"

# ============================================================
# CHECK IF BUCKET + KEYS ALREADY EXIST (idempotency)
# ============================================================

# Try reading existing bucket name and scoped keys from NinjaOne
Write-Host "Checking for existing B2 credentials in NinjaOne..."
Write-Host "  CUSTOM_FIELD_S3_BUCKET_NAME env: '$($env:CUSTOM_FIELD_S3_BUCKET_NAME)'"
Write-Host "  CUSTOM_FIELD_S3_KEY_ID env:      '$($env:CUSTOM_FIELD_S3_KEY_ID)'"
Write-Host "  CUSTOM_FIELD_S3_APP_KEY env:     '$($env:CUSTOM_FIELD_S3_APP_KEY)'"

$EXISTING_BUCKET = $null
$EXISTING_KEY_ID = $null
$EXISTING_APP_KEY = $null

# Read existing values from NinjaOne device fields
$NINJA_AVAILABLE = $null -ne (Get-Command "Ninja-Property-Get" -ErrorAction SilentlyContinue)
if ($NINJA_AVAILABLE) {
    try {
        if ($env:CUSTOM_FIELD_S3_BUCKET_NAME) {
            $EXISTING_BUCKET = Ninja-Property-Get $env:CUSTOM_FIELD_S3_BUCKET_NAME 2>$null
            Write-Host "  Bucket value:  '$EXISTING_BUCKET'"
        }
        if ($env:CUSTOM_FIELD_S3_KEY_ID) {
            $EXISTING_KEY_ID = Ninja-Property-Get $env:CUSTOM_FIELD_S3_KEY_ID 2>$null
            Write-Host "  Key ID value:  $(if ($EXISTING_KEY_ID) { 'set' } else { 'empty' })"
        }
        if ($env:CUSTOM_FIELD_S3_APP_KEY) {
            $EXISTING_APP_KEY = Ninja-Property-Get $env:CUSTOM_FIELD_S3_APP_KEY 2>$null
            Write-Host "  App Key value: $(if ($EXISTING_APP_KEY) { 'set' } else { 'empty' })"
        }
    } catch {
        Write-Warning "  Ninja-Property-Get failed: $_"
    }
} else {
    Write-Host "  Ninja-Property-Get not available (not running in NinjaRMM)."
}

$SKIP_B2_CREATION = $false
if ($EXISTING_BUCKET -and $EXISTING_KEY_ID -and $EXISTING_APP_KEY) {
    Write-Host "Existing B2 bucket and keys found in RMM:"
    Write-Host "  Bucket:    $EXISTING_BUCKET"
    Write-Host "  Key ID:    $($EXISTING_KEY_ID.Substring(0, [Math]::Min(8, $EXISTING_KEY_ID.Length)))..."
    Write-Host "  Skipping B2 bucket/key creation. Will create Veeam repo only."
    Write-Host ""
    $BUCKET_NAME = $EXISTING_BUCKET
    $SCOPED_KEY_ID = $EXISTING_KEY_ID
    $SCOPED_APP_KEY = $EXISTING_APP_KEY
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

    # Set lifecycle rule to purge hidden (old) file versions.
    # Without this, B2 keeps ALL versions forever and storage balloons.
    # daysFromHidingToDeleting = immutability + 1 day buffer so locked files
    # are never deleted before retention expires.
    # NOTE: Do NOT set bucket-level defaultRetention here. Veeam manages
    # immutability/retention itself via per-object locks. Setting a bucket
    # default causes "default retention is not supported" errors in Veeam.
    $LIFECYCLE_PURGE_DAYS = $IMMUTABILITY_DAYS + 1

    try {
        $UPDATE_BODY = @{
            accountId             = $B2_ACCOUNT_ID
            bucketId              = $B2_BUCKET.bucketId
            defaultServerSideEncryption = @{
                mode      = "SSE-B2"
                algorithm = "AES256"
            }
            lifecycleRules        = @(
                @{
                    daysFromHidingToDeleting  = $LIFECYCLE_PURGE_DAYS
                    daysFromUploadingToHiding = $null
                    fileNamePrefix            = ""
                }
            )
        } | ConvertTo-Json -Depth 5

        Invoke-B2Api -Uri "$B2_API_URL/b2api/$B2_API_VER/b2_update_bucket" `
            -AuthToken $B2_AUTH_TOKEN -Body $UPDATE_BODY | Out-Null

        Write-Host "  [OK] Server-side encryption: SSE-B2 (AES256)"
        Write-Host "  [OK] Lifecycle rule: delete hidden versions after $LIFECYCLE_PURGE_DAYS days"
    } catch {
        Write-Warning "  Failed to set encryption/lifecycle: $_"
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

        Write-Host "  [OK] Scoped key created: $($SCOPED_KEY_ID.Substring(0, [Math]::Min(8, $SCOPED_KEY_ID.Length)))..."
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
    Set-NinjaField $env:CUSTOM_FIELD_S3_KEY_ID $SCOPED_KEY_ID_OUT -Secret
    Set-NinjaField $env:CUSTOM_FIELD_S3_APP_KEY $SCOPED_APP_KEY_OUT -Secret

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
    # Suppress all confirmation prompts
    $ConfirmPreference = 'None'

    # Pre-trust the B2 endpoint SSL certificate so Veeam doesn't prompt
    Write-Host "  Pre-trusting SSL certificate for $env:B2_ENDPOINT..."
    try {
        $ENDPOINT_URI = [System.Uri]$env:B2_ENDPOINT
        $TCP = [System.Net.Sockets.TcpClient]::new($ENDPOINT_URI.Host, 443)
        $SSL = [System.Net.Security.SslStream]::new($TCP.GetStream(), $false, { $true })
        $SSL.AuthenticateAsClient($ENDPOINT_URI.Host)
        $CERT = $SSL.RemoteCertificate
        $SSL.Dispose()
        $TCP.Dispose()

        if ($CERT) {
            # Import the cert to Trusted Root if not already there
            $X509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CERT)
            $STORE = [System.Security.Cryptography.X509Certificates.X509Store]::new(
                [System.Security.Cryptography.X509Certificates.StoreName]::Root,
                [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine
            )
            $STORE.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $STORE.Add($X509)
            $STORE.Close()
            Write-Host "  [OK] Certificate trusted: $($X509.Subject)"
        }
    } catch {
        Write-Warning "  Could not pre-trust certificate: $_"
    }

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

    # Create a folder inside the bucket, named for this device's OUID. This is
    # the repository root for THIS BDR; Veeam owns everything below it. Another
    # BDR at the same location gets its own folder. The device OUID is stable, so
    # a rebuild of this BDR resolves to the same folder and reclaims its data.
    $VEEAM_FOLDER = New-VBRAmazonS3Folder -Name $DEVICE_GUID -Connection $VEEAM_CONNECTION -Bucket $VEEAM_BUCKET
    Write-Host "  [OK] Folder created: $DEVICE_GUID"

    # Create the repository (name = bucket name)
    # -Confirm:$false suppresses ShouldProcess prompts
    # -EnableBucketAutoProvision:$false prevents hang on S3-compatible endpoints
    #   (default changed to $true in Veeam 12.3.1, causes hang on non-AWS S3)
    $REPO_PARAMS = @{
        AmazonS3Folder              = $VEEAM_FOLDER
        Connection                  = $VEEAM_CONNECTION
        Name                        = $BUCKET_NAME
        EnableBackupImmutability     = $true
        ImmutabilityPeriod          = $IMMUTABILITY_DAYS
        EnableBucketAutoProvision   = $false
        Description                 = "$env:DESCRIPTION $BUCKET_NAME"
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
Write-Host "  Folder:       $DEVICE_GUID"
Write-Host "  Scoped key:   $($SCOPED_KEY_ID_OUT.Substring(0, [Math]::Min(8, $SCOPED_KEY_ID_OUT.Length)))..."
Write-Host "  Immutability: $IMMUTABILITY_DAYS days"
Write-Host ""


Write-Host ""
Write-Host "=== Script complete ==="

Stop-Transcript
