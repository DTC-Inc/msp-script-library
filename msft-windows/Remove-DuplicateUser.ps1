## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "remove-duplicate-user.log"

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
# Script to clean up duplicate profile registry entries
# Author: Joseph Owens
# Description: Identifies and removes invalid profile registry entries that have duplicate ProfileImagePath values
# Note: This script only processes local user profiles. Domain profiles are automatically skipped.

# Create log directory if it doesn't exist
$logPath = "C:\Windows\Logs\ProfileCleanup"
if (-not (Test-Path $logPath)) {
    New-Item -ItemType Directory -Path $logPath -Force | Out-Null
}

# Set up logging
$logFile = Join-Path $logPath "ProfileCleanup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
function Write-Log {
    param($Message)
    $logMessage = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $Message"
    Add-Content -Path $logFile -Value $logMessage
    Write-Host $logMessage
}

Write-Log "Starting Profile Cleanup Script"
Write-Log "Note: Only local user profiles will be processed. Domain profiles will be skipped."

# Get all ProfileList registry keys
$profileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
$profileList = Get-ChildItem -Path $profileListPath

# Create hashtable to store ProfileImagePath and their associated SIDs
$profilePaths = @{}

Write-Log "Scanning ProfileList registry keys..."

foreach ($profile in $profileList) {
    $sid = $profile.PSChildName
    $profileImagePath = (Get-ItemProperty -Path $profile.PSPath -Name "ProfileImagePath" -ErrorAction SilentlyContinue).ProfileImagePath

    # Skip if no ProfileImagePath
    if (-not $profileImagePath) {
        Write-Log "Skipping profile: $sid - No ProfileImagePath found"
        continue
    }

    # Skip domain profiles
    if ($profileImagePath -like "*\\*") {
        Write-Log "Skipping domain profile: $sid - $profileImagePath"
        continue
    }

    # Add to hashtable if path exists
    if ($profilePaths.ContainsKey($profileImagePath)) {
        $profilePaths[$profileImagePath] += $sid
        Write-Log "Found duplicate profile path: $profileImagePath"
        Write-Log "Current SIDs for this path: $($profilePaths[$profileImagePath] -join ', ')"
    } else {
        $profilePaths[$profileImagePath] = @($sid)
        Write-Log "Found local profile path: $profileImagePath with SID: $sid"
    }
}

# Process duplicates
foreach ($path in $profilePaths.Keys) {
    $sids = $profilePaths[$path]
    
    if ($sids.Count -gt 1) {
        Write-Log "`nProcessing duplicate profiles for path: $path"
        Write-Log "All SIDs found: $($sids -join ', ')"

        # Get the username from the path
        $username = Split-Path $path -Leaf

        # Get the correct SID from local user account
        $correctSid = $null
        try {
            $localUser = Get-LocalUser -Name $username -ErrorAction Stop
            $correctSid = $localUser.SID.Value
            Write-Log "Found local user account: $username"
            Write-Log "Correct SID from local user account: $correctSid"
        } catch {
            Write-Log "Error: User '$username' not found in local user accounts. Skipping."
            continue
        }

        # Find and remove invalid SID
        foreach ($sid in $sids) {
            if ($sid -ne $correctSid) {
                Write-Log "Removing invalid profile registry key: $sid"
                try {
                    Remove-Item -Path "$profileListPath\$sid" -Recurse -Force
                    Write-Log "Successfully removed invalid profile registry key: $sid"
                } catch {
                    Write-Log "Error removing registry key $sid : $_"
                }
            } else {
                Write-Log "Keeping valid profile registry key: $sid"
            }
        }
    }
}

Write-Log "`nProfile Cleanup Script completed"
Write-Log "Review the log file at: $logFile" 

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"

Stop-Transcript
