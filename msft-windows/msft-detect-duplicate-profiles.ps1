## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $RMM
## $deleteOldest - Set to 1 to automatically delete the oldest duplicate profile registry entry (default: 0, detection only)

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

    # Set default value for deleteOldest in interactive mode
    if ([string]::IsNullOrEmpty($deleteOldest)) {
        $deleteOldest = 0
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

    # Set default value for deleteOldest if not provided by RMM
    if ([string]::IsNullOrEmpty($deleteOldest)) {
        $deleteOldest = 0
    }
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host "Delete Oldest: $deleteOldest"

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
    $deletedCount = 0

    foreach ($duplicate in $duplicates) {
        $duplicateCount++
        $path = $duplicate.Value[0].Path
        $sids = $duplicate.Value

        Write-Output "[$duplicateCount] Duplicate Path: $path"
        Write-Output "    Number of SIDs pointing to this path: $($sids.Count)"
        Write-Output ""

        # Determine which profile is oldest if deletion is enabled
        $oldestEntry = $null
        $oldestTimestamp = $null

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

                # Get last load time to determine oldest
                $loadTimeLow = (Get-ItemProperty -Path $entry.KeyPath -Name "LocalProfileLoadTimeLow" -ErrorAction SilentlyContinue).LocalProfileLoadTimeLow
                $loadTimeHigh = (Get-ItemProperty -Path $entry.KeyPath -Name "LocalProfileLoadTimeHigh" -ErrorAction SilentlyContinue).LocalProfileLoadTimeHigh

                if ($loadTimeLow -or $loadTimeHigh) {
                    Write-Output "      Has been loaded: Yes"

                    # Combine high and low DWORD to get 64-bit timestamp
                    if ($loadTimeHigh -and $loadTimeLow) {
                        $timestamp = ([Int64]$loadTimeHigh -shl 32) -bor $loadTimeLow
                        Write-Output "      Load timestamp: $timestamp"

                        # Track oldest for potential deletion
                        if ($deleteOldest -eq 1) {
                            if ($null -eq $oldestTimestamp -or $timestamp -lt $oldestTimestamp) {
                                $oldestTimestamp = $timestamp
                                $oldestEntry = $entry
                            }
                        }
                    }
                } else {
                    Write-Output "      Has been loaded: No (or no timestamp)"

                    # If no load time, consider it oldest (never loaded)
                    if ($deleteOldest -eq 1 -and $null -eq $oldestEntry) {
                        $oldestEntry = $entry
                    }
                }

            } catch {
                # Silently continue if we can't get extra info
            }
            Write-Output ""
        }

        # Delete the oldest duplicate if enabled
        if ($deleteOldest -eq 1 -and $oldestEntry) {
            Write-Output "    ACTION: Deleting oldest duplicate profile registry entry..."
            Write-Output "    Target SID: $($oldestEntry.SID)"
            Write-Output "    Registry: $($oldestEntry.KeyPath)"

            try {
                # Backup registry key to a .reg file before deletion
                $backupPath = "$env:TEMP\ProfileList_Backup_$($oldestEntry.SID)_$(Get-Date -Format 'yyyyMMdd_HHmmss').reg"
                Write-Output "    Creating backup: $backupPath"

                $regPath = $oldestEntry.KeyPath -replace "Microsoft.PowerShell.Core\\Registry::", ""
                $exportResult = reg export "$regPath" "$backupPath" 2>&1

                if ($LASTEXITCODE -eq 0) {
                    Write-Output "    Backup created successfully."

                    # Delete the registry key
                    Write-Output "    Deleting registry key..."
                    Remove-Item -Path $oldestEntry.KeyPath -Recurse -Force -ErrorAction Stop
                    Write-Output "    SUCCESS: Registry key deleted."
                    $deletedCount++

                } else {
                    Write-Warning "    Failed to backup registry key. Skipping deletion for safety."
                    Write-Output "    Export error: $exportResult"
                }

            } catch {
                Write-Warning "    Failed to delete registry key: $($_.Exception.Message)"
            }
            Write-Output ""
        }
    }

    Write-Output "========================================`n"

    if ($deleteOldest -eq 1) {
        Write-Output "DELETION SUMMARY:"
        Write-Output ""
        Write-Output "Deleted $deletedCount duplicate profile registry entries."
        Write-Output "Registry backups saved to: $env:TEMP\ProfileList_Backup_*.reg"
        Write-Output ""
        Write-Output "NEXT STEPS:"
        Write-Output "1. Verify user can log in successfully"
        Write-Output "2. Check that the correct profile is being loaded"
        Write-Output "3. If issues occur, restore from backup .reg file"
        Write-Output "4. Consider deleting orphaned profile folders if they exist"
        Write-Output ""
    } else {
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
        Write-Output "AUTOMATIC DELETION:"
        Write-Output "To automatically delete the oldest duplicate, run with:"
        Write-Output "`$deleteOldest = 1"
        Write-Output ""
    }

} catch {
    Write-Error "Failed to scan ProfileList registry: $($_.Exception.Message)"
    Stop-Transcript
    exit 1
}

Write-Output "Profile duplicate detection completed."
Write-Output ""

Stop-Transcript
exit 0
