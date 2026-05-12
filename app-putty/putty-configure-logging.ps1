## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
##
## *** THIS SCRIPT MUST RUN IN THE LOGGED-ON USER'S CONTEXT, NOT AS SYSTEM. ***
## PuTTY stores per-user settings under HKCU; running as SYSTEM will write into
## the SYSTEM hive and have no effect on the engineer's PuTTY profile.
##
## $EngineerName  - (optional) Folder name to use under "Engineer Session Logs".
##                  Defaults to $env:USERNAME.
## $LogRoot       - (optional) Override the base path. Defaults to
##                  "G:\Shared drives\Engineer Session Logs".
## $LogType       - (optional) PuTTY LogType. Defaults to 2 (all session output).
##                  0=none, 1=printable, 2=all, 3=SSH packets, 4=SSH packets+raw

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "putty-configure-logging.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    # User-context script: write logs to LOCALAPPDATA so non-admin users can run it.
    $LogDir = Join-Path $env:LOCALAPPDATA 'DTC\logs'
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $LogPath = Join-Path $LogDir $ScriptLogName

} else {
    # Store the logs in the RMMScriptPath
    if ($null -eq $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"

    } else {
        $LogDir = Join-Path $env:LOCALAPPDATA 'DTC\logs'
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $LogPath = Join-Path $LogDir $ScriptLogName

    }

    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    }



}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"

# --- Guard: must run in user context, not SYSTEM ---
$current = [Security.Principal.WindowsIdentity]::GetCurrent().Name
Write-Host "Running as: $current"
if ($current -match '\\SYSTEM$' -or $current -eq 'NT AUTHORITY\SYSTEM') {
    Write-Host "[ERROR] This script is running as SYSTEM. PuTTY config must be applied per-user."
    Write-Host "        Re-run from the engineer's logged-on session (RMM 'Run As: Logged-On User')."
    Stop-Transcript
    exit 1
}

# --- Defaults ---
if ([string]::IsNullOrWhiteSpace($EngineerName)) { $EngineerName = $env:USERNAME }
if ([string]::IsNullOrWhiteSpace($LogRoot))      { $LogRoot      = 'G:\Shared drives\Engineer Session Logs' }
if (-not $PSBoundParameters.ContainsKey('LogType') -and ($null -eq $LogType -or $LogType -eq '')) {
    $LogType = 2
}

$engineerFolder = Join-Path $LogRoot $EngineerName
$logFileName    = Join-Path $engineerFolder '&h-&Y&M&D-&T.log'

Write-Host "EngineerName : $EngineerName"
Write-Host "LogRoot      : $LogRoot"
Write-Host "Engineer dir : $engineerFolder"
Write-Host "PuTTY pattern: $logFileName"

# --- Make sure the engineer's folder exists if the drive is mounted ---
if (Test-Path -Path $LogRoot) {
    if (-not (Test-Path -Path $engineerFolder)) {
        try {
            New-Item -ItemType Directory -Path $engineerFolder -Force | Out-Null
            Write-Host "Created engineer log folder: $engineerFolder"
        } catch {
            Write-Host "[WARNING] Could not create $engineerFolder. PuTTY may fail to write logs until the folder exists. Error: $_"
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

# LogType: 2 = all session output
# LogFileName: full path with PuTTY substitution tokens
# LogFileClash: 1 = always append (no prompt)
# LogFlush: 1 = flush log on every write
# LogHeader: 1 = write a header banner at the start of each log
$values = @{
    'LogType'      = [int]$LogType
    'LogFileName'  = [string]$logFileName
    'LogFileClash' = 1
    'LogFlush'     = 1
    'LogHeader'    = 1
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
Write-Host "  LogType      = $($verify.LogType)"
Write-Host "  LogFileName  = $($verify.LogFileName)"
Write-Host "  LogFileClash = $($verify.LogFileClash)"
Write-Host "  LogFlush     = $($verify.LogFlush)"
Write-Host "  LogHeader    = $($verify.LogHeader)"

if ($verify.LogFileName -eq $logFileName -and [int]$verify.LogType -eq [int]$LogType) {
    Write-Host "[SUCCESS] PuTTY default logging configured for $EngineerName."
    Stop-Transcript
    exit 0
} else {
    Write-Host "[FAILURE] Verification mismatch. Inspect HKCU registry values above."
    Stop-Transcript
    exit 1
}
