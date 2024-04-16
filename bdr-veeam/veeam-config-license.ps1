## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $accesskey, $secretKey, $region, $bucketName, $objectKey, $filePath all need set in the RMM before running this script.

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "veeam-config.license.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

} else { 
    # Store the logs in the RMMScriptPath
    if ($null -eq $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
        
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
        
    }

    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    }   


    
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"

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
