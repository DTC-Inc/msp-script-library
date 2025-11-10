## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $RMM

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-detect-duplicate-profiles.log"

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

<#
.SYNOPSIS
    Detects duplicate ProfileImagePath entries in Windows user profile registry.

.DESCRIPTION
    Scans HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList for duplicate
    ProfileImagePath values which can cause user profile corruption and login issues.

    Common causes:
    - Failed domain migrations
    - Profile corruption during Windows upgrades
    - Manual profile manipulation
    - SID conflicts

.NOTES
    Author: Nathaniel Smith / Claude Code
    Registry Path: HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList
#>

### ————— PROFILE LIST DETECTION —————
Write-Output "`n========================================"
Write-Output "Windows Profile Duplicate Detection"
Write-Output "========================================`n"

$profileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"

Write-Output "Scanning registry: $profileListPath"
Write-Output ""

try {
    # Get all profile subkeys (SIDs)
    $profileKeys = Get-ChildItem -Path $profileListPath -ErrorAction Stop

    if ($profileKeys.Count -eq 0) {
        Write-Output "No profile keys found in ProfileList."
        Stop-Transcript
        exit 0
    }

    Write-Output "Found $($profileKeys.Count) profile entries. Analyzing for duplicates..."
    Write-Output ""

    # Build a hashtable of ProfileImagePath -> List of SIDs
    $profilePaths = @{}
    $totalProfiles = 0

    foreach ($key in $profileKeys) {
        $sid = $key.PSChildName

        try {
            $profileImagePath = (Get-ItemProperty -Path $key.PSPath -Name "ProfileImagePath" -ErrorAction SilentlyContinue).ProfileImagePath

            if ($profileImagePath) {
                $totalProfiles++

                # Normalize path (case-insensitive comparison)
                $normalizedPath = $profileImagePath.ToLower()

                if (-not $profilePaths.ContainsKey($normalizedPath)) {
                    $profilePaths[$normalizedPath] = @()
                }

                $profilePaths[$normalizedPath] += @{
                    SID = $sid
                    Path = $profileImagePath
                    KeyPath = $key.PSPath
                }
            }
        } catch {
            Write-Warning "Could not read ProfileImagePath for SID: $sid. Error: $($_.Exception.Message)"
        }
    }

    Write-Output "Total profiles with ProfileImagePath: $totalProfiles"
    Write-Output "Unique profile paths: $($profilePaths.Count)"
    Write-Output ""

    # Find duplicates
    $duplicates = $profilePaths.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 }

    if ($duplicates.Count -eq 0) {
        Write-Output "========================================`n"
        Write-Output "RESULT: No duplicate profile paths found."
        Write-Output ""
        Write-Output "All user profiles have unique ProfileImagePath values."
        Write-Output "Profile registry appears healthy."
        Stop-Transcript
        exit 0
    }

    # Report duplicates
    Write-Output "========================================`n"
    Write-Output "WARNING: DUPLICATE PROFILE PATHS DETECTED"
    Write-Output ""
    Write-Output "Found $($duplicates.Count) profile path(s) with multiple SID entries:"
    Write-Output ""

    $duplicateCount = 0
    foreach ($duplicate in $duplicates) {
        $duplicateCount++
        $path = $duplicate.Value[0].Path
        $sids = $duplicate.Value

        Write-Output "[$duplicateCount] Duplicate Path: $path"
        Write-Output "    Number of SIDs pointing to this path: $($sids.Count)"
        Write-Output ""

        foreach ($entry in $sids) {
            Write-Output "    - SID: $($entry.SID)"
            Write-Output "      Registry: $($entry.KeyPath)"

            # Try to get additional profile info
            try {
                $state = (Get-ItemProperty -Path $entry.KeyPath -Name "State" -ErrorAction SilentlyContinue).State
                $stateText = switch ($state) {
                    0 { "Normal" }
                    1 { "Mandatory" }
                    2 { "Backup" }
                    4 { "Temporary" }
                    8 { "Roaming" }
                    default { "Unknown ($state)" }
                }
                Write-Output "      State: $stateText"

                $localPath = (Get-ItemProperty -Path $entry.KeyPath -Name "LocalProfileLoadTimeLow" -ErrorAction SilentlyContinue).LocalProfileLoadTimeLow
                if ($localPath) {
                    Write-Output "      Has been loaded: Yes"
                }

            } catch {
                # Silently continue if we can't get extra info
            }
            Write-Output ""
        }
    }

    Write-Output "========================================`n"
    Write-Output "RECOMMENDATIONS:"
    Write-Output ""
    Write-Output "1. Identify the correct SID for each user account"
    Write-Output "2. Back up the ProfileList registry key before making changes"
    Write-Output "3. Delete or rename the incorrect/duplicate registry entries"
    Write-Output "4. Consider renaming the duplicate profile folder if necessary"
    Write-Output "5. Test user logins after remediation"
    Write-Output ""
    Write-Output "Common Resolution:"
    Write-Output "- Domain accounts: Keep the SID that matches the domain SID"
    Write-Output "- Local accounts: Keep the SID with most recent profile data"
    Write-Output "- .bak profiles: Delete the .bak SID registry entry"
    Write-Output ""

} catch {
    Write-Error "Failed to scan ProfileList registry: $($_.Exception.Message)"
    Stop-Transcript
    exit 1
}

Write-Output "Profile duplicate detection completed."
Write-Output ""

Stop-Transcript
exit 0
