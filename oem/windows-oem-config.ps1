## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $dellDCUURL
## $dellServerAdministratorURL
## $hpeLighoutsOutConfiguration
## $hpeSmartStorageAdministrator
## $hpeSmartStorageAdministratorCommandLine

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "windows-oem-config.log"

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
            Invoke-WebRequest -Uri $$dellDCUURL -OutFile $output
            Start-Process -FilePath $output -Args "/S" -Wait -NoNewWindow
            Write-Host "Dell Command Update has been installed."
        }
    } else {
        Write-Host "This script is only for Dell workstations."
    }
} else {
    Write-Host "OS Edition is a server OS. Installing OEM server apps."
}




Stop-Transcript
