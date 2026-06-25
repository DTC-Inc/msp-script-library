## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description   / $env:Description   - Ticket # or initials for audit trail
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM

# Suspends BitLocker on all fully-encrypted volumes. RebootCount 0 = stays suspended
# until explicitly resumed (use msft-windows-resume-bitlocker.ps1).

# Standard DTC three-part structure: 1) variable declaration, 2) input handling, 3) script logic.

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description   = $env:Description,
    [string]$RMMScriptPath = $env:RMMScriptPath
)

$ScriptLogName = "bitlocker-suspend.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Mirror the resolved parameter values into $env: so the rest of the script can reference
# either $Description or $env:Description, whichever form the input arrived in.
if (-not [string]::IsNullOrEmpty($Description))   { $env:Description   = $Description }
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) { $env:RMMScriptPath = $RMMScriptPath }

if ([string]::IsNullOrEmpty($env:Description)) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $env:Description = "No Description"
}

# Store logs under $env:RMMScriptPath if provided, otherwise the standard Windows logs directory.
if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
    $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"
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
