## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "bitlocker-disable.log"

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

# This script disables BitLocker on all non-OS volumes first and disables the OS volume last.

# Get all BitLocker-protected volumes
$volumes = Get-BitLockerVolume | Where-Object { $_.ProtectionStatus -eq 'On' }

# Separate the OS volume (typically C:) from other volumes
$osVolume = $volumes | Where-Object { $_.MountPoint -eq "C:" }
$nonOsVolumes = $volumes | Where-Object { $_.MountPoint -ne "C:" }

# Disable BitLocker on all non-OS volumes first
foreach ($volume in $nonOsVolumes) {
    Write-Host "Disabling BitLocker on volume:" $volume.MountPoint
    Disable-BitLocker -MountPoint $volume.MountPoint

    # Optionally check status before moving to next volume
    while ((Get-BitLockerVolume -MountPoint $volume.MountPoint).VolumeStatus -ne 'FullyDecrypted') {
        Start-Sleep -Seconds 5
    }
    Write-Host "BitLocker disabled on volume:" $volume.MountPoint
}

# Check if there's an OS volume and disable BitLocker on it last
if ($osVolume) {
    Write-Host "Disabling BitLocker on OS volume:" $osVolume.MountPoint
    Disable-BitLocker -MountPoint $osVolume.MountPoint

    # Optionally check status
    while ((Get-BitLockerVolume -MountPoint $osVolume.MountPoint).VolumeStatus -ne 'FullyDecrypted') {
        Start-Sleep -Seconds 5
    }
    Write-Host "BitLocker disabled on OS volume:" $osVolume.MountPoint
} else {
    Write-Host "No OS volume with BitLocker protection found."
}

Write-Host "All volumes processed."

Stop-Transcript
