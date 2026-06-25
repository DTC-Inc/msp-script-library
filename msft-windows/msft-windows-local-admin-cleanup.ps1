## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description   / $env:Description   - Ticket # or initials for audit trail (default: "No Description")
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM
## $inactiveDays  / $env:inactiveDays  - The amount of days a user is inactive before executing removal from the local admins group.
## $exclusionList / $env:exclusionList - List of users to exclude from this script

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description   = $env:Description,
    [string]$RMMScriptPath = $env:RMMScriptPath,
    [string]$inactiveDays  = $env:inactiveDays,
    [string]$exclusionList = $env:exclusionList
)

$ScriptLogName = "msft-windows-local-admin-cleanup.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied.
if (-not $Description) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

# Store the logs in the RMMScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "Inactive days: $inactiveDays"
Write-Host "Users excluded: $exclusionList"

# Define the threshold for inactivity (30 days in this example)
$inactiveThreshold = (Get-Date).AddDays(-$inactiveDays)

# Define an array of usernames to exclude from removal
### exclusionList = @("User1", "User2")  # Replace 'User1', 'User2' with the actual usernames you want to exclude

# Get the Local Administrators group
$localAdminGroup = Get-LocalGroup -Name "Administrators"

# Enumerate all local user accounts
$localUsers = Get-WmiObject -Class Win32_UserAccount -Filter "LocalAccount = True"

foreach ($user in $localUsers) {
    # Check if the user is in the Local Administrators group
    $isMember = Get-LocalGroupMember -Group $localAdminGroup | Where-Object { $_.Name -eq $user.Caption }

    # Check if the user is a local user, not in the exclusion list, and if their last login is older than the inactive threshold
    if ($isMember -and $user.Name -notin $exclusionList -and $user.LastLogin) {
        $lastLoginTime = [Management.ManagementDateTimeConverter]::ToDateTime($user.LastLogin)

        if ($lastLoginTime -lt $inactiveThreshold) {
            try {
                # Attempt to remove the user from the Local Administrators group
                Remove-LocalGroupMember -Group $localAdminGroup -Member $user.Caption -ErrorAction Stop
                Write-Host "Removed inactive local user $($user.Caption) from the Local Administrators group."
            }
            catch {
                Write-Error "Failed to remove $($user.Caption) from the Local Administrators group. Error: $_"
            }
        }
    }
}




Stop-Transcript
