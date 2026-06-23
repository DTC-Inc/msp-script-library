## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $env:RMM         - "1" when executed from the RMM (string). Anything else = interactive.
## $env:Description - ticket # and/or initials, used as the job description
## $env:RebootCount - reboots BitLocker stays suspended before it auto-resumes (optional, default 1)
##
## Exit codes: 0 = system volume protection is OFF (suspended, or no BitLocker) -> safe to reboot.
##             1 = system volume is STILL protected (suspend failed) -> NOT safe to reboot.

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

Write-Host "================ Suspend BitLocker ================"
Write-Host "Description : $Description"
Write-Host "Log path    : $LogPath"
Write-Host "RMM mode    : $env:RMM"
Write-Host "RebootCount : $RebootCount"
Write-Host "==================================================="

# Suspend BitLocker on the system volume only. Only the OS/system volume can throw
# the pre-boot recovery prompt; fixed data volumes auto-unlock from the
# (suspended-but-bootable) system drive once Windows is up, so this covers the reboot.
function Suspend-SystemBitLocker {
    param([int]$RebootCount = 1)
    $mp = $env:SystemDrive

    Write-Host "[1/3] Checking BitLocker on system volume $mp ..."
    try {
        $vol = Get-BitLockerVolume -MountPoint $mp -ErrorAction Stop
    } catch {
        Write-Host "ERROR: could not query BitLocker on ${mp}: $($_.Exception.Message)"
        Write-Host "RESULT: unable to determine BitLocker state on $mp -> EXIT 1"
        return 1
    }
    Write-Host "      VolumeStatus     : $($vol.VolumeStatus)"
    Write-Host "      ProtectionStatus : $($vol.ProtectionStatus)"

    if ($vol.ProtectionStatus -ne 'On') {
        Write-Host "[2/3] Protection already OFF on $mp - nothing to suspend."
        Write-Host "RESULT: $mp is NOT protected -> safe to reboot -> EXIT 0"
        return 0
    }

    Write-Host "[2/3] Suspending BitLocker on $mp for $RebootCount reboot(s) ..."
    try {
        Suspend-BitLocker -MountPoint $mp -RebootCount $RebootCount -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "ERROR: Suspend-BitLocker failed on ${mp}: $($_.Exception.Message)"
        Write-Host "RESULT: suspend FAILED on $mp -> still protected -> EXIT 1"
        return 1
    }

    Write-Host "[3/3] Verifying protection is now off ..."
    $vol = Get-BitLockerVolume -MountPoint $mp
    Write-Host "      ProtectionStatus after suspend : $($vol.ProtectionStatus)"
    if ($vol.ProtectionStatus -eq 'On') {
        Write-Host "RESULT: $mp STILL PROTECTED after suspend -> NOT safe to reboot -> EXIT 1"
        return 1
    }

    Write-Host "RESULT: BitLocker on $mp SUSPENDED for $RebootCount reboot(s) -> safe to reboot -> EXIT 0"
    return 0
}

$exitCode = Suspend-SystemBitLocker -RebootCount $RebootCount

Write-Host "Final exit code: $exitCode"
Stop-Transcript
exit $exitCode
