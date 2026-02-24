## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
##
## Optional RMM Variables:
## - $Description: Ticket number or initials for tracking (defaults to "Automated Duplicate SID Scan")
## - $SearchBase: LDAP path to limit search scope (e.g., "OU=Workstations,DC=contoso,DC=com")

# Duplicate Local Machine SID Detector
# Queries all AD computer objects with extensionAttribute1 populated (written by msft-windows-sid-report.ps1),
# groups by SID, and reports any duplicates. Duplicate local machine SIDs indicate machines that were
# cloned/imaged without running sysprep.
#
# Prerequisites:
# - msft-windows-sid-report.ps1 must have run on workstations first to populate extensionAttribute1
# - Run this script on a Domain Controller or domain-joined admin workstation
# - Account running the script needs read access to computer objects in AD
#
# Exit Codes:
# 0 = Success, no duplicates found
# 1 = Success, duplicates found (non-zero to trigger RMM alerting)
# 2 = Error (not domain-joined, LDAP query failed, etc.)

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-sid-detect-duplicates.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        $Description = Read-Host "Please enter the ticket # and, or your initials (press Enter for 'Automated Duplicate SID Scan')"
        if (-not $Description) {
            $Description = "Automated Duplicate SID Scan"
        }

        $SearchBase = Read-Host "Enter LDAP search base to limit scope (press Enter to search entire domain)"

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
        $Description = "Automated Duplicate SID Scan"
    }
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host "Search Base: $(if ($SearchBase) { $SearchBase } else { '(entire domain)' })"
Write-Host ""

# Step 1: Check domain membership
$computerSystem = Get-WmiObject -Class Win32_ComputerSystem
$partOfDomain = $computerSystem.PartOfDomain

Write-Host "Running on: $($computerSystem.Name)"
Write-Host "Part of Domain: $partOfDomain"
Write-Host ""

if (-not $partOfDomain) {
    Write-Host "[ERROR] This computer is not domain-joined. Cannot query AD."
    Stop-Transcript
    exit 2
}

# Step 2: Query all computers with extensionAttribute1 populated
try {
    $searcher = [ADSISearcher]"(&(objectCategory=computer)(extensionAttribute1=*))"
    $searcher.PageSize = 1000
    $searcher.PropertiesToLoad.AddRange(@("cn", "extensionattribute1", "distinguishedname"))

    if (-not [string]::IsNullOrWhiteSpace($SearchBase)) {
        try {
            $searcher.SearchRoot = [ADSI]"LDAP://$SearchBase"
            Write-Host "[INFO] Search scope limited to: $SearchBase"
        } catch {
            Write-Host "[ERROR] Invalid SearchBase '$SearchBase': $($_.Exception.Message)"
            Stop-Transcript
            exit 2
        }
    }

    $results = $searcher.FindAll()
    $resultCount = $results.Count
    Write-Host "[INFO] Found $resultCount computer(s) with extensionAttribute1 populated."
    Write-Host ""
} catch {
    Write-Host "[ERROR] LDAP search failed: $($_.Exception.Message)"
    Stop-Transcript
    exit 2
}

if ($resultCount -eq 0) {
    Write-Host "[INFO] No computers have extensionAttribute1 populated."
    Write-Host "[INFO] Ensure msft-windows-sid-report.ps1 has been deployed and run on workstations first."

    # RMM Custom Field Output
    Write-Host ""
    Write-Host "============================================"
    Write-Host "RMM CUSTOM FIELD VALUES"
    Write-Host "============================================"
    Write-Host "DUPSID_FOUND: False"
    Write-Host "DUPSID_COUNT: 0"
    Write-Host "DUPSID_AFFECTED: 0"
    Write-Host "DUPSID_SCANNED: 0"
    Write-Host "DUPSID_DETAILS: No computers reporting SID data yet"
    Write-Host "DUPSID_SUMMARY: No computers reporting SID data - deploy sid-report script first"
    Write-Host "DUPSID_SCANDATE: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Host "============================================"

    $results.Dispose()
    Stop-Transcript
    exit 0
}

# Step 3: Build SID-to-computer mapping
$sidMap = @{}
$totalComputers = 0

