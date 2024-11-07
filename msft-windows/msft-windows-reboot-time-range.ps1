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
Write-Host "Workstation Reboot Day: $WorkstationRebootDayGUID"
Write-Host "Server Reboot Day: $ServerRebootDayGUID"
Write-Host "Hypervisor Reboot Day: $HypervisorRebootDayGUID"
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
        $RebootDayGUID = $HypervisorRebootDayGUID
    } else {
        Write-Output "This endpoint is a regular Windows Server."
        $RebootDayGUID = $ServerRebootDayGUID
    }
} elseif ($OsInfo.Caption -match "Windows 10|Windows 11") {
    Write-Output "This endpoint is a workstation."
    $RebootDayGUID = $WorkstationRebootDayGUID
} else {
    Write-Output "This endpoint type is unknown or unsupported."
    Exit 0
}

# Define a hashtable mapping GUIDs to days of the week for reboot day
$RebootDayMap = @{
# workstation reboot days
    "a4118048-a417-486f-a3e3-c281c0507e40" = "Monday"
    "54e460ae-fa38-4b17-b7a9-80b7ad7dc2e1" = "Tuesday"
    "32e6f55e-4b1c-4dac-a941-4e3eab76cde1" = "Wednesday"
    "563537f3-f201-4547-b323-2d8614d7d628" = "Thursday"
    "6a7a15ae-ffb8-4cab-b7a8-96ecc6ea71da" = "Friday"
    "f07a7542-3b1e-4f80-85a0-d81cb90cc493" = "Saturday"
    "18181b96-58e5-4026-a164-98a57ae265b2" = "Sunday"
# server reboot days
    "4268f283-ea0b-478a-9d00-de207023dd32" = "Monday"
    "434ae7cc-ff3b-427f-8527-01928ba373d7" = "Tuesday"
    "d684bae7-dcb4-4896-865c-1a7d12248779" = "Wednesday"
    "bcdd77ef-927e-490f-910d-79d6b40dcea5" = "Thursday"
    "afcd4c7c-3169-426f-9980-d0cdb815b86d" = "Friday"
    "57dc1d7a-7b29-4a90-aae5-ec089cb6e26d" = "Saturday"
    "32ca16da-3f4e-4d0f-932f-b0ed074557e3" = "Sunday"
# hypervisor reboot days
    "5c7326bd-3f94-4cd9-9825-d2a98dc3bf1c" = "Monday"
    "cf0f0b33-7ab9-42f5-8732-b3f93148b168" = "Tuesday"
    "80426bb8-4c74-4b39-99df-79dc054806cc" = "Wednesday"
    "6288333f-fdb7-4b49-a0a3-4ffc862fdbb7" = "Thursday"
    "e0bf1d08-c9b8-44ae-be6c-37df6a02b982" = "Friday"
    "0b3463ca-5bb0-405d-9c29-0c2089874ff6" = "Saturday"
    "f1ca5ece-97dd-4196-8540-110f733b2e1b" = "Sunday"
}

if ($RebootDayMap.ContainsKey($rebootDayGUID)) {
    $RebootDay = $RebootDayMap[$rebootDayGUID]
} else {
    $RebootDay = "GUID not found in mapping."
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
