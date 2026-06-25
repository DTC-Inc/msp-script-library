## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $userApiKey    / $env:userApiKey    - REQUIRED. Backblaze B2 API Key ID
## $userApiSecret / $env:userApiSecret - REQUIRED. Backblaze B2 API App Key

# Please make sure that b2-windows.exe is in the script root. All logs and data exported is stored here.

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-userApiKey ...) or from an RMM that supplies values as env variables.
    [string]$userApiKey    = $env:userApiKey,
    [string]$userApiSecret = $env:userApiSecret
)

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Validate required inputs. These must come from -Parameter or $env: -- there is no prompt.
$missing = @()
if (-not $userApiKey)    { $missing += 'userApiKey' }
if (-not $userApiSecret) { $missing += 'userApiSecret' }
if ($missing.Count -gt 0) {
    Write-Error "ERROR: Required input(s) not provided (set as -Parameter or `$env:): $($missing -join ', ')"
    exit 1
}

# global variables
$lifecycleRules = @'
[{
     "daysFromHidingToDeleting": 1,
     "daysFromUploadingToHiding": null,
     "fileNamePrefix": ""
}]
'@

Start-Transcript $psScriptRoot\backblaze-create-buckets.log

$filePath = Join-Path -Path $psScriptRoot -ChildPath "b2-windows.exe"

if (-not (Test-Path -Path $filePath)) {
    $url = "https://github.com/DTC-Inc/msp-script-library/blob/main/iaas-backblaze/b2-windows.exe"  # Replace with the actual download URL
     
    Write-Host "Downloading file..."
    $webClient = New-Object System.Net.WebClient
    $webClient.DownloadFile($url, $filePath)
    Write-Host "File downloaded successfully."

} else {
    Write-Host "File already exists."
}

# Authorize B2
& $psScriptRoot\b2-windows.exe authorize-account $userApiKey $userApiSecret

# Run the executable and capture its output
$executableOutput = & $psScriptRoot\b2-windows.exe list-buckets

# Create an array to store objects
$myObjects = @()

# Process each line and create an object
foreach ($line in $executableOutput) {
        # Split each line into properties (adjust the delimiter based on your output format)
        $properties = $line -split "  "

        # Create an object with custom properties
        $myObject = New-Object PSObject -Property @{
        BucketPermission = $properties[0]
        BucketId = $properties[1]
        BucketName = $properties[2]
    }

    # Add the object to the array
    $myObjects += $myObject
}

foreach ($bucket in $myObjects) {
    $bucketName = $bucket.BucketName
    Write-Host "Updating $bucketName with the latest lifecycle ruels."
    & $psScriptRoot\b2-windows.exe update-bucket --lifecycleRules $lifecycleRules $bucketName

}

Stop-Transcript