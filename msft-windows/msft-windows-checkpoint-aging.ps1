## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM           - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description   - Ticket # or initials for audit trail
## $env:RMMScriptPath - Optional log directory base provided by the RMM
## $env:DaysAging     - Number of days old a checkpoint must be to flag it (default: "7").
##                      Positive or negative both work (e.g. "7" or "-7" both mean "older than 7 days").

# Standard DTC three-part structure: 1) RMM variable declaration, 2) input handling, 3) script logic.

$ScriptLogName = "windows-hyper-v-checkpoint-aging.log"
$DefaultDaysAging = 7

# --- Default optional RMM environment variables --------------------------
if ([string]::IsNullOrEmpty($env:DaysAging)) {
    $env:DaysAging = "$DefaultDaysAging"
}

# --- Input handling: RMM vs interactive ----------------------------------

if ($env:RMM -ne "1") {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
        $env:Description = Read-Host "Please enter the ticket # and/or your initials for audit trail"
        $env:DaysAging = Read-Host "Please enter the number of days old a Hyper-V checkpoint must be to flag it (e.g. 7)"
        if ($env:Description -and ($null -ne ($env:DaysAging -as [int]))) {
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
    Write-Host "Creating log directory: $logDir"
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# Normalize DaysAging to a positive whole number, then negate so AddDays() walks backwards from now.
# A non-numeric or non-positive value (e.g. "abc", "0", "-0") is meaningless for "older than N days",
# so fall back to the default rather than silently flagging every checkpoint.
$parsedDays = $env:DaysAging -as [int]
if ($null -eq $parsedDays -or [math]::Abs($parsedDays) -lt 1) {
    Write-Host "WARNING: DaysAging value '$env:DaysAging' is not a valid positive number; defaulting to $DefaultDaysAging day(s)."
    $parsedDays = $DefaultDaysAging
}
$daysAging = [math]::Abs($parsedDays)
$daysAgingNegative = -$daysAging

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
Write-Host "Days Aging threshold: $daysAging day(s)"

# Detect Hyper-V WITHOUT the ServerManager module / Get-WindowsFeature.
#
# Get-WindowsFeature lives in the ServerManager module, which is Server-only and is NOT
# supported in the 32-bit PowerShell host that NinjaRMM uses to run scripts -- calling it
# there throws "Thread failed to start" (System.Threading.ThreadStartException).
#
# The Hyper-V Virtual Machine Management service (vmms) and the Get-VM cmdlet are present
# only when the Hyper-V platform is installed, and both are bitness-safe on client + server.
if (-not (Get-Service -Name "vmms" -ErrorAction SilentlyContinue)) {
    Write-Host "Hyper-V is not installed on this machine (vmms service not found)."
    if ($TranscriptStarted) { Stop-Transcript }
    Exit 0
}

if (-not (Get-Command -Name "Get-VM" -ErrorAction SilentlyContinue)) {
    Write-Host "Hyper-V platform is present but the Hyper-V PowerShell module is not installed; cannot enumerate checkpoints."
    if ($TranscriptStarted) { Stop-Transcript }
    Exit 0
}

$cutoff = (Get-Date).AddDays($daysAgingNegative)

# Enumerate checkpoints. If this throws (e.g. insufficient privilege, WMI/vmms fault) we must
# NOT fall through and report "no aging checkpoints" -- that would be a false all-clear that
# masks a broken host. Surface it with a distinct exit code instead.
try {
    $AgingCheckpoints = Get-VM -ErrorAction Stop | Get-VMSnapshot -ErrorAction Stop | Where-Object { $_.CreationTime -lt $cutoff }
} catch {
    Write-Host "ERROR: Failed to enumerate Hyper-V VMs/checkpoints: $_"
    if ($TranscriptStarted) { Stop-Transcript }
    Exit 2
}

if ($AgingCheckpoints) {
    $AgingCheckpoints | ForEach-Object {
        Write-Host "Checkpoint '$($_.Name)' on VM '$($_.VMName)' is older than $daysAging day(s). Created on $($_.CreationTime). Please delete this checkpoint."
    }
    if ($TranscriptStarted) { Stop-Transcript }
    Exit 1
} else {
    Write-Host "There are no checkpoints older than $daysAging day(s) that need to be deleted."
    if ($TranscriptStarted) { Stop-Transcript }
    Exit 0
}
