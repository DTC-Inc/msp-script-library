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
## $env:RMM            - "1" to skip the interactive Read-Host prompt
## $env:Description    - Ticket # / initials for the transcript audit trail
## $env:RMMScriptPath  - Optional transcript root. Falls back to LOCALAPPDATA\dtc-logs
## $env:EngineerName   - Folder under $LogRoot. Default: $env:USERNAME
## $env:LogRoot        - Base path. Default: "G:\Shared drives\Engineer Session Logs"
## $env:LogFilePattern - PuTTY filename template. Default: "&h-&Y&M&D-&T.log"
## $env:LogType        - 0=none 1=printable 2=all 3=SSH-pkt 4=SSH-pkt+raw. Default: 1
##                       (1 = printable; safer than 2 because raw input bytes that
##                       can include pasted credentials are not written to disk)
## $env:LogFileClash   - 0=overwrite, 1=append, -1=ask. Default: 1

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "putty-configure-logging.log"

# Auto-detect non-interactive PowerShell (e.g. NinjaOne, Datto, scheduled tasks).
# When -NonInteractive is on the command line, Read-Host throws and would kill the
# script, so treat that as RMM mode even if $env:RMM was not explicitly passed.
try {
    $cmdLineArgs = [Environment]::GetCommandLineArgs()
    if ($cmdLineArgs | Where-Object { $_ -match '^-NonInteractive$' }) {
        if ($env:RMM -ne "1") {
            Write-Host "Non-interactive PowerShell detected; treating as RMM mode."
            $env:RMM = "1"
        }
    }
} catch {
    # If detection itself fails, leave $env:RMM as-is and proceed.
}

if ($env:RMM -ne "1") {
    $ValidInput = 0
    while ($ValidInput -ne 1) {
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    # User-context script: write logs to LOCALAPPDATA so non-admin users can run it.
    $LogPath = Join-Path (Join-Path $env:LOCALAPPDATA 'dtc-logs') $ScriptLogName

} else {
    # Prefer RMMScriptPath when the RMM provides one (e.g. Datto), otherwise fall back
    # to LOCALAPPDATA so the user-context script can write its transcript without admin.
    if ($env:RMMScriptPath) {
        $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = Join-Path (Join-Path $env:LOCALAPPDATA 'dtc-logs') $ScriptLogName
    }

    if ([string]::IsNullOrWhiteSpace($env:Description)) {
        Write-Host "Description is empty/null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    } else {
        $Description = $env:Description
    }
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
Write-Host "RMM            : $env:RMM"
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
