## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# No variables are required for this script besides $Description.

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
Write-Host "Workstation Reboot Day: $WorkstationRebootDay"
Write-Host "Server Reboot Day: $ServerRebootDay"
Write-Host "Hypervisor Reboot Day: $HypervisorRebootDay"
Write-Host "Reboot Hour Start: $RebootHourStart"
Write-Host "Reboot Hour End: $RebootHourEnd"
Write-Host "Reboot Stagger Max: $RebootStaggerMax"

# Get OS information
$OsInfo = Get-WmiObject -Class Win32_OperatingSystem
$ServerRole = (Get-WindowsFeature -Name Hyper-V).Installed

# Check the OS type
if ($OsInfo.Caption -match "Windows Server") {
    if ($ServerRole) {
        Write-Output "This endpoint is a Hyper-V host (Windows Server with Hyper-V role)."
        $RebootDay = $HypervisorRebootDay
    } else {
        Write-Output "This endpoint is a regular Windows Server."
        $RebootDay = $ServerRebootDay
    }
} elseif ($OsInfo.Caption -match "Windows 10|Windows 11") {
    Write-Output "This endpoint is a workstation."
    $RebootDay = $WorkstationRebootDay
} else {
    Write-Output "This endpoint type is unknown or unsupported."
    Exit 0
}


if ($RebootDay -eq $null) {
    $RebootDay = "Friday"
    Write-Host "Reboot Day is null so we are setting the default to $RebootDay."
}

if ($RebootHourStart -eq $null) {
    $RebootHourStart = 3
    Write-Host "Reboot Hour Start is null so we are setting the default to $RebootHourStart."
}

if ($RebootHourEnd -eq $null) {
    $RebootHourEnd = 5
    Write-Host "Reboot Hour End is null so we are setting the default to $RebootHourEnd."
}

if ($RebootStaggerMax -eq $null) {
    $RebootStaggerMax = 5400
    Write-Host "Reboot Stagger Max is null sow we are setting the default to $RebootStaggerMax."
}

$now = Get-Date
if ($now.DayOfWeek -eq '$RebootDay' -and $now.Hour -ge $RebootHourStart -and $now.Hour -lt $RebootHourEnd) {
    Write-Host "It's between $RebootHourStart and $RebootHourEnd on $RebootDay. Rebooting the computer..."
    $RandomSleep = Get-Random -Minimum 60 -Maximum $RebootStaggerMax
    Write-Host "Sleeping for $($randomSleep/60) minutes before rebooting..."
    # Start-Sleep -Seconds $randomSleep  # Sleep for a random duration between 1 and 90 minutes **LEGACY LOGIC** 
    $ShutdownPath = $ENV:WINDIR + "\System32\shutdown.exe"  
    & $ShutdownPath -r -t $RandomSleep -f -c "Your MSP is rebooting this endpoint for pending maintenance in $($RandomSleep/60) minutes. Reboot time range script."

} else {
    Write-Host "It is not between $RebootHourStart and $RebootHourEnd on a $RebootDay. Not rebooting."
}

Stop-Transcript
