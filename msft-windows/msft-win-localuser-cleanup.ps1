## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# This script disables and removes any pre-staging administrative users from a windows endpoint with a specified age of inactivity in days.
# It also disables any local admin after a specified time period in days. It does not remove other local admins.

# $InstallationUsers needs filled out with comma seperated usernames used from pre-staging/staging. They need removed
# sooner rather than later

# $ExcludedUsers needs a list of comma separated usernames. This is to prevent removing important users.

# $InactivityDays needs set to the amount of days to remove installation users.

# $AdminInactivityDays needs set to the amount of days to remove local admins that aren't part of the installation users list.


# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-win-localuser-cleanup.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        $InstallationUsers = Read-Host "Please enter comma separated usernames of installation users to remove quickly"
        $ExcludedUsers = Read-Host "Please enter the users you wish to exclude from cleanup."
        $InactivityDays = Read-Host "Please enter the amount of days a user needs to be inactive to be disabled"
        $AdminInactivityDays = Read-Host "PLease enter the amount days all admins must be inative before disabling"
        Write-Host "Please note, Installation Users will be deleted after InactivityDays * 
        2"

        $ValidInput = 1
        
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

# Define a comma-separated string of installation users to check
#$InstallationUsers = "installadmin,testuser,backupadmin"

# Define a comma-separated string of excluded users
# $ExcludedUsers = "administrator,superuser"

# Check if the machine is a domain controller
$IsDomainController = Get-CimInstance -ClassName Win32_ComputerSystem | Where-Object { $_.DomainRole -eq 4 -or $_.DomainRole -eq 5 }
if ($IsDomainController) {
    Write-Output "This machine is a Windows Domain Controller. Exiting script."
    Exit 0
}

# Convert the strings into arrays
$UserNames = $InstallationUsers -split ','
$ExcludedUserNames = $ExcludedUsers -split ','

# Define the inactivity period for regular users
#$InactivityDays = 30

# Define the inactivity period for local administrators
# $AdminInactivityDays = 90

# Calculate the cutoff dates for inactivity
$CutoffDate = (Get-Date).AddDays(-$InactivityDays)
$AdminCutoffDate = (Get-Date).AddDays(-$AdminInactivityDays)

# Calculate the deletion threshold (inactivity time * 2 for regular users)
$DeletionThresholdDate = (Get-Date).AddDays(-($InactivityDays * 2))

# Get all members of the Administrators group
$AdminGroupMembers = (Get-LocalGroupMember -Group "Administrators").Name

# Combine all users to process: InstallationUsers + Local Administrators (avoiding duplicates)
$AllUsersToCheck = ($UserNames + $AdminGroupMembers) | Sort-Object -Unique

# Loop through each user in the combined array
foreach ($UserName in $AllUsersToCheck) {
    # Skip excluded users
    if ($ExcludedUserNames -contains $UserName) {
        Write-Output "Skipping excluded user: $UserName"
        continue
    }

    # Skip domain users (users not local)
    if ($UserName -match "\\") {
        Write-Output "Skipping domain user: $UserName"
        continue
    }

    # Skip Azure Active Directory users
    if ($UserName -match "@") {
        Write-Output "Skipping Azure AD user: $UserName"
        continue
    }

    Write-Output "Checking user: $UserName"

    # Check if the user exists and retrieve the local user object
    $User = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue

    if ($User -ne $null) {
        # Check the LastLogon property
        if ($User.LastLogon -ne $null) {
            Write-Output "Last logon time for '$UserName': $($User.LastLogon)"
            $LastLogon = $User.LastLogon
        } else {
            Write-Output "No logon record found for the user '$UserName'. Assuming the account is inactive."
            $LastLogon = $null
        }

        # Check if the user is a member of the Administrators group
        $IsAdmin = $AdminGroupMembers -contains $UserName

        if ($UserNames -contains $UserName) {
            # Always process InstallationUsers for disable and delete logic
            if ($LastLogon -eq $null -or $LastLogon -lt $CutoffDate) {
                # Disable inactive regular users
                if (-not $User.Enabled) {
                    Write-Output "The user '$UserName' is already disabled."
                } else {
                    Write-Output "The user '$UserName' has been inactive for 30+ days. Disabling the account..."
                    Disable-LocalUser -Name $UserName
                    Write-Output "The account '$UserName' has been disabled."
                }

                # Delete the account if disabled for InactivityDays * 2
                if ($User.Enabled -eq $false -and ($LastLogon -eq $null -or $LastLogon -lt $DeletionThresholdDate)) {
                    Write-Output "The user '$UserName' has been disabled for more than $($InactivityDays * 2) days. Deleting the account..."
                    Remove-LocalUser -Name $UserName
                    Write-Output "The account '$UserName' has been deleted."
                }
            } else {
                Write-Output "The user '$UserName' has been active within the last 30 days. No action taken."
            }
        } elseif ($IsAdmin) {
            # Process local administrators (not in InstallationUsers)
            Write-Output "The user '$UserName' is a local administrator."

            # Check if the local administrator is inactive for 90 days
            if ($LastLogon -eq $null -or $LastLogon -lt $AdminCutoffDate) {
                Write-Output "The local administrator '$UserName' has been inactive for 90+ days. Disabling the account..."
                Disable-LocalUser -Name $UserName
                Write-Output "The account '$UserName' has been disabled (Administrators are never deleted)."
            } else {
                Write-Output "The local administrator '$UserName' has been active within the last 90 days. No action taken."
            }
        } else {
            Write-Output "Skipping non-administrator user '$UserName' as it's not in the InstallationUsers list."
        }
    } else {
        Write-Output "The user '$UserName' does not exist on this system."
    }
}


Stop-Transcript
