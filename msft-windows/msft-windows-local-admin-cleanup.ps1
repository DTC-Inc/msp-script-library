### *** LIST OF VARIALBES REQUIRED FOR UN *** ##
#### * SET IN RMM OR RUN INTERACTIVELY * ####
# $exclusionList = list of users to exclude from this script
# $inactiveDays = The amount of days a user is inactive before executing removal from the local admins group.
#
#
#

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-local-admin-cleanup.log"

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

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host "InactivedDays: $inactiveDays"
Write-Host "Users excluded: $exclusionList"

# Define the threshold for inactivity (30 days in this example)
$inactiveThreshold = (Get-Date).AddDays(-$inactiveDays)

# Define an array of usernames to exclude from removal
# $exclusionList = @("User1", "User2")  # Replace 'User1', 'User2' with the actual usernames you want to exclude

# Get the Local Administrators group
$localAdminGroup = Get-LocalGroup -Name "Administrators"

# Enumerate all members of the Local Administrators group
$groupMembers = Get-LocalGroupMember -Group $localAdminGroup

foreach ($member in $groupMembers) {
    # Check if the member is a local user and not in the exclusion list
    if ($member.ObjectClass -eq 'User' -and $member.PrincipalSource -eq 'Local' -and $member.Name -notin $exclusionList) {
        # Build the path to the user's NTUSER.DAT file
        $ntuserDatPath = Join-Path -Path (Get-WmiObject -Class Win32_UserProfile | Where-Object { $_.LocalPath -like "*\$($member.Name)" }).LocalPath -ChildPath "NTUSER.DAT"

        if (Test-Path $ntuserDatPath) {
            $ntuserDatLastWrite = (Get-Item $ntuserDatPath).LastWriteTime

            # Check if the last write time of NTUSER.DAT is older than the inactive threshold
            if ($ntuserDatLastWrite -lt $inactiveThreshold) {
                try {
                    # Attempt to remove the local user from the Local Administrators group
                    Remove-LocalGroupMember -Group $localAdminGroup -Member $member.Name -ErrorAction Stop
                    Write-Host "Removed inactive local user $($member.Name) from the Local Administrators group."
                }
                catch {
                    Write-Error "Failed to remove $($member.Name) from the Local Administrators group. Error: $_"
                }
            }
        }
    }
}



Stop-Transcript
