## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description           / $env:Description           - Ticket # or initials for audit trail
## $ExcludeCurrentProcess / $env:ExcludeCurrentProcess - Set to 1 to exclude the current PowerShell process (default: 1)
## $KillPwshCore          / $env:KillPwshCore          - Set to 1 to also kill pwsh.exe (PowerShell 7+) (default: 0)
## $RMMScriptPath         / $env:RMMScriptPath         - Optional log directory base provided by the RMM

# Kill PowerShell Processes Script
# Use this to terminate runaway or stuck RMM scripts
#
# Exit Codes:
# 0 = Success (processes killed or none found)
# 1 = Failed to kill one or more processes

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description           = $env:Description,
    [string]$ExcludeCurrentProcess = $env:ExcludeCurrentProcess,
    [string]$KillPwshCore          = $env:KillPwshCore,
    [string]$RMMScriptPath         = $env:RMMScriptPath
)

$ScriptLogName = "Kill-PowerShell.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied.
if ([string]::IsNullOrEmpty($Description)) {
    $Description = "RMM Emergency Kill"
}

# Default the optional behavior flags when not supplied.
if ([string]::IsNullOrEmpty($ExcludeCurrentProcess)) {
    $ExcludeCurrentProcess = 1
}
if ([string]::IsNullOrEmpty($KillPwshCore)) {
    $KillPwshCore = 0
}

# Store the logs in the RMMScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

# Ensure log directory exists
$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

Start-Transcript -Path $LogPath

Write-Host "============================================"
Write-Host "Emergency PowerShell Process Termination"
Write-Host "============================================"
Write-Host ""
Write-Host "Description: $Description"
Write-Host "Exclude Current Process: $ExcludeCurrentProcess"
Write-Host "Kill PowerShell Core (pwsh): $KillPwshCore"
Write-Host "Execution Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

$currentPID = $PID
$exitCode = 0
$processesKilled = 0
$processesFailed = 0

# Build list of process names to kill
$processNames = @("powershell")
if ($KillPwshCore -eq 1) {
    $processNames += "pwsh"
}

foreach ($procName in $processNames) {
    Write-Host "[ACTION] Finding $procName.exe processes..."

    $processes = Get-Process -Name $procName -ErrorAction SilentlyContinue

    if ($null -eq $processes -or $processes.Count -eq 0) {
        Write-Host "  No $procName.exe processes found"
        continue
    }

    Write-Host "  Found $($processes.Count) $procName.exe process(es)"

    foreach ($proc in $processes) {
        # Skip current process if configured
        if ($ExcludeCurrentProcess -eq 1 -and $proc.Id -eq $currentPID) {
            Write-Host "  [SKIP] PID $($proc.Id) - current process (this script)"
            continue
        }

        try {
            $procInfo = "PID: $($proc.Id), Started: $($proc.StartTime), CommandLine: "

            # Try to get command line for logging
            try {
                $wmiProc = Get-CimInstance Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction SilentlyContinue
                if ($wmiProc) {
                    $procInfo += $wmiProc.CommandLine
                } else {
                    $procInfo += "(unavailable)"
                }
            } catch {
                $procInfo += "(unavailable)"
            }

            Write-Host "  [KILL] $procInfo"

            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            $processesKilled++
            Write-Host "    [SUCCESS] Process terminated"

        } catch {
            $processesFailed++
            Write-Host "    [FAILED] Could not kill process: $_"
            $exitCode = 1
        }
    }
}

Write-Host ""
Write-Host "============================================"
Write-Host "SUMMARY"
Write-Host "============================================"
Write-Host ""
Write-Host "Processes killed: $processesKilled"
Write-Host "Processes failed: $processesFailed"
Write-Host ""

if ($processesKilled -eq 0 -and $processesFailed -eq 0) {
    Write-Host "RESULT: No PowerShell processes to kill (besides this script)"
} elseif ($processesFailed -eq 0) {
    Write-Host "RESULT: SUCCESS - All target processes terminated"
} else {
    Write-Host "RESULT: PARTIAL - Some processes could not be terminated"
}

Stop-Transcript
exit $exitCode
