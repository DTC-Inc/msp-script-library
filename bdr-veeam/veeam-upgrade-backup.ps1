# Please note this only currently works with Hyper-V. VMWare support can be added.

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

# Enable all backup jobs

Get-VBRJob | Where -Property TypeToString -eq "Hyper-V Backup" | Enable-VBRJob