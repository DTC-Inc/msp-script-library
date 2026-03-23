# Diagnostic: step-by-step Veeam S3 repo creation
# Run interactively on the BDR server in PS7

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $PWSH = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($PWSH) { & $PWSH.Source -NoProfile -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path; exit $LASTEXITCODE }
}

$MY_MODULE_PATH = "C:\Program Files\Veeam\Backup and Replication\Console\"
$env:PSModulePath = $env:PSModulePath + "$([System.IO.Path]::PathSeparator)$MY_MODULE_PATH"
Get-Module -ListAvailable -Name Veeam.Backup.PowerShell | Import-Module -WarningAction SilentlyContinue

$ConfirmPreference = 'None'

# ---- Fill in from last successful B2 run ----
$BUCKET_NAME  = "7d591672a90f426db980ba861165c2aa-mn3jar51-veeam"
$SHORT_ID     = "mn3jar51"
$ENDPOINT     = "https://s3.us-west-002.backblazeb2.com"
$REGION       = "us-west-002"
$IMMUTABILITY = 14

$KEY_ID  = Read-Host "Scoped B2 Key ID (from NinjaOne S3_KEY_ID field)"
$APP_KEY = Read-Host "Scoped B2 App Key (from NinjaOne S3_APP_KEY field)"

Write-Host ""
Write-Host "=========================================="
Write-Host "Config"
Write-Host "=========================================="
Write-Host "  Bucket:      $BUCKET_NAME"
Write-Host "  Folder:      $SHORT_ID"
Write-Host "  Endpoint:    $ENDPOINT"
Write-Host "  Region:      $REGION"
Write-Host "  Immutability: $IMMUTABILITY days"
Write-Host "  Key ID:      $($KEY_ID.Substring(0,8))..."
Write-Host ""

Write-Host "=========================================="
Write-Host "Step 1: Get-Help Add-VBRAmazonS3CompatibleRepository"
Write-Host "=========================================="
$CMD = Get-Command Add-VBRAmazonS3CompatibleRepository
Write-Host "Parameters:"
$CMD.Parameters.Keys | Sort-Object | ForEach-Object { Write-Host "  $_" }
Write-Host ""

Write-Host "=========================================="
Write-Host "Step 2: Add-VBRAmazonAccount"
Write-Host "=========================================="
try {
    $ACCOUNT = Add-VBRAmazonAccount -AccessKey $KEY_ID -SecretKey $APP_KEY -Description "diag $BUCKET_NAME"
    Write-Host "  [OK] Account: $($ACCOUNT.Id)"
} catch {
    Write-Host "  FAILED: $_"
    exit 1
}

Write-Host ""
Write-Host "=========================================="
Write-Host "Step 3: Connect-VBRAmazonS3CompatibleService"
Write-Host "=========================================="
try {
    $CONN = Connect-VBRAmazonS3CompatibleService -Account $ACCOUNT -CustomRegionId $REGION -ServicePoint $ENDPOINT
    Write-Host "  [OK] Connected"
} catch {
    Write-Host "  FAILED: $_"
    exit 1
}

Write-Host ""
Write-Host "=========================================="
Write-Host "Step 4: Get-VBRAmazonS3Bucket"
Write-Host "=========================================="
try {
    $BUCKET = Get-VBRAmazonS3Bucket -Connection $CONN -Name $BUCKET_NAME
    Write-Host "  [OK] Bucket found: $($BUCKET.Name)"
} catch {
    Write-Host "  FAILED: $_"
    exit 1
}

Write-Host ""
Write-Host "=========================================="
Write-Host "Step 5: New-VBRAmazonS3Folder"
Write-Host "=========================================="
try {
    $FOLDER = New-VBRAmazonS3Folder -Name $SHORT_ID -Connection $CONN -Bucket $BUCKET
    Write-Host "  [OK] Folder: $($FOLDER.Name)"
} catch {
    Write-Host "  FAILED: $_"
    # Folder might already exist, try to get it
    try {
        $FOLDER = Get-VBRAmazonS3Folder -Connection $CONN -Bucket $BUCKET | Where-Object { $_.Name -eq $SHORT_ID }
        Write-Host "  [OK] Folder already exists: $($FOLDER.Name)"
    } catch {
        Write-Host "  Could not get existing folder: $_"
        exit 1
    }
}

Write-Host ""
Write-Host "=========================================="
Write-Host "Step 6: Add-VBRAmazonS3CompatibleRepository (WITHOUT immutability)"
Write-Host "=========================================="
Write-Host "  Trying without immutability first to isolate the hang..."
Write-Host ""
try {
    $REPO = Add-VBRAmazonS3CompatibleRepository `
        -Name $BUCKET_NAME `
        -Connection $CONN `
        -AmazonS3Folder $FOLDER `
        -EnableBucketAutoProvision:$false `
        -Description "diag $BUCKET_NAME"

    Write-Host "  [OK] Repo created WITHOUT immutability: $($REPO.Name)"
    Write-Host ""
    Write-Host "  Now try enabling immutability via Set-VBRAmazonS3CompatibleRepository..."
    try {
        Set-VBRAmazonS3CompatibleRepository -Repository $REPO `
            -EnableBackupImmutability `
            -ImmutabilityPeriod $IMMUTABILITY `
            -EnableBucketAutoProvision:$false

        Write-Host "  [OK] Immutability enabled!"
    } catch {
        Write-Host "  Set immutability FAILED: $_"
        Write-Host "  Repo exists but without immutability. Enable it in the Veeam console."
    }
} catch {
    Write-Host "  FAILED: $_"
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "Step 6b: Try with immutability in one shot"
    Write-Host "=========================================="
    try {
        $REPO = Add-VBRAmazonS3CompatibleRepository `
            -Name "$BUCKET_NAME-v2" `
            -Connection $CONN `
            -AmazonS3Folder $FOLDER `
            -EnableBackupImmutability `
            -ImmutabilityPeriod $IMMUTABILITY `
            -EnableBucketAutoProvision:$false `
            -Description "diag $BUCKET_NAME"

        Write-Host "  [OK] Repo created WITH immutability: $($REPO.Name)"
    } catch {
        Write-Host "  FAILED: $_"
    }
}

Write-Host ""
Write-Host "=========================================="
Write-Host "Done"
Write-Host "=========================================="
