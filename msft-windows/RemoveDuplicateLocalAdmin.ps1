## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
#$profileRegPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
#$logDir = 'C:\Windows\Logs'
#$logFile = Join-Path $logDir 'localuser_profile_cleanup.log'
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "RemoveDuplicateLocalAdmin.log"

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
# Configuration
#$profileRegPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
#$logDir = 'C:\Windows\Logs'
#$logFile = Join-Path $logDir 'profile_cleanup.log'

# Ensure log directory exists
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# Logging helper
function Write-Log {
    param ([string]$message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $message" | Out-File -FilePath $logFile -Append -Encoding UTF8
}

Write-Log "---- Starting local profile cleanup ----"

$profiles = @()

# Collect all user profile entries
Get-ChildItem -Path $profileRegPath | ForEach-Object {
    $sid = $_.PSChildName
    try {
        $props = Get-ItemProperty -Path $_.PSPath
        if ($props.ProfileImagePath -like 'C:\Users\*') {
            $username = Split-Path $props.ProfileImagePath -Leaf
            $profiles += [PSCustomObject]@{
                SID = $sid
                Username = $username
                ProfileImagePath = $props.ProfileImagePath
                RegistryPath = $_.PSPath
            }
        }
    } catch {
        Write-Log "WARNING: Failed to process registry key for SID $sid. $_"
    }
}

# Group profiles by base username
$grouped = $profiles | Group-Object { ($_).Username -replace '\..*$', '' }

foreach ($group in $grouped) {
    $baseUsername = $group.Name
    $userProfiles = $group.Group

    if ($userProfiles.Count -le 1) {
        Write-Log "Only one profile found for $baseUsername — no cleanup needed."
        continue
    }

    Write-Log "Multiple profiles found for $baseUsername:"
    foreach ($profile in $userProfiles) {
        Write-Log "`t$($profile.SID) - $($profile.ProfileImagePath)"
    }

    # Attempt to resolve local account SID only
    try {
        $resolvedSID = (New-Object System.Security.Principal.NTAccount(".\$baseUsername")).Translate([System.Security.Principal.SecurityIdentifier]).Value

        # Ensure it's a true local user SID (starts with S-1-5-21 and NOT domain)
        if ($resolvedSID -notmatch '^S-1-5-21-\d+-\d+-\d+-\d+$') {
            Write-Log "Skipping $baseUsername — resolved SID is not a local user SID: $resolvedSID"
            continue
        }

        Write-Log "Resolved local SID for $baseUsername: $resolvedSID"
    } catch {
        Write-Log "Could not resolve local user SID for $baseUsername. Skipping."
        continue
    }

    foreach ($profile in $userProfiles) {
        if ($profile.SID -ne $resolvedSID) {
            try {
                Remove-Item -Path $profile.RegistryPath -Recurse -Force
                Write-Log "Removed duplicate profile key for SID $($profile.SID) at path $($profile.ProfileImagePath)"
            } catch {
                Write-Log "ERROR: Failed to remove SID $($profile.SID). $_"
            }
        } else {
            Write-Log "Keeping valid local profile SID $($profile.SID)"
        }
    }
}

Write-Log "---- Completed local profile cleanup ----"

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"

Stop-Transcript
