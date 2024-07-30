## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# $IdleTime is the amount of time in hours for an endpoint to be idle for a reboot to occur.

# This script should be scheduled or run on-demand to prevent a mistake reboot.

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-idle-time-reboot.log"

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

$now = Get-Date
if ($now.DayOfWeek -eq 'Friday' -and $now.Hour -ge 3 -and $now.Hour -lt 5) {
    Write-Host "It's between 3 AM and 5 AM on Friday. Rebooting the computer..."
    $randomSleep = Get-Random -Minimum 60 -Maximum 120
    Write-Host "Sleeping for $($randomSleep/60) minutes before rebooting..."
    Start-Sleep -Seconds $randomSleep  # Sleep for a random duration between 1 and 90 minutes    
    Restart-Computer -Force
    Start-Sleep -Seconds 3600  # Wait for an hour to avoid multiple reboots within the same time window

} else {
    Write-Host "It is not between 3 AM and 5 AM on a Friday."
}

Stop-Transcript
