## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "EnterLogNameHere.log"

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
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

} else { 
    # Store the logs in the RMMScriptPath
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

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"

# Get the health status of all storage spaces virtual disks
$virtualDisks = Get-VirtualDisk

# Initialize flag to track health status
$allHealthy = $true

foreach ($disk in $virtualDisks) {
    # Check the health status of each virtual disk
    if ($disk.HealthStatus -ne 'Healthy') {
        # Display details of the unhealthy virtual disk
        Write-Host "Unhealthy Virtual Disk Detected:"
        Write-Host "Name: $($disk.FriendlyName)"
        Write-Host "Health Status: $($disk.HealthStatus)"
        Write-Host "Operational Status: $($disk.OperationalStatus)"
        Write-Host "Size: $($disk.Size) bytes"
        Write-Host "Resiliency Setting: $($disk.ResiliencySettingName)"
        Write-Host "-----------------------------"
        
        $allHealthy = $false
    }
}

# Exit with 0 if all disks are healthy, otherwise exit with 1
if ($allHealthy) {
    exit 0
} else {
    exit 1
}


Stop-Transcript
