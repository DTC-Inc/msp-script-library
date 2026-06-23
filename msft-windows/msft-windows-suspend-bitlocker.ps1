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

# Function to suspend BitLocker on the system volume for $RebootCount reboot(s).
# Only the OS/system volume can trigger the pre-boot recovery prompt; fixed data
# volumes auto-unlock once Windows is up off the (suspended-but-bootable) system
# drive, so suspending $env:SystemDrive is sufficient to cover the reboot.
function Suspend-SystemBitLocker {
    param([int]$RebootCount = 1)
    try {
        $mp = $env:SystemDrive
        $vol = Get-BitLockerVolume -MountPoint $mp -ErrorAction Stop

        if ($vol.ProtectionStatus -eq 'On') {
            Suspend-BitLocker -MountPoint $mp -RebootCount $RebootCount -Verbose | Out-Null

            # Verify protection is actually off before we rely on it.
            $vol = Get-BitLockerVolume -MountPoint $mp
            if ($vol.ProtectionStatus -eq 'On') {
                Write-Error "System volume $mp still protected after suspend."
                exit 1
            }
            Write-Output "BitLocker on system volume $mp suspended for $RebootCount reboot(s)."
        } else {
            Write-Output "System volume $mp is not actively protected; nothing to suspend."
        }
        Exit 0
    }
    catch {
        Write-Error "An error occurred: $_"
        exit 1
    }
}

# Call the function to suspend BitLocker on the system volume
Suspend-SystemBitLocker -RebootCount $RebootCount



Stop-Transcript
