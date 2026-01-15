## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $RMM
## $Description

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "app-dentrix-configure-qos.log"

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
    Configures Windows QoS policies for Dentrix ACE Server to prioritize dental application traffic.

.DESCRIPTION
    Detects if Dentrix is installed on the system and applies Network Quality of Service (QoS)
    policies to prioritize Dentrix ACE Server communication ports. This ensures reliable and
    responsive performance for dental practice management software.

    QoS Policies Applied:
    - Dentrix-ACE-Primary: Port 6597 (TCP) - DSCP 46 (Expedited Forwarding)
    - Dentrix-ACE-Secondary: Port 5712 (TCP) - DSCP 46 (Expedited Forwarding)
    - Dentrix-Module-Ports: Ports 6602-6606, 6610 (TCP) - DSCP 46 (Expedited Forwarding)

    DSCP 46 (EF - Expedited Forwarding) provides highest priority for low-latency traffic.

.NOTES
    Author: Nathaniel Smith / Claude Code
    Date: 2025-11-10

    Prerequisites:
    - Requires Administrator privileges
    - Dentrix must be installed (script auto-detects)
    - Network infrastructure must support QoS/DSCP tagging for effectiveness

    Detection Method:
    - Checks registry: HKLM:\SOFTWARE\WOW6432Node\Dentrix (32-bit on 64-bit)
    - Checks registry: HKLM:\SOFTWARE\Dentrix (64-bit)
    - Checks file path: C:\Program Files (x86)\Dentrix\

    Idempotent: Script can be run multiple times safely. Existing policies are skipped.
#>

### ————— CHECK ELEVATION —————
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    Stop-Transcript
    exit 1
}

### ————— DETECT DENTRIX INSTALLATION —————
Write-Output "`n========================================"
Write-Output "Dentrix QoS Configuration"
Write-Output "========================================`n"

Write-Output "Detecting Dentrix installation..."

$dentrixInstalled = $false
$dentrixPath = $null

# Check registry (32-bit app on 64-bit Windows)
$registryPath32 = "HKLM:\SOFTWARE\WOW6432Node\Dentrix"
if (Test-Path -Path $registryPath32) {
    Write-Output "  [✓] Found Dentrix registry key: $registryPath32"
    $dentrixInstalled = $true
    try {
        $installPath = Get-ItemProperty -Path $registryPath32 -Name "InstallPath" -ErrorAction SilentlyContinue
        if ($installPath) {
            $dentrixPath = $installPath.InstallPath
            Write-Output "  [✓] Install path: $dentrixPath"
        }
    } catch {
        Write-Output "  [i] Could not read InstallPath from registry"
    }
}

# Check registry (64-bit native)
$registryPath64 = "HKLM:\SOFTWARE\Dentrix"
if (Test-Path -Path $registryPath64) {
    Write-Output "  [✓] Found Dentrix registry key: $registryPath64"
    $dentrixInstalled = $true
    if (-not $dentrixPath) {
        try {
            $installPath = Get-ItemProperty -Path $registryPath64 -Name "InstallPath" -ErrorAction SilentlyContinue
            if ($installPath) {
                $dentrixPath = $installPath.InstallPath
                Write-Output "  [✓] Install path: $dentrixPath"
            }
        } catch {
            Write-Output "  [i] Could not read InstallPath from registry"
        }
    }
}

# Check common installation path
$commonPath = "C:\Program Files (x86)\Dentrix\"
if (Test-Path -Path $commonPath) {
    Write-Output "  [✓] Found Dentrix installation directory: $commonPath"
    $dentrixInstalled = $true
    if (-not $dentrixPath) {
        $dentrixPath = $commonPath
    }
}

# Alternative 64-bit path (less common)
$altPath = "C:\Program Files\Dentrix\"
if (Test-Path -Path $altPath) {
    Write-Output "  [✓] Found Dentrix installation directory: $altPath"
    $dentrixInstalled = $true
    if (-not $dentrixPath) {
        $dentrixPath = $altPath
    }
}

if (-not $dentrixInstalled) {
    Write-Output "`n[!] Dentrix installation not detected on this system."
    Write-Output ""
    Write-Output "This script requires Dentrix to be installed."
    Write-Output "If Dentrix is installed in a non-standard location, manual QoS configuration may be needed."
    Write-Output ""
    Stop-Transcript
    exit 0
}

