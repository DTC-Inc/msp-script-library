## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:Description   - Ticket # or initials for audit trail
## $env:RMMScriptPath - Optional log directory base provided by the RMM

# Suspends BitLocker on all fully-encrypted volumes. RebootCount 0 = stays suspended
# until explicitly resumed (use msft-windows-resume-bitlocker.ps1).

# Standard DTC three-part structure: 1) RMM variable declaration, 2) input handling, 3) script logic.

$ScriptLogName = "bitlocker-suspend.log"

# --- Input handling: interactive vs unattended ---------------------------

# Prompt only in an interactive session. NinjaRMM (and any unattended/scheduled run)
# is non-interactive, so it skips the prompts and uses defaults -- it never blocks or
# errors on Read-Host.
if ([Environment]::UserInteractive) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        $env:Description = Read-Host "Please enter the ticket # and/or your initials for audit trail"
        if ($env:Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"
} else {
    # RMM mode: store logs under $env:RMMScriptPath if the RMM provided one,
    # otherwise fall back to the standard Windows logs directory.
    if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
        $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$env:WINDIR\logs\$ScriptLogName"
    }

    if ([string]::IsNullOrEmpty($env:Description)) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $env:Description = "No Description"
    }
}

# Ensure log directory exists before starting the transcript
$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# --- Script logic --------------------------------------------------------

# Start-Transcript fails in some hosts (e.g. the NinjaRMM scripting host throws
# "Transcription cannot be started"). Guard it so the script still runs and its
# Write-Host output still reaches the RMM console; only the transcript file is lost.
$TranscriptStarted = $false
try {
    Start-Transcript -Path $LogPath -ErrorAction Stop
    $TranscriptStarted = $true
} catch {
    Write-Host "Warning: Could not start transcript logging to $LogPath - $($_.Exception.Message)"
}

Write-Host "Description: $env:Description"
Write-Host "Log path: $LogPath"

# BitLocker cmdlets require the BitLocker feature/module. If absent, no-op cleanly.
if (-not (Get-Command -Name "Get-BitLockerVolume" -ErrorAction SilentlyContinue)) {
    Write-Host "BitLocker cmdlets are not available on this machine; nothing to suspend."
    if ($TranscriptStarted) { Stop-Transcript }
    Exit 0
}

$exitCode = 0
try {
    $bitLockerVolumes = Get-BitLockerVolume -ErrorAction Stop | Where-Object { $_.VolumeStatus -eq 'FullyEncrypted' }

    if ($bitLockerVolumes) {
        foreach ($volume in $bitLockerVolumes) {
            Suspend-BitLocker -MountPoint $volume.MountPoint -RebootCount 0 -ErrorAction Stop | Out-Null
            Write-Host "BitLocker encryption on volume $($volume.MountPoint) has been suspended."
        }
    } else {
        Write-Host "No fully-encrypted BitLocker volumes found."
    }
} catch {
    Write-Host "ERROR: Failed to suspend BitLocker: $_"
    $exitCode = 1
}

if ($TranscriptStarted) { Stop-Transcript }
Exit $exitCode
