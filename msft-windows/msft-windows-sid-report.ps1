## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
##
## Optional RMM Variables:
## - $Description: Ticket number or initials for tracking (defaults to "Automated SID Report")

# Local Machine SID Reporter
# Writes the local machine SID to extensionAttribute1 on the computer's own AD object.
# This enables centralized duplicate SID detection for cloned/imaged machines
# that were not properly sysprepped.
#
# The local machine SID is NOT the AD objectSid. It is the SID baked into the OS
# during installation. When a machine is cloned without sysprep, multiple machines
# share this SID, which can cause authentication and security issues.
#
# Exit Codes:
# 0 = Success (SID written to AD)
# 1 = Error (not domain-joined, computer not found, permission denied, etc.)

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-sid-report.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        $Description = Read-Host "Please enter the ticket # and, or your initials (press Enter for 'Automated SID Report')"
        if (-not $Description) {
            $Description = "Automated SID Report"
        }
        $ValidInput = 1
    }
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

} else {
    # Store the logs in the RMMScriptPath
    if ($null -ne $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
    }

    if ($null -eq $Description) {
        $Description = "Automated SID Report"
    }
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host ""

# Step 1: Check domain membership
$computerSystem = Get-WmiObject -Class Win32_ComputerSystem
$computerName = $computerSystem.Name
$partOfDomain = $computerSystem.PartOfDomain

Write-Host "Computer Name: $computerName"
Write-Host "Part of Domain: $partOfDomain"
Write-Host ""

if (-not $partOfDomain) {
    Write-Host "[ERROR] This computer is not domain-joined. Cannot write to AD."
    Write-Host "[INFO] Machine SID reporting requires domain membership."
    Stop-Transcript
    exit 1
}

# Step 2: Get the local machine SID
# Query the built-in Administrator account (RID -500) and strip the RID to get the machine SID
try {
    $adminAccount = Get-WmiObject -Class Win32_UserAccount -Filter "LocalAccount = True AND SID LIKE '%-500'"
    if ($null -eq $adminAccount) {
        Write-Host "[ERROR] Could not find built-in Administrator account (SID ending in -500)."
        Write-Host "[INFO] This is unexpected and may indicate a corrupted SAM database."
        Stop-Transcript
        exit 1
    }
    $adminSid = $adminAccount.SID
    $machineSid = $adminSid.Substring(0, $adminSid.LastIndexOf('-'))
    Write-Host "[INFO] Local Machine SID: $machineSid"
    Write-Host "[INFO] Derived from built-in Administrator SID: $adminSid"
    Write-Host ""
} catch {
    Write-Host "[ERROR] Failed to retrieve local machine SID: $($_.Exception.Message)"
    Stop-Transcript
    exit 1
}

# Step 3: Find the computer's own AD object using ADSISearcher
try {
    $searcher = [ADSISearcher]"(&(objectCategory=computer)(cn=$computerName))"
    $searcher.PropertiesToLoad.AddRange(@("distinguishedname", "extensionattribute1"))
    $result = $searcher.FindOne()

    if ($null -eq $result) {
        Write-Host "[ERROR] Computer object '$computerName' not found in Active Directory."
        Write-Host "[INFO] Ensure the computer is properly joined to the domain."
        Stop-Transcript
        exit 1
    }

    Write-Host "[INFO] Found AD computer object: $($result.Properties['distinguishedname'][0])"
} catch {
    Write-Host "[ERROR] LDAP search failed: $($_.Exception.Message)"
    Stop-Transcript
    exit 1
}

# Step 4: Write the machine SID to extensionAttribute1
try {
    $computerObject = $result.GetDirectoryEntry()

    $currentValue = $null
    try {
        $currentValue = $computerObject.extensionAttribute1.Value
    } catch {
        # Attribute may not exist yet, that's fine
    }

    if ($currentValue) {
        Write-Host "[INFO] Current extensionAttribute1 value: $currentValue"
        if ($currentValue -eq $machineSid) {
            Write-Host "[INFO] extensionAttribute1 already contains the correct machine SID. No update needed."
            Stop-Transcript
            exit 0
        }
    } else {
        Write-Host "[INFO] extensionAttribute1 is currently empty."
    }

    $computerObject.Put("extensionAttribute1", $machineSid)
    $computerObject.SetInfo()

    Write-Host "[SUCCESS] Written machine SID '$machineSid' to extensionAttribute1 on AD object."
} catch {
    Write-Host "[ERROR] Failed to write extensionAttribute1: $($_.Exception.Message)"
    Write-Host "[INFO] This may be a permissions issue. The script requires write access to the computer's own AD object."
    Write-Host "[INFO] When running as SYSTEM, the computer account typically has write access to its own attributes."
    Write-Host "[INFO] If running as a user, domain admin or delegated permissions may be required."
    Stop-Transcript
    exit 1
}

# Step 5: Verify the write was successful
try {
    $verifySearcher = [ADSISearcher]"(&(objectCategory=computer)(cn=$computerName))"
    $verifySearcher.PropertiesToLoad.AddRange(@("extensionattribute1"))
    $verifyResult = $verifySearcher.FindOne()
    $verifiedValue = $verifyResult.Properties['extensionattribute1'][0]

    if ($verifiedValue -eq $machineSid) {
        Write-Host "[VERIFIED] extensionAttribute1 confirmed: $verifiedValue"
    } else {
        Write-Host "[WARNING] Verification mismatch. Written: $machineSid, Read back: $verifiedValue"
    }
} catch {
    Write-Host "[WARNING] Could not verify write. The update may still have succeeded: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "============================================"
Write-Host "SID Report Complete"
Write-Host "============================================"

Stop-Transcript
exit 0
