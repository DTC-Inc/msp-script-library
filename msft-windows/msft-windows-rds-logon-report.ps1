## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $env:RMM            - "1" to skip the interactive Read-Host prompt
## $env:Description    - Ticket # / initials for the transcript audit trail
## $env:RMMScriptPath  - Optional transcript root (e.g. Datto). Falls back to $env:WINDIR\logs
## $env:DaysBack       - Number of days of history to pull (default: 90)
## $env:OutputFolder   - Folder to write the CSV to (default: C:\temp)

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-rds-logon-report.log"

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
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"

} else {
    # Prefer RMMScriptPath when the RMM provides one (e.g. Datto), otherwise fall back to WINDIR.
    if ($env:RMMScriptPath) {
        $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$env:WINDIR\logs\$ScriptLogName"
    }

    if ([string]::IsNullOrWhiteSpace($env:Description)) {
        Write-Host "Description is empty/null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    } else {
        $Description = $env:Description
    }
}

# Resolve effective values from env vars with sane defaults.
$DaysBack     = if ([string]::IsNullOrWhiteSpace($env:DaysBack))     { 90 }        else { [int]$env:DaysBack }
$OutputFolder = if ([string]::IsNullOrWhiteSpace($env:OutputFolder)) { 'C:\temp' } else { $env:OutputFolder }

