## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
##
## *** THIS SCRIPT MUST RUN IN THE LOGGED-ON USER'S CONTEXT, NOT AS SYSTEM. ***
## PuTTY stores per-user settings under HKCU; running as SYSTEM writes into the
## SYSTEM hive and has no effect on the engineer's PuTTY profile.
##
## Framing: this is a SANE DEFAULT, not a compliance enforcement control.
## Engineers can override per-session in PuTTY's Logging panel or clear the
## HKCU values directly. Treat it as "logs are on unless someone goes out of
## their way" -- not "logging is enforced." Audit/retention/ACL of the log
## destination is handled outside this script.
##
## $Description    / $env:Description    - Ticket # / initials for the transcript audit trail
## $RMMScriptPath  / $env:RMMScriptPath  - Optional transcript root. Falls back to LOCALAPPDATA\dtc-logs
## $EngineerName   / $env:EngineerName   - Folder under $LogRoot. Default: $env:USERNAME
## $LogRoot        / $env:LogRoot        - Base path. Default: "G:\Shared drives\Engineer Session Logs"
## $LogFilePattern / $env:LogFilePattern - PuTTY filename template. Default: "&h-&Y&M&D-&T.log"
## $LogType        / $env:LogType        - 0=none 1=printable 2=all 3=SSH-pkt 4=SSH-pkt+raw. Default: 1
##                                         (1 = printable; safer than 2 because raw input bytes that
##                                         can include pasted credentials are not written to disk)
## $LogFileClash   / $env:LogFileClash   - 0=overwrite, 1=append, -1=ask. Default: 1

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    # There is no Read-Host and no $env:RMM flag: the script is non-interactive by design.
    [string]$Description    = $env:Description,
    [string]$RMMScriptPath  = $env:RMMScriptPath,
    [string]$EngineerName   = $env:EngineerName,
    [string]$LogRoot        = $env:LogRoot,
    [string]$LogFilePattern = $env:LogFilePattern,
    [string]$LogType        = $env:LogType,
    [string]$LogFileClash   = $env:LogFileClash
)

$ScriptLogName = "putty-configure-logging.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Mirror the resolved parameter values into $env: so the resolution block below can
# reference either the param or $env:Name, whichever form the input arrived in.
if (-not [string]::IsNullOrEmpty($Description))    { $env:Description    = $Description }
if (-not [string]::IsNullOrEmpty($RMMScriptPath))  { $env:RMMScriptPath  = $RMMScriptPath }
if (-not [string]::IsNullOrEmpty($EngineerName))   { $env:EngineerName   = $EngineerName }
if (-not [string]::IsNullOrEmpty($LogRoot))        { $env:LogRoot        = $LogRoot }
if (-not [string]::IsNullOrEmpty($LogFilePattern)) { $env:LogFilePattern = $LogFilePattern }
if (-not [string]::IsNullOrEmpty($LogType))        { $env:LogType        = $LogType }
if (-not [string]::IsNullOrEmpty($LogFileClash))   { $env:LogFileClash   = $LogFileClash }

# Default the audit-trail description if it was not supplied.
if ([string]::IsNullOrWhiteSpace($env:Description)) {
    Write-Host "Description is empty/null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
} else {
    $Description = $env:Description
}

# User-context script: prefer RMMScriptPath when the RMM provides one (e.g. Datto), otherwise
# fall back to LOCALAPPDATA so the user-context script can write its transcript without admin.
if ($env:RMMScriptPath) {
    $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = Join-Path (Join-Path $env:LOCALAPPDATA 'dtc-logs') $ScriptLogName
}

# Resolve effective values from env vars with sane defaults.
$EngineerName   = if ([string]::IsNullOrWhiteSpace($env:EngineerName))   { $env:USERNAME }                          else { $env:EngineerName }
$LogRoot        = if ([string]::IsNullOrWhiteSpace($env:LogRoot))        { 'G:\Shared drives\Engineer Session Logs' } else { $env:LogRoot }
$LogFilePattern = if ([string]::IsNullOrWhiteSpace($env:LogFilePattern)) { '&h-&Y&M&D-&T.log' }                       else { $env:LogFilePattern }
$LogType        = if ([string]::IsNullOrWhiteSpace($env:LogType))        { 1 }                                       else { [int]$env:LogType }
$LogFileClash   = if ([string]::IsNullOrWhiteSpace($env:LogFileClash))   { 1 }                                       else { [int]$env:LogFileClash }

# Emit progress to stdout BEFORE the transcript starts, so even if Start-Transcript
# fails (no log dir, locked file, etc.) the RMM still captures something useful.
Write-Host "putty-configure-logging.ps1 starting"
Write-Host "Description    : $Description"
Write-Host "Computer       : $env:COMPUTERNAME"
Write-Host "User context   : $env:USERNAME"
Write-Host "PowerShell     : $($PSVersionTable.PSVersion) ($([IntPtr]::Size * 8)-bit)"
Write-Host "EngineerName   : $EngineerName"
Write-Host "LogRoot        : $LogRoot"
Write-Host "LogFilePattern : $LogFilePattern"
Write-Host "LogType        : $LogType"
Write-Host "LogFileClash   : $LogFileClash"

