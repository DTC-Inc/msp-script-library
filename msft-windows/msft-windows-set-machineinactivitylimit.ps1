## Script variables that need set in RMM
# $machineInacvitiyLimit (miliseconds)

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-set-machineinacvitylimit.log"

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

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host "Machine Inactivity Limit (miliseconds): $machineInactivityLimit"

# Define the path and the name of the registry key
$registryPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
$keyName = "MachineInactivityLimit"

# Define the value to set (15 minutes in milliseconds)
# $value = 900000

# Check if the registry path exists, create if it doesn't
if (-Not (Test-Path $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
}

# Set the registry key value
Set-ItemProperty -Path $registryPath -Name $keyName -Value $value -Type DWord

# Output to confirm the operation
Write-Host "The MachineInactivityLimit has been set to 15 minutes."

Stop-Transcript
