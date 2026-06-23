## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $env:RMM         - "1" when executed from the RMM (string). Anything else = interactive.
## $env:Description - ticket # and/or initials, used as the job description
## $env:RebootCount - reboots BitLocker stays suspended before it auto-resumes (optional, default 1)

$ScriptLogName = "bitlocker-suspend.log"

# Resolve RebootCount from the RMM environment variable; default to 1 if unset/invalid.
# 1 = suspend for exactly the next reboot, then BitLocker re-protects itself.
$RebootCount = 1
$parsedCount = 0
if ($env:RebootCount -and [int]::TryParse($env:RebootCount, [ref]$parsedCount) -and $parsedCount -ge 1) {
    $RebootCount = $parsedCount
}

if ($env:RMM -ne "1") {
    # Interactive run: prompt for a description.
    $ValidInput = 0
    while ($ValidInput -ne 1) {
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"

} else {
    # RMM run: all variables arrive as environment variables.
    if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
        $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$env:WINDIR\logs\$ScriptLogName"
    }

    $Description = $env:Description
    if ([string]::IsNullOrEmpty($Description)) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    }
}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $env:RMM"
Write-Host "RebootCount: $RebootCount"

# Suspend BitLocker on the system volume only. Only the OS/system volume can throw
# the pre-boot recovery prompt; fixed data volumes auto-unlock from the
# (suspended-but-bootable) system drive once Windows is up, so this covers the reboot.
function Suspend-SystemBitLocker {
    param([int]$RebootCount = 1)
    $mp = $env:SystemDrive
    try {
        $vol = Get-BitLockerVolume -MountPoint $mp -ErrorAction Stop
        if ($vol.ProtectionStatus -ne 'On') {
            Write-Output "System volume $mp is not actively protected; nothing to suspend."
            return 0
        }
        Suspend-BitLocker -MountPoint $mp -RebootCount $RebootCount -Verbose | Out-Null

        # Verify protection is actually off before we rely on it.
        $vol = Get-BitLockerVolume -MountPoint $mp
        if ($vol.ProtectionStatus -eq 'On') {
            Write-Error "System volume $mp still protected after suspend."
            return 1
        }
        Write-Output "BitLocker on system volume $mp suspended for $RebootCount reboot(s)."
        return 0
    }
    catch {
        Write-Error "An error occurred: $_"
        return 1
    }
}

$exitCode = Suspend-SystemBitLocker -RebootCount $RebootCount

Stop-Transcript
exit $exitCode
