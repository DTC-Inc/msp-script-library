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

        $IdleTime = Read-Host "Please enter the idle time for how long the endpoint need to be idle before reboot in hours"
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
Write-Host "Idle Time: $IdleTime"

# Function to get idle time in seconds
function Get-IdleTime {
    $lastInputInfo = New-Object "Win32.LastInputInfo"
    $lastInputInfo.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($lastInputInfo)
    [System.Runtime.InteropServices.Marshal]::PtrToStructure([System.Runtime.InteropServices.Marshal]::AllocHGlobal([System.Runtime.InteropServices.Marshal]::SizeOf($lastInputInfo)), [type]::GetType('Win32.LastInputInfo'))
    [System.Runtime.InteropServices.Marshal]::StructToPtr($lastInputInfo, [System.Runtime.InteropServices.Marshal]::AllocHGlobal([System.Runtime.InteropServices.Marshal]::SizeOf($lastInputInfo)), $false)
    $lastInputInfo.dwTime = [Environment]::TickCount - [System.Environment]::TickCount
    return ([Environment]::TickCount - $lastInputInfo.dwTime) / 1000
}

# Function to check idle time and reboot if necessary
function Check-IdleTimeAndReboot {
    $idleTimeInSeconds = Get-IdleTime
    $idleTimeInHours = $idleTimeInSeconds / 3600

    if ($idleTimeInHours -ge $IdleTime) {
        Restart-Computer -Force
    } else {
        Write-Output "Idle time is less than 1 hour. No reboot required."
    }
}

Stop-Transcript
