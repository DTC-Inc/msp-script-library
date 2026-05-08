## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $DaysBack       - Number of days of history to pull (default: 90)
## $OutputFolder   - Folder to write the CSV to (default: C:\temp)

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-rds-logon-report.log"

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
    if ($null -eq $RMMScriptPath) {
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

# Start the script logic here.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host "DaysBack: $DaysBack"
Write-Host "OutputFolder: $OutputFolder"

# Ensure output folder exists.
if (-not (Test-Path -Path $OutputFolder)) {
    Write-Host "Creating output folder $OutputFolder"
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

$computerName = $env:COMPUTERNAME
$startTime    = (Get-Date).AddDays(-[int]$DaysBack)
$timestamp    = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath      = Join-Path $OutputFolder ("rds-logons-{0}-{1}days-{2}.csv" -f $computerName, $DaysBack, $timestamp)

Write-Host "Querying RDS logon events since $startTime on $computerName"

# Microsoft-Windows-TerminalServices-LocalSessionManager/Operational
#   21 = Remote Desktop Services: Session logon succeeded
#   25 = Remote Desktop Services: Session reconnection succeeded
$filter = @{
    LogName   = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
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
        Stop-Transcript
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

$results = $results | Sort-Object TimeCreated -Descending

if ($results) {
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

Stop-Transcript
