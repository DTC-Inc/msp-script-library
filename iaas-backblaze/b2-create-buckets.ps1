## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $userApiKey     / $env:userApiKey     - REQUIRED. Backblaze B2 API Key ID
## $userApiSecret  / $env:userApiSecret  - REQUIRED. Backblaze B2 API App Key
## $clientListFile / $env:clientListFile - Optional. Set to 1 to import the client list from a CSV file
## $path           / $env:path           - Optional. Path to the client list CSV file (used when $clientListFile -eq 1)
## $clientList     / $env:clientList     - Optional. Clients comma separated, exactly as in your PSA
## $client         / $env:client         - Optional. Single client to create a bucket for
## $rmmScriptPath  / $env:rmmScriptPath  - Optional log/exe directory base provided by the RMM

# Please make sure that b2-windows.exe is in the script root. All logs and data exported is stored here.

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-userApiKey ...) or from an RMM that supplies the values as env variables.
    [string]$userApiKey     = $env:userApiKey,
    [string]$userApiSecret  = $env:userApiSecret,
    [string]$clientListFile = $env:clientListFile,
    [string]$path           = $env:path,
    [string]$clientList     = $env:clientList,
    [string]$client         = $env:client,
    [string]$rmmScriptPath  = $env:rmmScriptPath
)

# global variables
$lifecycleRules = @'
[{
     "daysFromHidingToDeleting": 1,
     "daysFromUploadingToHiding": null,
     "fileNamePrefix": ""
}]
'@

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Required inputs must come from -Parameter or $env: -- there is no prompt.
$missing = @()
if (-not $userApiKey)    { $missing += 'userApiKey' }
if (-not $userApiSecret) { $missing += 'userApiSecret' }
if ($missing.Count -gt 0) {
    Write-Error "ERROR: Required input(s) not provided (set as -Parameter or `$env:): $($missing -join ', ')"
    exit 1
}

# Determine the directory base for b2-windows.exe and logs. Use $rmmScriptPath when the RMM
# provides one, otherwise the script root.
if (-not [string]::IsNullOrEmpty($rmmScriptPath)) {
    $scriptBase = $rmmScriptPath
    $LogPath = "$rmmScriptPath\logs\backblaze-create-buckets.log"
} else {
    $scriptBase = $psScriptRoot
    $LogPath = "$psScriptRoot\backblaze-create-buckets.log"
}

# Ensure log directory exists before starting the transcript
$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# --- Script logic --------------------------------------------------------

Start-Transcript -Path $LogPath

$filePath = Join-Path -Path $scriptBase -ChildPath "b2-windows.exe"

if (-not (Test-Path -Path $filePath)) {
    $url = "https://repo.dtctoday.com/file/public-dtc/scripts/b2-windows.exe"  # Replace with the actual download URL

    Write-Host "Downloading file..."
    $webClient = New-Object System.Net.WebClient
    $webClient.DownloadFile($url, $filePath)
    Write-Host "File downloaded successfully."
} else {
    Write-Host "File already exists."
}

# Build the list of buckets to create. A single $client is processed as one bucket; a
# $clientList (or a CSV file when $clientListFile -eq 1) is processed as many buckets.
if (-not [string]::IsNullOrEmpty($client)) {
    $cleanedClient = $client -replace '\W','' -replace ' ','-' | ForEach-Object { $_.ToLower() }
    $bucketList = @("veeam-dtc-$cleanedClient")
} elseif ($clientListFile -eq 1) {
    # Get client list
    $bucketList = Import-Csv $path | Select-Object -Skip 1 | ForEach-Object {
        $row = $_.PSObject.Properties.Value
        $cleanedRow = $row -replace '\W','' -replace ' ','-' | ForEach-Object { $_.ToLower() }
        $bucket = "veeam-dtc-$cleanedRow"
        $bucket
    }
} else {
    $bucketList = $clientList | ForEach-Object {
        $row = $_.PSObject.Properties.Value
        $cleanedRow = $row -replace '\W','' -replace ' ','-' | ForEach-Object { $_.ToLower() }
        $bucket = "veeam-dtc-$cleanedRow"
        $bucket
    }
}

# Create bucket for each client
foreach ($bucketName in $bucketList) {
    Write-Host "Creating bucket: $bucketName"
    & "$scriptBase\b2-windows.exe" authorize-account $userApiKey $userApiSecret
    & "$scriptBase\b2-windows.exe" create-bucket --defaultServerSideEncryptionAlgorithm "AES256" --defaultServerSideEncryption "SSE-B2" --fileLockEnabled $bucketName "allPrivate" --lifecycleRules $lifecycleRules
    $keyOut = & "$scriptBase\b2-windows.exe" create-key $bucketName "listAllBucketNames,listBuckets,readBuckets,readBucketEncryption,writeBucketEncryption, readBucketRetentions,writeBucketRetentions,listFiles,readFiles,shareFiles,writeFiles, deleteFiles,readFileLegalHolds,writeFileLegalHolds,readFileRetentions,writeFileRetentions,bypassGovernance" --bucket $bucketName
    Write-Host $bucketName " " $keyOut
    $keyId, $keyApp = $keyOut -split '\s+'
    $data = [PSCustomObject]@{
        BucketName = $bucketName
        KeyId = $keyId
        KeyApp = $keyApp
    }

    $data | Export-Csv -Path "$scriptBase\bucket-info.csv" -NoTypeInformation -Append
}

Stop-Transcript