# Pre-create the transcript directory so Start-Transcript can't fail on a missing folder.
$logDir = Split-Path -Path $LogPath -Parent
if ($logDir -and -not (Test-Path -Path $logDir)) {
    try {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        Write-Host "Created log directory: $logDir"
    } catch {
        Write-Host "Warning: could not create log directory ${logDir}: $($_.Exception.Message)"
    }
}

# Wrap Start-Transcript so a transcript failure (e.g. ErrorActionPreference=Stop in
# the RMM runner) cannot kill the script.
$transcriptStarted = $false
try {
    Start-Transcript -Path $LogPath -ErrorAction Stop | Out-Null
    $transcriptStarted = $true
    Write-Host "Transcript started: $LogPath"
} catch {
    Write-Host "Warning: Start-Transcript failed for ${LogPath}: $($_.Exception.Message)"
    Write-Host "Continuing without transcript."
}

Write-Host "Log path: $LogPath"

# Main body wrapped in try/finally so any unhandled throw still stops the transcript
# cleanly and returns a real exit code to the RMM.
$exitCode = 0

try {
    # --- Guard: must run in user context, not SYSTEM ---
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-Host "Running as: $currentUser"
    if ($currentUser -match '\\SYSTEM$' -or $currentUser -eq 'NT AUTHORITY\SYSTEM') {
        throw "This script is running as SYSTEM. PuTTY config must be applied per-user. Re-run from the engineer's logged-on session (NinjaRMM 'Run As: Logged-On User')."
    }

    # --- Build paths ---
    $engineerFolder  = Join-Path $LogRoot $EngineerName
    $fullLogFileName = Join-Path $engineerFolder $LogFilePattern

    Write-Host "Engineer dir   : $engineerFolder"
    Write-Host "PuTTY log path : $fullLogFileName"

    # --- Make sure the engineer's folder exists if the drive is mounted ---
    if (Test-Path -Path $LogRoot) {
        if (-not (Test-Path -Path $engineerFolder)) {
            try {
                New-Item -ItemType Directory -Path $engineerFolder -Force | Out-Null
                Write-Host "Created engineer log folder: $engineerFolder"
            } catch {
                Write-Host "[WARNING] Could not create $engineerFolder. PuTTY may fail to write logs until the folder exists. Error: $($_.Exception.Message)"
            }
        } else {
            Write-Host "Engineer log folder already exists."
        }
    } else {
        Write-Host "[WARNING] $LogRoot is not currently accessible (Google Drive may not be mounted yet)."
        Write-Host "          Registry settings will still be written; logging will start once the drive is available."
    }

    # --- Write PuTTY Default Settings under HKCU ---
    # PuTTY URL-encodes the space in the key name as %20.
    $puttyDefaultsKey = 'HKCU:\Software\SimonTatham\PuTTY\Sessions\Default%20Settings'

    if (-not (Test-Path $puttyDefaultsKey)) {
        Write-Host "Creating PuTTY Default Settings registry key."
        New-Item -Path $puttyDefaultsKey -Force | Out-Null
    }

    # LogType=1 (printable) by default: safer than 2 because raw input bytes that
    # can include pasted credentials are NOT written to disk.
    # SSHLogOmitPasswords=1: don't log SSH password-auth prompt data.
    # SSHLogOmitData=1: don't log session data in SSH packet logs (defense in depth
    #                   for LogType 3/4; no effect on LogType 1/2 but explicit is better).
    $values = @{
        'LogType'             = [int]$LogType
        'LogFileName'         = [string]$fullLogFileName
        'LogFileClash'        = [int]$LogFileClash
        'LogFlush'            = 1
        'LogHeader'           = 1
        'SSHLogOmitPasswords' = 1
        'SSHLogOmitData'      = 1
    }

    foreach ($name in $values.Keys) {
        $val  = $values[$name]
        $type = if ($val -is [int]) { 'DWord' } else { 'String' }
        Set-ItemProperty -Path $puttyDefaultsKey -Name $name -Value $val -Type $type -Force
        Write-Host "Set $name ($type) = $val"
    }

    # --- Verify ---
    $verify = Get-ItemProperty -Path $puttyDefaultsKey
    Write-Host ""
    Write-Host "Verification:"
    Write-Host "  LogType             = $($verify.LogType)"
    Write-Host "  LogFileName         = $($verify.LogFileName)"
    Write-Host "  LogFileClash        = $($verify.LogFileClash)"
    Write-Host "  LogFlush            = $($verify.LogFlush)"
    Write-Host "  LogHeader           = $($verify.LogHeader)"
    Write-Host "  SSHLogOmitPasswords = $($verify.SSHLogOmitPasswords)"
    Write-Host "  SSHLogOmitData      = $($verify.SSHLogOmitData)"

    if ($verify.LogFileName -ne $fullLogFileName -or [int]$verify.LogType -ne [int]$LogType) {
        throw "Verification mismatch. Expected LogFileName=$fullLogFileName / LogType=$LogType. See HKCU values above."
    }

    Write-Host "[SUCCESS] PuTTY default logging configured for $EngineerName."
} catch {
    Write-Host "[FAILURE] $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    $exitCode = 1
} finally {
    Write-Host "putty-configure-logging.ps1 completed (exit $exitCode)"
    if ($transcriptStarted) { Stop-Transcript }
}

exit $exitCode