foreach ($result in $results) {
    $cn = $result.Properties['cn'][0]
    $sid = $result.Properties['extensionattribute1'][0]
    $dn = $result.Properties['distinguishedname'][0]

    if ([string]::IsNullOrWhiteSpace($sid)) {
        continue
    }

    $totalComputers++

    $entry = [PSCustomObject]@{
        Name = $cn
        DN   = $dn
    }

    if ($sidMap.ContainsKey($sid)) {
        $sidMap[$sid] += $entry
    } else {
        $sidMap[$sid] = @($entry)
    }
}

# Clean up COM objects from FindAll()
$results.Dispose()

Write-Host "[INFO] Processed $totalComputers computer(s) with valid SID data."
Write-Host "[INFO] Unique SIDs: $($sidMap.Count)"
Write-Host ""

# Step 4: Identify duplicates
$duplicates = @($sidMap.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })
$duplicateCount = $duplicates.Count
$affectedMachines = 0
foreach ($dup in $duplicates) {
    $affectedMachines += $dup.Value.Count
}
$duplicateFound = $duplicateCount -gt 0

Write-Host "============================================"
Write-Host "DUPLICATE SID SCAN RESULTS"
Write-Host "============================================"
Write-Host ""
Write-Host "Total computers scanned: $totalComputers"
Write-Host "Unique SIDs: $($sidMap.Count)"
Write-Host "Duplicate SID groups: $duplicateCount"
Write-Host "Affected machines: $affectedMachines"
Write-Host ""

# Step 5: Detailed output of duplicates
if ($duplicateFound) {
    Write-Host "[WARNING] DUPLICATE SIDs DETECTED!"
    Write-Host ""

    $groupIndex = 0
    foreach ($entry in $duplicates) {
        $groupIndex++
        $sid = $entry.Key
        $computers = $entry.Value

        Write-Host "--- Duplicate Group $groupIndex ---"
        Write-Host "  SID: $sid"
        Write-Host "  Affected Computers ($($computers.Count)):"
        foreach ($computer in $computers) {
            Write-Host "    - $($computer.Name)"
            Write-Host "      DN: $($computer.DN)"
        }
        Write-Host ""
    }

    Write-Host "[ACTION REQUIRED] These machines were likely cloned or imaged without running sysprep."
    Write-Host "[ACTION REQUIRED] Run 'sysprep /generalize' or use New-SID on affected machines to generate unique SIDs."
    Write-Host ""
} else {
    Write-Host "[OK] No duplicate SIDs detected. All $totalComputers machines have unique local machine SIDs."
    Write-Host ""
}

# Step 6: RMM Custom Field Output
# Build details string for RMM
$detailsParts = @()
foreach ($entry in $duplicates) {
    $sid = $entry.Key
    $names = ($entry.Value | ForEach-Object { $_.Name }) -join ", "
    $detailsParts += "${sid}: $names"
}
$detailsString = $detailsParts -join " | "
if ([string]::IsNullOrEmpty($detailsString)) {
    $detailsString = "None"
}
if ($detailsString.Length -gt 190) {
    $detailsString = $detailsString.Substring(0, 187) + "..."
}

# Build short summary
if ($duplicateFound) {
    $summaryText = "$duplicateCount dup SID group(s) affecting $affectedMachines machine(s) - remediation required"
} else {
    $summaryText = "No duplicate SIDs found across $totalComputers computer(s)"
}
if ($summaryText.Length -gt 190) {
    $summaryText = $summaryText.Substring(0, 187) + "..."
}

$scanDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

Write-Host "============================================"
Write-Host "RMM CUSTOM FIELD VALUES"
Write-Host "============================================"
Write-Host "DUPSID_FOUND: $duplicateFound"
Write-Host "DUPSID_COUNT: $duplicateCount"
Write-Host "DUPSID_AFFECTED: $affectedMachines"
Write-Host "DUPSID_SCANNED: $totalComputers"
Write-Host "DUPSID_DETAILS: $detailsString"
Write-Host "DUPSID_SUMMARY: $summaryText"
Write-Host "DUPSID_SCANDATE: $scanDate"
Write-Host "============================================"
Write-Host ""

# NinjaRMM specific (uncomment and modify for your RMM):
# Ninja-Property-Set dupSidFound $duplicateFound
# Ninja-Property-Set dupSidCount $duplicateCount
# Ninja-Property-Set dupSidSummary $summaryText

Stop-Transcript

if ($duplicateFound) {
    exit 1
} else {
    exit 0
}
