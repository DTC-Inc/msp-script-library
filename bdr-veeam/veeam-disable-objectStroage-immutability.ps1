# This script disables all Amazon S3 and Amazon S3 compabitible object storage immutability.

# Getting input from user if not running from RMM else set variables from RMM.

Write-Host $description
Write-Host $rmmScriptPath
Write-Host $rmm

$scriptLogName = "veeam-disable-objectStorage-immutability.log"

if ($rmm -ne 1) {
    $validInput = 0
    # Only run if we receive valid input
    while ($validInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make validInput = 1 whenever correct input is given.
        $description = Read-Host "Please enter the ticket # and, or your initials. Its used as the description for the job"
        $validInput = 1
    }
    $logPath = "$env:WINDIR\logs\$scriptLogName"


} else { 
    # Store the logs in the rmmScriptPath
    $logPath = "$rmmScriptPath\logs\$scriptLogName"

    if ($description -eq $null) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $description = "No description"
    }   
}

Start-Transcript -Path $logPath

# Install veeam powershell module
if ($Modules = Get-Module -ListAvailable -Name Veeam.Backup.PowerShell) {
    try {
        $Modules | Import-Module -WarningAction SilentlyContinue
        }
        catch {
            throw "Failed to load Veeam Modules"
            }
 }

$backupRepo = $backupRepo = Get-VBRBackupRepository |Where -Property Type -like "AmazonS3*"
$backupRepo.DisableImmutability()

Stop-Transcript