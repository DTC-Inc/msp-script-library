## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description   / $env:Description   - Ticket # or initials for audit trail
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM
## $LookbackDays  / $env:LookbackDays  - How many days back to look for bluescreens (default: 1)

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description   = $env:Description,
    [string]$RMMScriptPath = $env:RMMScriptPath,
    [string]$LookbackDays  = $env:LookbackDays
)

$ScriptLogName = "msft-windows-bsod-alert.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Preserve the standard default for the audit-trail description.
if ([string]::IsNullOrEmpty($Description)) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

# Default and validate the lookback window. Env vars arrive as strings, so coerce to int.
if ([string]::IsNullOrEmpty($LookbackDays)) {
    $LookbackDays = "1"
}
$LookbackDaysInt = 0
if (-not [int]::TryParse($LookbackDays, [ref]$LookbackDaysInt) -or $LookbackDaysInt -lt 1) {
    Write-Host "LookbackDays '$LookbackDays' is not a valid positive integer; defaulting to 1."
    $LookbackDaysInt = 1
}

# Store the logs in the RMMScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "Lookback window: last $LookbackDaysInt day(s)"

$startTime = (Get-Date).AddDays(-$LookbackDaysInt)
$bsodFound = $false

# Authoritative blue-screen signal: "The computer has rebooted from a bugcheck." This event
# (provider Microsoft-Windows-WER-SystemErrorReporting, Event ID 1001) is written only on a
# real BSOD and its message carries the stop code and dump path. Get-WinEvent emits a
# (suppressed) error when nothing matches, so SilentlyContinue returns $null in that case.
$bugCheckEvents = Get-WinEvent -FilterHashtable @{
    LogName      = 'System'
    ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'
    Id           = 1001
    StartTime    = $startTime
} -ErrorAction SilentlyContinue

if ($bugCheckEvents) {
    $bsodFound = $true
    Write-Host "Bluescreen bugcheck event(s) detected: $($bugCheckEvents.Count)"
    Write-Host "-----------------------------"
    foreach ($event in $bugCheckEvents) {
        Write-Host "Time:    $($event.TimeCreated)"
        Write-Host "Details: $($event.Message)"
        Write-Host "-----------------------------"
    }
}

# Corroborating signal: minidump files written within the same window. A crash that wrote a
# dump but whose WER event was cleared still shows up here.
$minidumpPath = "$env:SystemRoot\Minidump"
if (Test-Path $minidumpPath) {
    $recentDumps = Get-ChildItem -Path $minidumpPath -Filter "*.dmp" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $startTime } | Sort-Object LastWriteTime -Descending
    if ($recentDumps) {
        $bsodFound = $true
        Write-Host "Recent minidump file(s) found in ${minidumpPath}: $($recentDumps.Count)"
        foreach ($dump in $recentDumps) {
            Write-Host "  $($dump.Name)  ($($dump.LastWriteTime))"
        }
        Write-Host "-----------------------------"
    }
}

# Exit 0 if no bluescreens in the window, otherwise exit 1 so the RMM condition can alert.
if ($bsodFound) {
    Write-Host "RESULT: Bluescreen activity detected in the last $LookbackDaysInt day(s). Alerting."
    Stop-Transcript
    exit 1
} else {
    Write-Host "RESULT: No bluescreens detected in the last $LookbackDaysInt day(s)."
    Stop-Transcript
    exit 0
}
