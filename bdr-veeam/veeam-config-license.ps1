## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description   / $env:Description   - Ticket # or initials, used as the Description for the job
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM
## $accessKey     / $env:accessKey     - Object storage access key
## $secretKey     / $env:secretKey     - Object storage secret key
## $region        / $env:region        - Object storage region (e.g. us-east-1)
## $bucketName    / $env:bucketName    - Object storage bucket name
## $objectKey     / $env:objectKey     - Object key/path of the license file
## $filePath      / $env:filePath      - Local path to download the license file to

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description   = $env:Description,
    [string]$RMMScriptPath = $env:RMMScriptPath,
    [string]$accessKey     = $env:accessKey,
    [string]$secretKey     = $env:secretKey,
    [string]$region        = $env:region,
    [string]$bucketName    = $env:bucketName,
    [string]$objectKey     = $env:objectKey,
    [string]$filePath      = $env:filePath
)

$ScriptLogName = "veeam-config.license.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied (e.g. an automated RMM run).
if ([string]::IsNullOrEmpty($Description)) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

# Store the logs in the RMMScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"

# Make sure PSModulePath includes Veeam Console
Write-Host "Installing Veeam PowerShell Module if not installed already."
$MyModulePath = "C:\Program Files\Veeam\Backup and Replication\Console\"
$env:PSModulePath = $env:PSModulePath + "$([System.IO.Path]::PathSeparator)$MyModulePath"
if ($Modules = Get-Module -ListAvailable -Name Veeam.Backup.PowerShell) {
    try {
        $Modules | Import-Module -WarningAction SilentlyContinue
        }
        catch {
            throw "Failed to load Veeam Modules"
            }
 }

# Set script URL for s3-functions library script for powershell and execute to load into memory.
$scriptURL = "https://raw.githubusercontent.com/DTC-Inc/msp-script-library/main/s3-api-lib/s3-functions.ps1"

# Invoke the script via http
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString($scriptURL))

# Set varialbes for downloading an object from object storage
# This is set above or in the RMM $accessKey = 'YOUR_ACCESS_KEY'
# This is set above or in the RMM $secretKey = 'YOUR_SECRET_KEY'
# This is set above or in the RMM $region = 'us-east-1' # Change to your bucket's region
# This is set above or in the RMM $bucketName = 'example-bucket'
# This is set above or in the RMM $objectKey = 'licenses/veeam-dtc-rental-license.lic'
# This is set above or in the RMM  filePath = '$env:WINDIR\temp\veeam-dtc-rental-license.lic'

Download-S3Object -AccessKey $accessKey -SecretKey $secretKey -Region $region -BucketName $bucketName -ObjectKey $objectKey -FilePath $filePath

Install-VBRLicense -Path $filePath

Stop-Transcript
