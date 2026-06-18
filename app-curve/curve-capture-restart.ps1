## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM           - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description   - Ticket # or initials for audit trail
##
## No additional variables required.

# curve-capture-restart.ps1
#
# Stops CurveCapture.exe if it is running, waits for it to fully exit, then
# relaunches it. CurveCapture is Curve Dental's imaging-capture bridge app and
# installs per-user under:
#     %APPDATA%\CurveDental\CurveCapture\bin\CurveCapture.exe
#
# IMPORTANT: This is a USER-CONTEXT script. Deploy it in NinjaRMM with
# "Run As: Logged-on User" (NOT System). Two reasons:
#   1. %APPDATA% is per-user. Under SYSTEM it resolves to the SYSTEM profile
#      and the CurveCapture path will not exist.
#   2. CurveCapture is an interactive GUI app. Launched from SYSTEM it would
#      start in session 0 and be invisible to the user. User context puts the
#      relaunched window back in front of the person using the workstation.
#
# Follows the three-section template: RMM variable declaration, input
# handling, script logic wrapped in Start-Transcript / Stop-Transcript.

$ScriptLogName = "curve-capture-restart.log"
$procName      = "CurveCapture"

# --- Input handling: RMM vs interactive ----------------------------------

if ($env:RMM -ne "1") {
    $ValidInput = 0
    while ($ValidInput -ne 1) {
        $env:Description = Read-Host "Please enter the ticket # and/or your initials for audit trail"
        if ($env:Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
} else {
    if ([string]::IsNullOrEmpty($env:Description)) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $env:Description = "No Description"
    }
}

# User-context script: log under %LOCALAPPDATA% — $env:WINDIR\logs requires
# admin rights a user-context script will not have.
$LogPath = "$env:LOCALAPPDATA\dtc-logs\$ScriptLogName"

$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    Write-Host "Creating log directory: $logDir"
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# --- Script logic --------------------------------------------------------

Start-Transcript -Path $LogPath

Write-Host "Description: $env:Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $env:RMM"

try {
    $exePath = Join-Path $env:APPDATA "CurveDental\CurveCapture\bin\CurveCapture.exe"

    if (-not (Test-Path $exePath)) {
        Write-Host "ERROR: CurveCapture.exe not found at expected path: $exePath"
        Write-Host "Confirm this script is running in the logged-on user's context (not SYSTEM) and that CurveCapture is installed for this user."
        Stop-Transcript
        exit 1
    }
    Write-Host "Found CurveCapture: $exePath"

    # --- Stop the process ---
    $running = Get-Process -Name $procName -ErrorAction SilentlyContinue
    if ($running) {
        Write-Host "Stopping $procName (PID $($running.Id -join ', '))..."
        $running | Stop-Process -Force

        # Wait for it to actually exit (up to 15 seconds)
        $timeout = (Get-Date).AddSeconds(15)
        while ((Get-Process -Name $procName -ErrorAction SilentlyContinue) -and ((Get-Date) -lt $timeout)) {
            Start-Sleep -Milliseconds 500
        }

        if (Get-Process -Name $procName -ErrorAction SilentlyContinue) {
            Write-Host "ERROR: $procName did not exit within 15 seconds. Aborting restart."
            Stop-Transcript
            exit 1
        }
        Write-Host "$procName stopped."
    } else {
        Write-Host "$procName was not running."
    }

    # --- Restart ---
    Write-Host "Starting $procName..."
    Start-Process -FilePath $exePath -WorkingDirectory (Split-Path $exePath)
    Write-Host "$procName started. Done."

} catch {
    Write-Host "ERROR: Unexpected failure restarting $procName - $_"
    Stop-Transcript
    exit 1
}

Stop-Transcript
