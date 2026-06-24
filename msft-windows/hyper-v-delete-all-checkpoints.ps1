## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM           - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description   - Ticket # or initials for audit trail
## $env:RMMScriptPath - Optional log directory base provided by the RMM
##
## WARNING: This script DELETES every Hyper-V checkpoint on every VM on the host. It is a
## deliberate maintenance action -- deploy it intentionally.

# Standard DTC three-part structure: 1) RMM variable declaration, 2) input handling, 3) script logic.

$ScriptLogName = "windows-hyper-v-delete-all-checkpoints.log"

# --- Input handling: RMM vs interactive ----------------------------------

# Only prompt when the session is genuinely interactive. NinjaRMM runs scripts
# non-interactively ([Environment]::UserInteractive is $false), so even if the RMM
# preset variable is missing or renamed, we fall through to RMM mode with defaults
# instead of blocking forever on Read-Host (which manifests as a hung RMM job).
if ($env:RMM -ne "1" -and [Environment]::UserInteractive) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
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

# This script needs administrator rights to manage Hyper-V and to write to the system log
# directory. Check before starting the transcript (a non-admin run can't write the log anyway).
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Please run this script with administrator privileges." -ForegroundColor Red
    Exit 1
}

# Ensure log directory exists before starting the transcript
$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    Write-Host "Creating log directory: $logDir"
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
Write-Host "RMM: $env:RMM"

# Detect Hyper-V WITHOUT the ServerManager module / Get-WindowsFeature.
#
# Get-WindowsFeature lives in the ServerManager module, which is Server-only and is NOT
# supported in the 32-bit PowerShell host that RMMs use to run scripts -- calling it there
# throws "Thread failed to start" (System.Threading.ThreadStartException).
#
# The Hyper-V Virtual Machine Management service (vmms) and the Get-VM cmdlet are present
# only when the Hyper-V platform is installed, and both are bitness-safe on client + server.
if (-not (Get-Service -Name "vmms" -ErrorAction SilentlyContinue)) {
    Write-Host "Hyper-V is not installed on this machine (vmms service not found)."
    if ($TranscriptStarted) { Stop-Transcript }
    Exit 0
}

if (-not (Get-Command -Name "Get-VM" -ErrorAction SilentlyContinue)) {
    Write-Host "Hyper-V platform is present but the Hyper-V PowerShell module is not installed; cannot manage checkpoints."
    if ($TranscriptStarted) { Stop-Transcript }
    Exit 0
}

# Delete all Hyper-V checkpoints, one VM at a time.
try {
    $vmList = Get-VM -ErrorAction Stop
} catch {
    Write-Host "ERROR: Failed to enumerate Hyper-V VMs: $_" -ForegroundColor Red
    if ($TranscriptStarted) { Stop-Transcript }
    Exit 2
}

if (-not $vmList) {
    Write-Host "No virtual machines found on this host." -ForegroundColor Yellow
    if ($TranscriptStarted) { Stop-Transcript }
    Exit 0
}

$deletedCount = 0
$failureCount = 0
foreach ($vm in $vmList) {
    # Enumerate this VM's checkpoints. A failure here (e.g. WMI/vmms fault) must not abort the
    # whole run -- record it and move on to the next VM.
    try {
        $checkpointList = Get-VMSnapshot -VMName $vm.Name -ErrorAction Stop
    } catch {
        Write-Host "Error reading checkpoints for VM '$($vm.Name)': $_" -ForegroundColor Red
        $failureCount++
        continue
    }

    if (-not $checkpointList) {
        Write-Host "No checkpoints found for VM '$($vm.Name)'." -ForegroundColor Yellow
        continue
    }

    foreach ($checkpoint in $checkpointList) {
        try {
            Write-Host "Deleting checkpoint '$($checkpoint.Name)' for VM '$($vm.Name)'."
            # Remove only THIS checkpoint. An earlier version piped $vmList into
            # Remove-VMSnapshot, which removed every snapshot on every VM each iteration.
            # -Confirm:$false guarantees no prompt under any $ConfirmPreference (RMM runs non-interactive).
            $checkpoint | Remove-VMSnapshot -Confirm:$false -ErrorAction Stop
            $deletedCount++
        } catch {
            Write-Host "Error deleting checkpoint '$($checkpoint.Name)' for VM '$($vm.Name)': $_" -ForegroundColor Red
            $failureCount++
            # Keep going so one failure does not abort the rest of the cleanup.
            continue
        }
    }
}

Write-Host "Summary: $deletedCount checkpoint(s) deleted, $failureCount failure(s)."
Write-Host "Note: deleting a checkpoint triggers an AVHDX merge that completes asynchronously after this script exits."

if ($failureCount -gt 0) {
    Write-Host "Completed with $failureCount checkpoint deletion failure(s). See log for details." -ForegroundColor Red
    if ($TranscriptStarted) { Stop-Transcript }
    Exit 1
}

Write-Host "All checkpoints processed successfully."
if ($TranscriptStarted) { Stop-Transcript }
Exit 0
