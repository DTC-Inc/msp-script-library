# Install veeam powershell module
if ($Modules = Get-Module -ListAvailable -Name Veeam.Backup.PowerShell) {
    try {
        $Modules | Import-Module -WarningAction SilentlyContinue
        }
        catch {
            throw "Failed to load Veeam Modules"
            }
 }

# Upgrade VBR Backup Chain to True Per VM
Get-VBRBackup |Where -Property TypeToString -eq "Hyper-V Backup" | Upgrade-VBRBackup

