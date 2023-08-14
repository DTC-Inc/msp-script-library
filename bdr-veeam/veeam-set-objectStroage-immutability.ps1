# Install veeam powershell module
if ($Modules = Get-Module -ListAvailable -Name Veeam.Backup.PowerShell) {
    try {
        $Modules | Import-Module -WarningAction SilentlyContinue
        }
        catch {
            throw "Failed to load Veeam Modules"
            }
 }

# Set Immutablity Period
$immutabilityPeriod = 7

# Set ObjectStorageImmutabilityGenerationDays. Remember actual immutability time is $objectStorageImmutabilityGenerationDays + $immutabilityPeriod
$objectStorageImmutabilityGenerationDays = 30

Get-VBRObjectStorageRepository | Set-VBRAmazonS3CompatibleRepository -ImmutabilityPeriod $immutabilityPeriod -EnableBackupImmutability

try {
    $registryValue = Get-ItemProperty -Path "HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication" -Name "ObjectStorageImmutabilityGenerationDays"
    
} catch {
    Write-Host "Registry item doesn't exist. We'll create one."
} 


if ($registryValue) {
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication" -Name "ObjectStorageImmutabilityGenerationDays" -Value $objectStorageImmutabilityGenerationDays
} else {
    New-ItemProperty -Path "HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication\" -Name "ObjectStorageImmutabilityGenerationDays" -PropertyType DWord -Value $objectStorageImmutabilityGenerationDays

}

