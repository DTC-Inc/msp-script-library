## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $DaysBack       - Number of days of history to pull (default: 90)
## $OutputFolder   - Folder to write the CSV to (default: C:\temp)

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-rds-logon-report.log"

# Auto-detect non-interactive PowerShell (e.g. NinjaOne, Datto, scheduled tasks).
# When -NonInteractive is on the command line, Read-Host throws and would kill the
# script, so treat that as RMM mode even if $RMM was not explicitly passed.
try {
    $cmdLineArgs = [Environment]::GetCommandLineArgs()
    if ($cmdLineArgs | Where-Object { $_ -match '^-NonInteractive$' }) {
        if ($RMM -ne 1) {
            Write-Host "Non-interactive PowerShell detected; treating as RMM mode."
            $RMM = 1
        }
    }
} catch {
    # If detection itself fails, leave $RMM as-is and proceed.
}

if ($RMM -ne 1) {
    $ValidInput = 0
    while ($ValidInput -ne 1) {
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

} else {
    # Prefer RMMScriptPath when the RMM provides one (e.g. Datto), otherwise fall back to WINDIR.
    if ($RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
    }

    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    }
}

# Defaults for parameters that may be set by the RMM or left empty interactively.
if (-not $DaysBack)     { $DaysBack = 90 }
if (-not $OutputFolder) { $OutputFolder = "C:\temp" }

# Emit progress to stdout BEFORE the transcript starts, so even if Start-Transcript
# fails (no log dir, locked file, etc.) the RMM still captures something useful.
Write-Host "msft-windows-rds-logon-report.ps1 starting"
Write-Host "Description: $Description"
Write-Host "RMM: $RMM"
Write-Host "DaysBack: $DaysBack"
Write-Host "OutputFolder: $OutputFolder"
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "User context: $env:USERNAME"
Write-Host "PowerShell: $($PSVersionTable.PSVersion) ($([IntPtr]::Size * 8)-bit)"

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

# Start the script logic here. Wrap Start-Transcript so a transcript failure
# (e.g. ErrorActionPreference=Stop in the RMM runner) cannot kill the script.
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

# Ensure output folder exists.
if (-not (Test-Path -Path $OutputFolder)) {
    Write-Host "Creating output folder $OutputFolder"
    try {
        New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
    } catch {
        Write-Host "ERROR: could not create output folder ${OutputFolder}: $($_.Exception.Message)"
        if ($transcriptStarted) { Stop-Transcript }
        exit 1
    }
}

$computerName = $env:COMPUTERNAME
$startTime    = (Get-Date).AddDays(-[int]$DaysBack)
$timestamp    = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath      = Join-Path $OutputFolder ("rds-logons-{0}-{1}days-{2}.csv" -f $computerName, $DaysBack, $timestamp)

# Fail fast if the LSM log is missing/disabled (e.g. running on a non-RDS host).
$lsmLogName = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
$lsmLog = Get-WinEvent -ListLog $lsmLogName -ErrorAction SilentlyContinue
if (-not $lsmLog) {
    Write-Host "ERROR: Event log '$lsmLogName' not present on $computerName. Is RDS Session Host installed?"
    if ($transcriptStarted) { Stop-Transcript }
    exit 1
}
Write-Host "LSM log: enabled=$($lsmLog.IsEnabled) records=$($lsmLog.RecordCount) sizeBytes=$($lsmLog.FileSize)"

Write-Host "Querying RDS logon events since $startTime on $computerName"

# Microsoft-Windows-TerminalServices-LocalSessionManager/Operational
#   21 = Remote Desktop Services: Session logon succeeded
#   25 = Remote Desktop Services: Session reconnection succeeded
$filter = @{
    LogName   = $lsmLogName
    Id        = 21, 25
    StartTime = $startTime
}

try {
    $events = Get-WinEvent -FilterHashtable $filter -ErrorAction Stop
} catch {
    if ($_.Exception.Message -match 'No events were found') {
        Write-Host "No RDS logon events found in the last $DaysBack days."
        $events = @()
    } else {
        Write-Host "Failed to query event log: $($_.Exception.Message)"
        if ($transcriptStarted) { Stop-Transcript }
        exit 1
    }
}

Write-Host "Found $($events.Count) events. Parsing..."

$results = foreach ($event in $events) {
    # The LSM events store User / SessionID / Address inside UserData/EventXML.
    $xml = [xml]$event.ToXml()
    $data = $xml.Event.UserData.EventXML

    $eventType = switch ($event.Id) {
        21 { 'Logon' }
        25 { 'Reconnect' }
        default { "Id$($event.Id)" }
    }

    [pscustomobject]@{
        TimeCreated = $event.TimeCreated
        Computer    = $computerName
        EventId     = $event.Id
        EventType   = $eventType
        User        = $data.User
        SessionID   = $data.SessionID
        SourceIP    = $data.Address
    }
}

$results = @($results | Sort-Object TimeCreated -Descending)

if ($results.Count -gt 0) {
    $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host "Wrote $($results.Count) rows to $csvPath"
} else {
    # Still produce an empty CSV with headers so the artifact exists.
    [pscustomobject]@{
        TimeCreated = $null
        Computer    = $computerName
        EventId     = $null
        EventType   = $null
        User        = $null
        SessionID   = $null
        SourceIP    = $null
    } | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    # Re-write without the placeholder row.
    "TimeCreated,Computer,EventId,EventType,User,SessionID,SourceIP" | Set-Content -Path $csvPath -Encoding UTF8
    Write-Host "No events to export. Empty CSV written to $csvPath"
}

Write-Host "msft-windows-rds-logon-report.ps1 completed"
if ($transcriptStarted) { Stop-Transcript }
