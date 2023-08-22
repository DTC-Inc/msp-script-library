# Install veeam powershell module
if ($Modules = Get-Module -ListAvailable -Name Veeam.Backup.PowerShell) {
    try {
        $Modules | Import-Module -WarningAction SilentlyContinue
        }
        catch {
            throw "Failed to load Veeam Modules"
            }
 }

$backupRepo = Get-VBRBackupRepository | Where -Property Type -like "AmazonS3*"
$backupRepo.DisableImmutability()
