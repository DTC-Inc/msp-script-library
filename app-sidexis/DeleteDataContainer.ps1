## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# Getting input from user if not running from RMM else set variables from RMM.


$ScriptLogName = "CleanupDataContainer.log"

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

# Script to clean up old X-ray images from datacontainer folder
# Author: Claude
# Date: 2024

# Define log file path
$logPath = "C:\Windows\Logs\DataContainerCleanup"
$logFile = Join-Path -Path $logPath -ChildPath "DataContainerCleanup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Create log directory if it doesn't exist
if (-not (Test-Path -Path $logPath)) {
    New-Item -Path $logPath -ItemType Directory -Force | Out-Null
}

# Function to write to both console and log file
function Write-Log {
    param($Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    Write-Host $logMessage
    Add-Content -Path $logFile -Value $logMessage
}

Write-Log "Starting DataContainer cleanup process"

# Get the system drive
$systemDrive = $env:SYSTEMDRIVE

# Define the datacontainer path
$dataContainerPath = Join-Path -Path $systemDrive -ChildPath "datacontainer"

# Check if the datacontainer folder exists
if (-not (Test-Path -Path $dataContainerPath)) {
    Write-Log "DataContainer folder not found at: $dataContainerPath"
    exit
}

# Get current date
$currentDate = Get-Date

# Get all folders in datacontainer
$folders = Get-ChildItem -Path $dataContainerPath -Directory

# Counter for deleted folders
$deletedCount = 0

# Process each folder
foreach ($folder in $folders) {
    # Check if folder name starts with 8 digits (yyyyMMdd)
    if ($folder.Name -match '^(\d{8})_') {
        $dateString = $matches[1]
        try {
            # Parse the date from the first 8 digits
            $folderDate = [DateTime]::ParseExact($dateString, "yyyyMMdd", $null)
            # Calculate the age of the folder
            $age = $currentDate - $folderDate
            # If folder is older than 7 days, delete it
            if ($age.Days -gt 7) {
                Write-Log "Deleting folder: $($folder.FullName) (Age: $($age.Days) days)"
                Remove-Item -Path $folder.FullName -Recurse -Force
                $deletedCount++
            }
        }
        catch {
            Write-Log "Error processing folder $($folder.Name): $_"
        }
    }
}

Write-Log "Cleanup completed. Deleted $deletedCount folders." 

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"

Stop-Transcript
