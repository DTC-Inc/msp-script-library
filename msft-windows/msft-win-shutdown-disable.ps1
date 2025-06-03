## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-win-shutdown-disable.log"

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

        $DisableShutdownUi = Read-Host "Enter Y to enable shutdown, enter N to disable shutdown"
        if ($DisableShutdownUi -eq "Y") {
            $DisableShutdownUi = $True
            $ValidInput = 1
        } elseif ($DisableShutdownUi -eq "N") {
            $DisableShutdownUi = $False
            $ValidInput = 1
        } else { 
            Write-Host "Input invalid, please only enter Y or N."
            $ValidInput = 0
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
Write Host "Disable Shutdown: $DisableShutdownUi"

# Set this variable:
#   $true  => Disable the shutdown option from the Windows UI
#   $false => Enable (restore) the shutdown option in the Windows UI
# $DisableShutdownUI = $true  # Change to $false to re-enable the shutdown option

# Define the registry path for Explorer policies
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"

if ($DisableShutdownUI) {
    # Disable Shutdown UI:
    # Create the registry key if it doesn't exist
    if (-not (Test-Path $regPath)) {
        New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies" -Name "Explorer" -Force | Out-Null
    }
    # Set the NoClose value to disable the shutdown/restart options in the UI
    Set-ItemProperty -Path $regPath -Name "NoClose" -Value 1 -Type DWord
    Write-Host "Shutdown option from the Windows UI has been disabled."
}
else {
    # Enable Shutdown UI:
    if (Test-Path $regPath) {
        # If the "NoClose" property exists, remove it
        if (Get-ItemProperty -Path $regPath -Name "NoClose" -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $regPath -Name "NoClose" -ErrorAction SilentlyContinue
            Write-Host "Shutdown option from the Windows UI has been enabled."
        }
        else {
            Write-Host "No shutdown disabling registry entry found. Shutdown option is already enabled."
        }
    }
    else {
        Write-Host "Registry key not found. Shutdown option should be enabled by default."
    }
}

Write-Host "Note: You may need to log off or restart Explorer for the changes to take effect."

Stop-Transcript

