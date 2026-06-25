## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description   / $env:Description   - Ticket # or initials for audit trail
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description   = $env:Description,
    [string]$RMMScriptPath = $env:RMMScriptPath
)

$ScriptLogName = "resume-bitlocker.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Mirror the resolved parameter values into $env: so the rest of the script can reference
# either $Description or $env:Description, whichever form the input arrived in.
if (-not [string]::IsNullOrEmpty($Description))   { $env:Description   = $Description }
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) { $env:RMMScriptPath = $RMMScriptPath }

if ([string]::IsNullOrEmpty($env:Description)) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $env:Description = "No Description"
}

# Store the logs in the RMMScriptPath
if ($null -eq $env:RMMScriptPath) {
    $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"

} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

}

Start-Transcript -Path $LogPath

Write-Host "Description: $env:Description"
Write-Host "Log path: $LogPath"

# Function to resume BitLocker encryption on all volumes
function Resume-AllBitLocker {
    try {
        # Get all BitLocker volumes where BitLocker is suspended
        $suspendedBitLockerVolumes = Get-BitLockerVolume | Where-Object { $_.ProtectionStatus -eq 'Off' }

        if ($suspendedBitLockerVolumes.Count -gt 0) {
            foreach ($volume in $suspendedBitLockerVolumes) {
                # Resume BitLocker encryption
                Resume-BitLocker -MountPoint $volume.MountPoint -Verbose

                Write-Output "BitLocker encryption on volume $($volume.MountPoint) has been resumed."
            }
        } else {
            Write-Output "No BitLocker encrypted volumes with suspended encryption found."
        }
        Exit 0
    }
    catch {
        Write-Error "An error occurred: $_"
        exit 1
    }
}

# Call the function to resume BitLocker on all volumes
Resume-AllBitLocker



Stop-Transcript
