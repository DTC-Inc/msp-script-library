## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description                             / $env:Description                             - Ticket # or initials for audit trail
## $RMMScriptPath                           / $env:RMMScriptPath                           - Optional log directory base provided by the RMM
## $dellDCUURL                              / $env:dellDCUURL                              - Download URL for Dell Command Update installer
## $dellServerAdministratorURL              / $env:dellServerAdministratorURL              - Download URL for Dell Server Administrator
## $hpeLighoutsOutConfiguration             / $env:hpeLighoutsOutConfiguration             - HPE iLO configuration input
## $hpeSmartStorageAdministrator            / $env:hpeSmartStorageAdministrator            - HPE Smart Storage Administrator input
## $hpeSmartStorageAdministratorCommandLine / $env:hpeSmartStorageAdministratorCommandLine - HPE Smart Storage Administrator command-line input

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description                             = $env:Description,
    [string]$RMMScriptPath                           = $env:RMMScriptPath,
    [string]$dellDCUURL                              = $env:dellDCUURL,
    [string]$dellServerAdministratorURL              = $env:dellServerAdministratorURL,
    [string]$hpeLighoutsOutConfiguration             = $env:hpeLighoutsOutConfiguration,
    [string]$hpeSmartStorageAdministrator            = $env:hpeSmartStorageAdministrator,
    [string]$hpeSmartStorageAdministratorCommandLine = $env:hpeSmartStorageAdministratorCommandLine
)

$ScriptLogName = "windows-oem-config.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied.
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

# Get Manufacturer
$manufacturer = (Get-WmiObject -Class Win32_ComputerSystem).Manufacturer
# Get the OS edition
$osEdition = (Get-WmiObject -Class Win32_OperatingSystem).Caption

Write-Host "Manufacturer: $manufacturer"
write-Host "OS Edition: $osEdition"

# Check if the OS is not a server edition
if ($osEdition -notmatch "Server") {
    Write-Host "OS edition is a workstation OS. Installing OEM workstation apps."
    if ($manufacturer -like "Dell*") {
        $dcuPath = "C:\Program Files\Dell\CommandUpdate\dcu-cli.exe"
        if (Test-Path -Path $dcuPath) {
            Write-Host "Dell Command Update is already installed."
        } else {
            $output = "$env:WINDIR\temp\dell-command-update.exe"
            Invoke-WebRequest -Uri $dellDCUURL -OutFile $output
            Start-Process -FilePath $output -Args "/S" -Wait -NoNewWindow
            Write-Host "Dell Command Update has been installed."
        }
        if (Test-Path -Path $dcuPath) {
            Write-Host "Dell Command Update has been installed."
            exit 0
        } else {
            Write-Host "Dell Command Update failed to install."
            exit 1
        }
    } else {
        Write-Host "This script is only for Dell workstations."
    }
} else {
    Write-Host "OS Edition is a server OS. Installing OEM server apps."
}




Stop-Transcript
