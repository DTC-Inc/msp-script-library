## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
#$profileRegPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
#$localUser = 'dtcadmin'
#$logDir = 'C:\Windows\Logs'
#$logFile = Join-Path $logDir 'dtcadmin_profile_cleanup.log'
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
#$localUser = 'dtcadmin'
#$logDir = 'C:\Windows\Logs'
#$logFile = Join-Path $logDir 'dtcadmin_profile_cleanup.log'

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

Write-Log "---- Starting dtcadmin profile cleanup ----"

try {
    # Resolve the actual SID of the dtcadmin account
    $dtcadminSID = (New-Object System.Security.Principal.NTAccount($localUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    Write-Log "Resolved SID for $localUser: $dtcadminSID"
} catch {
    Write-Log "ERROR: Failed to resolve SID for $localUser. $_"
    exit 1
}

# Find all ProfileList entries pointing to dtcadmin
$matchedProfiles = @()

Get-ChildItem -Path $profileRegPath | ForEach-Object {
    $sid = $_.PSChildName
    try {
        $props = Get-ItemProperty -Path $_.PSPath
        if ($props.ProfileImagePath -like "*\$localUser") {
            $matchedProfiles += [PSCustomObject]@{
                SID = $sid
                ProfileImagePath = $props.ProfileImagePath
                RegistryPath = $_.PSPath
                IsValidSID = ($sid -eq $dtcadminSID)
            }
        }
    } catch {
        Write-Log "WARNING: Failed to process registry key for SID $sid. $_"
    }
}

# Handle profile matches
if ($matchedProfiles.Count -eq 0) {
    Write-Log "No profile keys found for $localUser"
} elseif ($matchedProfiles.Count -eq 1) {
    Write-Log "Only one profile key found for $localUser — no action needed"
} else {
    foreach ($profile in $matchedProfiles) {
        if ($profile.IsValidSID) {
            Write-Log "Keeping valid profile key for SID $($profile.SID)"
        } else {
            try {
                Remove-Item -Path $profile.RegistryPath -Recurse -Force
                Write-Log "Removed duplicate profile key for SID $($profile.SID) at path $($profile.ProfileImagePath)"
            } catch {
                Write-Log "ERROR: Failed to remove SID $($profile.SID). $_"
            }
        }
    }
}

Write-Log "---- Completed dtcadmin profile cleanup ----"

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"

Stop-Transcript