Write-Output "`n[✓] Dentrix detected. Proceeding with QoS policy configuration...`n"

### ————— DEFINE QOS POLICIES —————
$qosPolicies = @(
    @{
        Name = "Dentrix-ACE-Primary"
        Description = "Dentrix ACE Server primary communication port"
        Ports = @(6597)
        DSCP = 46
    },
    @{
        Name = "Dentrix-ACE-Secondary"
        Description = "Dentrix ACE Server secondary communication port"
        Ports = @(5712)
        DSCP = 46
    },
    @{
        Name = "Dentrix-Module-Ports"
        Description = "Dentrix module communication ports"
        Ports = @(6602, 6603, 6604, 6605, 6606, 6610)
        DSCP = 46
    }
)

### ————— APPLY QOS POLICIES —————
$policiesCreated = 0
$policiesSkipped = 0
$policiesFailed = 0

foreach ($policy in $qosPolicies) {
    Write-Output "Processing: $($policy.Name)"
    Write-Output "  Description: $($policy.Description)"
    Write-Output "  Ports: $($policy.Ports -join ', ')"
    Write-Output "  DSCP: $($policy.DSCP) (Expedited Forwarding)"

    # Check if policy already exists
    $existingPolicy = Get-NetQosPolicy -Name $policy.Name -ErrorAction SilentlyContinue

    if ($existingPolicy) {
        Write-Output "  [→] Policy already exists. Skipping."
        $policiesSkipped++
    } else {
        try {
            # Create the QoS policy
            $newPolicy = New-NetQosPolicy -Name $policy.Name `
                                          -IPProtocol TCP `
                                          -IPDstPortMatchCondition $policy.Ports `
                                          -DSCPAction $policy.DSCP `
                                          -NetworkProfile All `
                                          -ErrorAction Stop

            Write-Output "  [✓] Policy created successfully."
            $policiesCreated++

        } catch {
            Write-Error "  [✗] Failed to create policy: $($_.Exception.Message)"
            $policiesFailed++
        }
    }
    Write-Output ""
}

### ————— SUMMARY —————
Write-Output "========================================"
Write-Output "QoS Configuration Summary"
Write-Output "========================================`n"

Write-Output "Dentrix Location: $dentrixPath"
Write-Output ""
Write-Output "Policies Created: $policiesCreated"
Write-Output "Policies Skipped (already exist): $policiesSkipped"
Write-Output "Policies Failed: $policiesFailed"
Write-Output ""

if ($policiesCreated -gt 0) {
    Write-Output "[✓] QoS policies have been applied successfully."
    Write-Output ""
    Write-Output "IMPORTANT NOTES:"
    Write-Output "  • Policies are active immediately (no reboot required)"
    Write-Output "  • DSCP 46 (EF) provides highest priority for these ports"
    Write-Output "  • Network switches/routers must support QoS for full effect"
    Write-Output "  • Verify network infrastructure honors DSCP markings"
    Write-Output ""
    Write-Output "To verify policies:"
    Write-Output "  Get-NetQosPolicy | Where-Object {`$_.Name -like 'Dentrix*'}"
    Write-Output ""
} elseif ($policiesSkipped -gt 0 -and $policiesFailed -eq 0) {
    Write-Output "[✓] All Dentrix QoS policies are already configured."
    Write-Output ""
} else {
    Write-Output "[!] Some policies failed to apply. Review errors above."
    Write-Output ""
}

### ————— DISPLAY CURRENT POLICIES —————
Write-Output "Current Dentrix QoS Policies:"
Write-Output "----------------------------------------"
$currentPolicies = Get-NetQosPolicy | Where-Object { $_.Name -like "Dentrix*" }
if ($currentPolicies) {
    foreach ($cp in $currentPolicies) {
        Write-Output "Name: $($cp.Name)"
        Write-Output "  Protocol: $($cp.IPProtocol)"
        Write-Output "  Destination Ports: $($cp.IPDstPortMatchCondition)"
        Write-Output "  DSCP Action: $($cp.DSCPAction)"
        Write-Output "  Network Profile: $($cp.NetworkProfile)"
        Write-Output ""
    }
} else {
    Write-Output "  [i] No Dentrix policies found."
}

Write-Output "========================================`n"

Stop-Transcript

# Exit with appropriate code
if ($policiesFailed -gt 0) {
    exit 1
} else {
    exit 0
}
