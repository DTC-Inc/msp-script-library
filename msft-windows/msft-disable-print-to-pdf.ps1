## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $RMM

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-disable-print-to-pdf.log"

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
    Disables Microsoft Print to PDF feature to resolve Windows 11 upgrade compatibility issues.

.DESCRIPTION
    Removes the Microsoft Print to PDF Windows optional feature which is a known blocker
    for Windows 11 upgrades. This script disables the feature without forcing an immediate
    reboot, but a reboot is REQUIRED before starting the Windows 11 upgrade.

    Known Issues:
    - Microsoft Print to PDF drivers can cause Windows 11 upgrade failures
    - Compatibility scan detects Print to PDF as blocker
    - Feature must be fully removed (requires reboot) before upgrade attempt

.NOTES
    Author: Nathaniel Smith / Claude Code
    IMPORTANT: System MUST be rebooted after running this script before attempting upgrade.

    Feature Names:
    - Printing-PrintToPDFServices-Features (Print to PDF)

    Workflow for Windows 11 Upgrade:
    1. Run this script to disable Print to PDF
    2. REBOOT the system
    3. Run Windows 11 upgrade script
#>

### ————— CHECK ELEVATION —————
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    Stop-Transcript
    exit 1
}

### ————— DETECT PRINT TO PDF FEATURE STATE —————
Write-Output "`n========================================"
Write-Output "Microsoft Print to PDF Removal"
Write-Output "========================================`n"

$featureName = "Printing-PrintToPDFServices-Features"

Write-Output "Checking Print to PDF feature status..."

try {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction Stop

    Write-Output "Feature Name: $($feature.FeatureName)"
    Write-Output "Display Name: $($feature.DisplayName)"
    Write-Output "Current State: $($feature.State)"
    Write-Output ""

    if ($feature.State -eq "Disabled") {
        Write-Output "RESULT: Microsoft Print to PDF is already disabled."
        Write-Output ""
        Write-Output "IMPORTANT: If this system has not been rebooted since disabling,"
        Write-Output "a reboot is still required before attempting Windows 11 upgrade."
        Write-Output "The drivers remain loaded in memory until reboot."
        Write-Output ""
        Stop-Transcript
        exit 0
    }

    if ($feature.State -eq "DisablePending") {
        Write-Output "RESULT: Microsoft Print to PDF is pending removal."
        Write-Output ""
        Write-Output "CRITICAL: System MUST be rebooted to complete removal."
        Write-Output "Do NOT attempt Windows 11 upgrade until after reboot."
        Write-Output "The feature is not fully removed until reboot completes."
        Write-Output ""
        Stop-Transcript
        exit 0
    }

} catch {
    Write-Error "Failed to query Windows optional feature: $($_.Exception.Message)"
    Stop-Transcript
    exit 1
}

### ————— DISABLE PRINT TO PDF —————
Write-Output "Disabling Microsoft Print to PDF feature..."
Write-Output "This may take a few minutes..."
Write-Output ""

try {
    # Disable the feature without forcing immediate reboot
    $result = Disable-WindowsOptionalFeature -Online -FeatureName $featureName -NoRestart -ErrorAction Stop

    if ($result.RestartNeeded) {
        Write-Output "========================================`n"
        Write-Output "SUCCESS: Microsoft Print to PDF has been disabled."
        Write-Output ""
        Write-Output "CRITICAL - REBOOT REQUIRED:"
        Write-Output ""
        Write-Output "The feature has been disabled but is NOT fully removed until reboot."
        Write-Output "Print to PDF drivers are still loaded in memory."
        Write-Output ""
        Write-Output "BEFORE attempting Windows 11 upgrade:"
        Write-Output "  1. Reboot this system"
        Write-Output "  2. Verify feature is fully disabled (run this script again)"
        Write-Output "  3. Then proceed with Windows 11 upgrade"
        Write-Output ""
        Write-Output "Windows Setup compatibility scan will fail if system is not rebooted."
        Write-Output "The loaded drivers will be detected as a blocker even though disabled."
        Write-Output ""
        Write-Output "========================================`n"

    } else {
        Write-Output "========================================`n"
        Write-Output "SUCCESS: Microsoft Print to PDF has been disabled."
        Write-Output ""
        Write-Output "No reboot indicated as required by Windows, but for Windows 11 upgrade:"
        Write-Output "It is still recommended to reboot before attempting upgrade to ensure"
        Write-Output "all driver components are fully unloaded from memory."
        Write-Output ""
        Write-Output "========================================`n"
    }

    # Show final state
    Write-Output "Verifying final state..."
    $finalState = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction Stop
    Write-Output "Final State: $($finalState.State)"
    Write-Output ""

} catch {
    Write-Error "Failed to disable Print to PDF feature: $($_.Exception.Message)"
    Write-Output ""
    Write-Output "This may occur if:"
    Write-Output "- System files are corrupted (run sfc /scannow)"
    Write-Output "- Windows Update is in progress"
    Write-Output "- Insufficient permissions"
    Write-Output "- Feature is already being modified"
    Write-Output ""
    Stop-Transcript
    exit 1
}

Write-Output "Print to PDF removal completed."
Write-Output ""
Write-Output "NEXT STEPS:"
Write-Output "1. Schedule a reboot for this system"
Write-Output "2. After reboot, verify feature is disabled (run this script again)"
Write-Output "3. Proceed with Windows 11 upgrade"
Write-Output ""

Stop-Transcript
exit 0