# Emit progress to stdout BEFORE the transcript starts, so even if Start-Transcript
# fails (no log dir, locked file, etc.) the RMM still captures something useful.
Write-Host "msft-windows-rds-logon-report.ps1 starting"
Write-Host "Description  : $Description"
Write-Host "RMM          : $env:RMM"
Write-Host "Computer     : $env:COMPUTERNAME"
Write-Host "User context : $env:USERNAME"
Write-Host "PowerShell   : $($PSVersionTable.PSVersion) ($([IntPtr]::Size * 8)-bit)"
Write-Host "DaysBack     : $DaysBack"
Write-Host "OutputFolder : $OutputFolder"

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
    # Ensure output folder exists.
    if (-not (Test-Path -Path $OutputFolder)) {
        Write-Host "Creating output folder $OutputFolder"
        try {
            New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
        } catch {
            throw "Could not create output folder ${OutputFolder}: $($_.Exception.Message)"
        }
    }

    $computerName = $env:COMPUTERNAME
    $now          = Get-Date
    $startTime    = $now.AddDays(-[int]$DaysBack)
    $timestamp    = $now.ToString("yyyyMMdd-HHmmss")

    $securityLogName = 'Security'
    # -ListLog needs admin / Event Log Readers; if that fails it is not a hard error,
    # the real test is the FilterXPath query below.
    $securityLog = Get-WinEvent -ListLog $securityLogName -ErrorAction SilentlyContinue
    if ($securityLog) {
        Write-Host "Security log: enabled=$($securityLog.IsEnabled) records=$($securityLog.RecordCount) sizeBytes=$($securityLog.FileSize)"
    } else {
        Write-Host "Note: could not enumerate '$securityLogName' (likely permissions). Continuing to query."
    }

    Write-Host "Querying RDS logon events since $startTime on $computerName"

    # Security log:
    #   4624 LogonType=10 = RemoteInteractive (RDP authentication succeeded)
    #   4778               = Session was reconnected to a Window Station
    # Push filters down to the event log API via XPath so we don't drag the
    # entire Security log into memory on busy hosts.
    $startIso  = $startTime.ToUniversalTime().ToString('o')
    $xpath4624 = "*[System[EventID=4624 and TimeCreated[@SystemTime>='$startIso']]] and *[EventData[Data[@Name='LogonType']='10']]"
    $xpath4778 = "*[System[EventID=4778 and TimeCreated[@SystemTime>='$startIso']]]"

    function Get-FilteredEvents {
        param([string]$LogName, [string]$XPath, [string]$Label)
        try {
            return @(Get-WinEvent -LogName $LogName -FilterXPath $XPath -ErrorAction Stop)
        } catch {
            if ($_.Exception.Message -match 'No events were found') {
                Write-Host "No $Label events in window."
                return @()
            }
            throw
        }
    }

    try {
        $logonEvents     = Get-FilteredEvents -LogName $securityLogName -XPath $xpath4624 -Label '4624 (LogonType=10)'
        $reconnectEvents = Get-FilteredEvents -LogName $securityLogName -XPath $xpath4778 -Label '4778 (reconnect)'
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'Attempted to perform an unauthorized operation|access is denied') {
            throw "Failed to query Security log: $msg. Reading the Security log requires Administrator or membership in the 'Event Log Readers' group. NinjaOne running as SYSTEM has access."
        }
        throw "Failed to query Security log: $msg"
    }

    $events = @($logonEvents) + @($reconnectEvents)
    Write-Host "Found $($logonEvents.Count) logon (4624 LT=10) and $($reconnectEvents.Count) reconnect (4778) events. Parsing..."

    $results = foreach ($event in $events) {
        # Both 4624 and 4778 store fields in EventData/Data nodes keyed by Name attribute.
        $xml = [xml]$event.ToXml()
        $dataNodes = @{}
        foreach ($d in $xml.Event.EventData.Data) {
            if ($d.Name) { $dataNodes[$d.Name] = $d.'#text' }
        }

        if ($event.Id -eq 4624) {
            $eventType = 'Logon'
            $domain    = $dataNodes['TargetDomainName']
            $userName  = $dataNodes['TargetUserName']
            $sessionId = $dataNodes['LogonId']
            $sourceIp  = $dataNodes['IpAddress']
        } else {
            $eventType = 'Reconnect'
            $domain    = $dataNodes['AccountDomain']
            $userName  = $dataNodes['AccountName']
            $sessionId = $dataNodes['SessionName']
            $sourceIp  = $dataNodes['ClientAddress']
        }

        # Skip machine accounts and well-known system principals.
        if ($userName -match '\$$') { continue }
        if ($userName -in @('SYSTEM', 'ANONYMOUS LOGON', 'LOCAL SERVICE', 'NETWORK SERVICE', 'DWM-1', 'UMFD-0', 'UMFD-1')) { continue }

        $userField = if ($domain) { "$domain\$userName" } else { $userName }

        [pscustomobject]@{
            TimeCreated = $event.TimeCreated
            Computer    = $computerName
            EventId     = $event.Id
            EventType   = $eventType
            User        = $userField
            SessionID   = $sessionId
            SourceIP    = $sourceIp
        }
    }

    $results = @($results | Sort-Object TimeCreated -Descending)

    # Name the CSV based on the actual span of data retrieved, not the requested DaysBack.
    # Example: requested 90 days, log only retained 14 -> filename shows "14days".
    if ($results.Count -gt 0) {
        $oldestEvent = ($results | Select-Object -Last 1).TimeCreated
        $actualDays  = [int][math]::Ceiling(($now - $oldestEvent).TotalDays)
        if ($actualDays -lt 1) { $actualDays = 1 }
    } else {
        $actualDays = 0
    }
    $csvPath = Join-Path $OutputFolder ("rds-logons-{0}-{1}days-{2}.csv" -f $computerName, $actualDays, $timestamp)
    Write-Host "Requested $DaysBack days, retrieved $actualDays days of data; CSV: $csvPath"

    if ($results.Count -gt 0) {
        $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host "[SUCCESS] Wrote $($results.Count) rows to $csvPath"
    } else {
        # Still produce an empty CSV with headers so the artifact exists.
        "TimeCreated,Computer,EventId,EventType,User,SessionID,SourceIP" | Set-Content -Path $csvPath -Encoding UTF8
        Write-Host "[SUCCESS] No events to export. Empty CSV written to $csvPath"
    }
} catch {
    Write-Host "[FAILURE] $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    $exitCode = 1
} finally {
    Write-Host "msft-windows-rds-logon-report.ps1 completed (exit $exitCode)"
    if ($transcriptStarted) { Stop-Transcript }
}

exit $exitCode
