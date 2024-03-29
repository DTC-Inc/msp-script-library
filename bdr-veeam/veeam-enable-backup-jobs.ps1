# Install veeam powershell module
if ($Modules = Get-Module -ListAvailable -Name Veeam.Backup.PowerShell) {
    try {
        $Modules | Import-Module -WarningAction SilentlyContinue
        }
        catch {
            throw "Failed to load Veeam Modules"
            }
 }

Get-VBRJob | Enable-VBRJob