# Define the event ID, log name and service name
$eventId = 4012
$logName = "DFS Replication"
$serviceName = 'DFSR'

# Get all events with ID 4012 from the DFS Replication log and sort them by TimeCreated in ascending order
$events = Get-WinEvent -FilterHashtable @{LogName=$logName; ID=$eventId} | Sort-Object TimeCreated

if ($events -ne $null -and $events.Count -gt 0) {
    # Get the earliest event
    $earliestEvent = $events[0]
    
    # Convert the event time to a DateTime object
    $eventTime = $earliestEvent.TimeCreated

    # Calculate the difference in days from the event time to now
    $timeDifference = New-TimeSpan -Start $eventTime -End (Get-Date)

    # Output the number of days since the event was logged
    Write-Output "The DFS Replication has been disconnected from its partner for $($timeDifference.Days) days since the first Event ID $eventId recorded on $($eventTime)."
} else {
    Write-Output "No events with ID $eventId found in the $logName log."
}

# Add 200 days to MaxOfflineTimeInDays
	$daysPlus = $timeDifference.Days + 1000

# Save command to a variable to run withing powershell
	$dfsrcmd = "wmic.exe /namespace:\\root\microsoftdfs path DfsrMachineConfig set MaxOfflineTimeInDays=$daysPlus"

# Run command to set MaxOfflineTimeInDays to value in $daysPlus200
	Start-Process "cmd.exe" -ArgumentList "/c $dfsrcmd"

# Restart the service for setting to take effect
Restart-Service -Name $serviceName -Force

# Wait for the service to come back up
do {
    Start-Sleep -Seconds 1
    $serviceStatus = (Get-Service -Name $serviceName).Status
} while ($serviceStatus -ne 'Running')

# Save command in variable to run in powershell with default MaxOfflineTimeInDays value
	$dfsrcmd = "wmic.exe /namespace:\\root\microsoftdfs path DfsrMachineConfig set MaxOfflineTimeInDays=60"

# Run command to set MaxOfflineTimeInDays to default value
	Start-Process "cmd.exe" -ArgumentList "/c $dfsrcmd"




