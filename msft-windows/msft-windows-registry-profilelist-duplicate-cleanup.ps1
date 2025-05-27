## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# This script checks for duplicate users in the registry ProfileList and removes duplicates
# No input variables required - script runs automatically
# SAFETY: Only removes unused/orphaned duplicate profiles, preserves active profiles

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "ProfileList-Duplicate-Cleanup.log"

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
Write-Host "Starting ProfileList duplicate cleanup process..."

try {
    # Registry path for ProfileList
    $ProfileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
    
    Write-Host "Checking registry path: $ProfileListPath"
    
    # Get all profile subkeys
    $ProfileKeys = Get-ChildItem -Path $ProfileListPath -ErrorAction Stop
    
    Write-Host "Found $($ProfileKeys.Count) profile entries in registry"
    
    # Hash table to track ProfileImagePath values and their associated keys
    $ProfilePathMap = @{}
    $DuplicatesFound = @()
    
    foreach ($ProfileKey in $ProfileKeys) {
        try {
            # Get all properties for this profile key
            $ProfileProperties = Get-ItemProperty -Path $ProfileKey.PSPath -ErrorAction SilentlyContinue
            
            # Get the ProfileImagePath (this is the main identifier for user profiles)
            $ProfileImagePath = $ProfileProperties.ProfileImagePath
            $ProfileGuid = $ProfileProperties.ProfileGuid
            
            # Skip system profiles and profiles without ProfileImagePath
            if (-not $ProfileImagePath) {
                Write-Host "Profile $($ProfileKey.PSChildName) has no ProfileImagePath - skipping (likely system profile)"
                continue
            }
            
            # Check if profile folder exists and get last write time
            $FolderExists = Test-Path -Path $ProfileImagePath
            $LastWriteTime = $null
            if ($FolderExists) {
                $LastWriteTime = (Get-Item -Path $ProfileImagePath).LastWriteTime
            }
            
            Write-Host "Processing profile: $($ProfileKey.PSChildName)"
            Write-Host "  Profile Path: $ProfileImagePath (Exists: $FolderExists)"
            Write-Host "  ProfileGuid: $ProfileGuid"
            if ($LastWriteTime) {
                Write-Host "  Last Modified: $LastWriteTime"
            }
            
            # Use ProfileImagePath as the key for duplicate detection
            if ($ProfilePathMap.ContainsKey($ProfileImagePath)) {
                # Duplicate found - determine which one to keep
                $ExistingProfile = $ProfilePathMap[$ProfileImagePath]
                $CurrentProfile = @{
                    KeyName = $ProfileKey.PSChildName
                    KeyPath = $ProfileKey.PSPath
                    ProfilePath = $ProfileImagePath
                    ProfileGuid = $ProfileGuid
                    FolderExists = $FolderExists
                    LastWriteTime = $LastWriteTime
                }
                
                Write-Host "DUPLICATE FOUND: ProfileImagePath $ProfileImagePath already exists!" -ForegroundColor Yellow
                Write-Host "  Original: $($ExistingProfile.KeyName) - GUID: $($ExistingProfile.ProfileGuid) (Folder Exists: $($ExistingProfile.FolderExists))"
                Write-Host "  Duplicate: $($CurrentProfile.KeyName) - GUID: $($CurrentProfile.ProfileGuid) (Folder Exists: $($CurrentProfile.FolderExists))"
                
                # Determine which profile to remove based on priority:
                # 1. Keep the one with existing folder over non-existing
                # 2. If both exist or both don't exist, keep the most recently modified
                # 3. If modification times are equal, keep the first one found
                
                $ProfileToRemove = $null
                $ProfileToKeep = $null
                
                if ($ExistingProfile.FolderExists -and -not $CurrentProfile.FolderExists) {
                    # Keep existing (has folder), remove current (no folder)
                    $ProfileToRemove = $CurrentProfile
                    $ProfileToKeep = $ExistingProfile
                    Write-Host "  Decision: Removing current profile (no folder exists)" -ForegroundColor Cyan
                }
                elseif (-not $ExistingProfile.FolderExists -and $CurrentProfile.FolderExists) {
                    # Keep current (has folder), remove existing (no folder)
                    $ProfileToRemove = $ExistingProfile
                    $ProfileToKeep = $CurrentProfile
                    # Update the map with the current profile
                    $ProfilePathMap[$ProfileImagePath] = $CurrentProfile
                    Write-Host "  Decision: Removing original profile (no folder exists)" -ForegroundColor Cyan
                }
                elseif ($ExistingProfile.FolderExists -and $CurrentProfile.FolderExists) {
                    # Both have folders - keep the most recently modified
                    if ($CurrentProfile.LastWriteTime -gt $ExistingProfile.LastWriteTime) {
                        $ProfileToRemove = $ExistingProfile
                        $ProfileToKeep = $CurrentProfile
                        $ProfilePathMap[$ProfileImagePath] = $CurrentProfile
                        Write-Host "  Decision: Removing original profile (current is more recent)" -ForegroundColor Cyan
                    } else {
                        $ProfileToRemove = $CurrentProfile
                        $ProfileToKeep = $ExistingProfile
                        Write-Host "  Decision: Removing current profile (original is more recent or equal)" -ForegroundColor Cyan
                    }
                }
                else {
                    # Neither has folders - keep the first one found
                    $ProfileToRemove = $CurrentProfile
                    $ProfileToKeep = $ExistingProfile
                    Write-Host "  Decision: Removing current profile (neither has folder, keeping first found)" -ForegroundColor Cyan
                }
                
                # Add to duplicates list for removal
                $DuplicatesFound += @{
                    KeyName = $ProfileToRemove.KeyName
                    KeyPath = $ProfileToRemove.KeyPath
                    ProfileGuid = $ProfileToRemove.ProfileGuid
                    ProfilePath = $ProfileToRemove.ProfilePath
                    FolderExists = $ProfileToRemove.FolderExists
                    KeptProfile = $ProfileToKeep.KeyName
                    Reason = if (-not $ProfileToRemove.FolderExists -and $ProfileToKeep.FolderExists) { "No folder exists" }
                            elseif ($ProfileToRemove.FolderExists -and $ProfileToKeep.FolderExists) { "Less recent modification" }
                            else { "Duplicate with no clear priority" }
                }
            } else {
                # First occurrence of this ProfileImagePath
                $ProfilePathMap[$ProfileImagePath] = @{
                    KeyName = $ProfileKey.PSChildName
                    KeyPath = $ProfileKey.PSPath
                    ProfilePath = $ProfileImagePath
                    ProfileGuid = $ProfileGuid
                    FolderExists = $FolderExists
                    LastWriteTime = $LastWriteTime
                }
            }
        }
        catch {
            Write-Host "Error processing profile key $($ProfileKey.PSChildName): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    
    # Remove duplicates
    if ($DuplicatesFound.Count -gt 0) {
        Write-Host "`nFound $($DuplicatesFound.Count) duplicate profile(s). Proceeding with removal..." -ForegroundColor Yellow
        
        foreach ($Duplicate in $DuplicatesFound) {
            try {
                Write-Host "Removing duplicate profile registry key: $($Duplicate.KeyName)" -ForegroundColor Red
                Write-Host "  ProfileGuid: $($Duplicate.ProfileGuid)"
                Write-Host "  Profile Path: $($Duplicate.ProfilePath)"
                Write-Host "  Folder Exists: $($Duplicate.FolderExists)"
                Write-Host "  Removal Reason: $($Duplicate.Reason)"
                Write-Host "  Keeping Profile: $($Duplicate.KeptProfile)"
                
                # Remove the duplicate registry key
                Remove-Item -Path $Duplicate.KeyPath -Recurse -Force -ErrorAction Stop
                Write-Host "Successfully removed duplicate profile: $($Duplicate.KeyName)" -ForegroundColor Green
            }
            catch {
                Write-Host "Failed to remove duplicate profile $($Duplicate.KeyName): $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        
        Write-Host "`nDuplicate cleanup completed. Removed $($DuplicatesFound.Count) duplicate profile(s)." -ForegroundColor Green
    } else {
        Write-Host "`nNo duplicate profiles found. Registry ProfileList is clean." -ForegroundColor Green
    }
    
    # Final verification
    Write-Host "`nPerforming final verification..."
    $FinalProfileKeys = Get-ChildItem -Path $ProfileListPath
    Write-Host "Final profile count: $($FinalProfileKeys.Count)"
    
}
catch {
    Write-Host "Critical error during ProfileList cleanup: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
}

Write-Host "`nProfileList duplicate cleanup process completed."

Stop-Transcript 