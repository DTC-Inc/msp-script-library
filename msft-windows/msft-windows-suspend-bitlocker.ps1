param(
    # Number of reboots BitLocker stays suspended for before it auto-resumes.
    # Resolution order: -RebootCount parameter > $env:RebootCount > default 1.
    # 1 = suspend for exactly the next reboot, then BitLocker re-protects itself.
    [int]$RebootCount = 0
)

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "bitlocker-suspend.log"

# Resolve RebootCount: parameter wins; else environment variable; else default 1.
if ($RebootCount -le 0 -and $env:RebootCount) {
    [int]::TryParse($env:RebootCount, [ref]$RebootCount) | Out-Null
}
if ($RebootCount -le 0) { $RebootCount = 1 }

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
    if ($null -ne $RMMScriptPath) {
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
Write-Host "RebootCount: $RebootCount"

# Function to suspend BitLocker on all actively protected volumes for $RebootCount reboot(s).
function Suspend-AllBitLocker {
    param([int]$RebootCount = 1)
    try {
        # Volumes with protection currently ON are the ones that need suspending.
        $bitLockerVolumes = Get-BitLockerVolume | Where-Object { $_.ProtectionStatus -eq 'On' }

        if ($bitLockerVolumes.Count -gt 0) {
            foreach ($volume in $bitLockerVolumes) {
                # Suspend BitLocker for the configured number of reboots.
                Suspend-BitLocker -MountPoint $volume.MountPoint -RebootCount $RebootCount -Verbose

                Write-Output "BitLocker on volume $($volume.MountPoint) suspended for $RebootCount reboot(s)."
            }

            # Verify nothing is still actively protected.
            $stillOn = Get-BitLockerVolume | Where-Object { $_.ProtectionStatus -eq 'On' }
            if ($stillOn) {
                Write-Error "Volume(s) still protected after suspend: $($stillOn.MountPoint -join ', ')"
                exit 1
            }
        } else {
            Write-Output "No actively protected BitLocker volumes found; nothing to suspend."
        }
        Exit 0
    }
    catch {
        Write-Error "An error occurred: $_"
        exit 1
    }
}

# Call the function to suspend BitLocker on all volumes
Suspend-AllBitLocker -RebootCount $RebootCount



Stop-Transcript
