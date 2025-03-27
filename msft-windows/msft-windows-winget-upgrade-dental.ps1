## THIS SCRIPT USES THE WINGET COMMAND TO UPGRADE APPS WITH AVAILABLE UPDATES AND NOT SPECIFIED IN THE EXCLUSION FILE

## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM


# Getting input from user if not running from RMM else set variables from RMM.

# No variables are required for this script besides $Description.

$ScriptLogName = "msft-windows-winget-upgrade.log"

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

# Download the app exclusion list from Github

$rawUrl = "https://raw.githubusercontent.com/coop-a-loop/msp-script-library/refs/heads/main/msft-windows/msft-windows-winget-exclusions-dental.txt"
$excludedApps = Invoke-RestMethod -Uri $rawUrl
Write-Host "The following apps will be excluded from upgrade:"
Write-Host $excludedApps

# Split the exclusion list into an array, ensuring each app ID is treated separately
$excludedApps = $excludedApps -split "`n"  # Split by newlines to create an array

# Clean up each entry: trim spaces and remove quotes
$excludedApps = $excludedApps | ForEach-Object { $_.Trim().Trim("'") } | Where-Object { $_ -ne "" }

# Get list of apps with available upgrades
$appsToUpgrade = winget upgrade |
    Select-String "^\S" |  # Filter lines starting with non-whitespace characters
    Select-Object -Skip 2 |  # Skip the first two lines (header and dashed separator)
    ForEach-Object {
        # Clean up the line by trimming extra whitespace from the start and end
        $line = $_.Line.Trim()

        # Split by two or more spaces
        $fields = $line -split '\s{2,}'

        # Ensure the line has exactly 5 fields, and capture them
        if ($fields.Length -eq 5) {
            [PSCustomObject]@{
                Name       = $fields[0].Trim()    # App name
                Id         = $fields[1].Trim()    # App ID
                Version    = $fields[2].Trim()    # Installed version
                Available  = $fields[3].Trim()    # Available version
                Source     = $fields[4].Trim()    # Source
            }
        }
    }

# Display the list of apps with available upgrades
Write-Host "There are updates for the following $($appsToUpgrade.Count) apps"
$appsToUpgrade

# Simulate upgrading apps that are not in the exclusion list
$appsToUpgrade | ForEach-Object {
    if ($_ -and $excludedApps -notcontains $_.Id) {
        Write-Host "Simulating upgrade for: $($_.Name) (ID: $($_.Id))"
        # Add any actual upgrade simulation code here if needed
    }
    else {
        Write-Host "Skipping: $($_.Name) (ID: $($_.Id)) - Excluded"
    }
}

Write-Host ""

Stop-Transcript
