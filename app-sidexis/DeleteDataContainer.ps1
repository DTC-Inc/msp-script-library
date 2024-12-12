## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# Getting input from user if not running from RMM else set variables from RMM.


$ScriptLogName = "DeleteDataContainer.log"

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

# Path to the folder
$FolderPath = "C:\datacontainer"


# Check if the folder exists
if (-Not (Test-Path -Path $FolderPath)) {
    Write-Output "Folder '$FolderPath' does not exist. Exiting script."
    Exit
}

# Get the current date minus 30 days
$DateThreshold = (Get-Date).AddDays(-30)

# Delete folders older than 30 days
Get-ChildItem -Path $FolderPath -Directory | Where-Object { $_.LastWriteTime -lt $DateThreshold } | ForEach-Object {
    Write-Output "Deleting folder: $($_.FullName)"
    Remove-Item -Path $_.FullName -Recurse -Force
}

Write-Output "Cleanup completed for folder '$FolderPath'."


Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"

Stop-Transcript
