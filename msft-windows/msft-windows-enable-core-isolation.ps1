## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $Description

# This script re-enables Core Isolation (Memory Integrity / HVCI)
# Use this to reverse the effects of msft-windows-disable-core-isolation.ps1
# Note: On some older machines, disabling Core Isolation can cause screen flickering - this script fixes that.

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-enable-core-isolation.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
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
    if ($null -ne $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
    }

    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "Windows Core Isolation Enable"
    }
}

# Start the script logic here.

# Ensure log directory exists before starting transcript
$logDir = Split-Path -Path $LogPath -Parent
if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

$TranscriptStarted = $false
try {
    Start-Transcript -Path $LogPath -ErrorAction Stop
    $TranscriptStarted = $true
} catch {
    Write-Host "Warning: Could not start transcript logging to $LogPath - $($_.Exception.Message)"
}

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM `n"

Write-Host "=== Windows Core Isolation Enable Script ===" -ForegroundColor Cyan
Write-Host "This script re-enables Core Isolation (Memory Integrity/HVCI)." -ForegroundColor White
Write-Host ""

try {
    # Check if running as administrator
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-Error "This script must be run as Administrator to modify system security settings."
        if ($TranscriptStarted) { Stop-Transcript }
        exit 1
    }

    Write-Host "Running with Administrator privileges" -ForegroundColor Green
    Write-Host ""

    # Track success/failure of each operation
    $hvciSuccess = $false
    $vbsSuccess = $false
    $hypervisorSuccess = $false

    # Step 1: Check current Core Isolation status
    Write-Host "Step 1: Checking current Core Isolation status..." -ForegroundColor Yellow

    try {
        $deviceGuard = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue
        if ($deviceGuard) {
            Write-Host "  VBS Status: $($deviceGuard.VirtualizationBasedSecurityStatus)" -ForegroundColor Gray
            Write-Host "  HVCI Status: $($deviceGuard.CodeIntegrityPolicyEnforcementStatus)" -ForegroundColor Gray
        }
    } catch {
        Write-Host "  Could not query current status" -ForegroundColor Gray
    }

    Write-Host ""

    # Step 2: Enable Memory Integrity (HVCI)
    Write-Host "Step 2: Enabling Memory Integrity (HVCI)..." -ForegroundColor Yellow

    $hvciPath = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"

    if (!(Test-Path $hvciPath)) {
        New-Item -Path $hvciPath -Force | Out-Null
        Write-Host "  Created registry path: $hvciPath" -ForegroundColor Gray
    }

    try {
        Set-ItemProperty -Path $hvciPath -Name "Enabled" -Value 1 -Type DWord -Force
        Write-Host "  HVCI Enabled = 1 (Enabled)" -ForegroundColor Green
        $hvciSuccess = $true
    } catch {
        Write-Host "  Failed to enable HVCI: $($_.Exception.Message)" -ForegroundColor Red
    }

    try {
        # Remove the WasEnabledBy value if it exists (let Windows manage it)
        Remove-ItemProperty -Path $hvciPath -Name "WasEnabledBy" -Force -ErrorAction SilentlyContinue
        Write-Host "  Cleared WasEnabledBy (Windows will manage)" -ForegroundColor Green
    } catch {
        # Ignore - may not exist
    }

    Write-Host ""

    # Step 3: Enable Virtualization Based Security (VBS)
    Write-Host "Step 3: Enabling Virtualization Based Security (VBS)..." -ForegroundColor Yellow

    $deviceGuardPath = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard"

    if (!(Test-Path $deviceGuardPath)) {
        New-Item -Path $deviceGuardPath -Force | Out-Null
    }

    try {
        Set-ItemProperty -Path $deviceGuardPath -Name "EnableVirtualizationBasedSecurity" -Value 1 -Type DWord -Force
        Write-Host "  EnableVirtualizationBasedSecurity = 1 (Enabled)" -ForegroundColor Green
        $vbsSuccess = $true
    } catch {
        Write-Host "  Failed to enable VBS: $($_.Exception.Message)" -ForegroundColor Red
    }

    try {
        # Set to require Secure Boot and DMA protection (value 3)
        # Value 1 = Secure Boot only, Value 3 = Secure Boot + DMA Protection
        Set-ItemProperty -Path $deviceGuardPath -Name "RequirePlatformSecurityFeatures" -Value 1 -Type DWord -Force
        Write-Host "  RequirePlatformSecurityFeatures = 1 (Secure Boot)" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to set RequirePlatformSecurityFeatures: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host ""

    # Step 4: Re-enable Hypervisor (required for VBS)
    Write-Host "Step 4: Re-enabling Hypervisor..." -ForegroundColor Yellow

    try {
        $result = bcdedit /set "{current}" hypervisorlaunchtype Auto 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Hypervisor Launch Type set to Auto" -ForegroundColor Green
            $hypervisorSuccess = $true
        } else {
            Write-Host "  Hypervisor setting: $result" -ForegroundColor Gray
        }
    } catch {
        Write-Host "  Could not modify hypervisor launch type" -ForegroundColor Gray
    }

    try {
        $result = bcdedit /deletevalue "{current}" vsmlaunchtype 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  VSM Launch Type reset to default" -ForegroundColor Green
        } else {
            Write-Host "  VSM setting: $result" -ForegroundColor Gray
        }
    } catch {
        Write-Host "  Could not reset VSM launch type" -ForegroundColor Gray
    }

    Write-Host ""

    # Step 5: Remove DMA Protection policy override (restore default)
    Write-Host "Step 5: Restoring Kernel DMA Protection defaults..." -ForegroundColor Yellow

    $dmaGuardPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Kernel DMA Protection"

    try {
        if (Test-Path $dmaGuardPath) {
            Remove-ItemProperty -Path $dmaGuardPath -Name "DeviceEnumerationPolicy" -Force -ErrorAction SilentlyContinue
            Write-Host "  Removed DMA policy override (Windows default restored)" -ForegroundColor Green
        } else {
            Write-Host "  No DMA policy override found (already default)" -ForegroundColor Green
        }
    } catch {
        Write-Host "  Could not remove DMA policy: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host ""

    # Final summary
    Write-Host "=== Configuration Summary ===" -ForegroundColor Cyan
    if ($hvciSuccess) {
        Write-Host "Memory Integrity (HVCI): Enabled" -ForegroundColor Green
    } else {
        Write-Host "Memory Integrity (HVCI): Failed to enable" -ForegroundColor Red
    }
    if ($vbsSuccess) {
        Write-Host "Virtualization Based Security (VBS): Enabled" -ForegroundColor Green
    } else {
        Write-Host "Virtualization Based Security (VBS): Failed to enable" -ForegroundColor Red
    }
    if ($hypervisorSuccess) {
        Write-Host "Hypervisor: Set to Auto" -ForegroundColor Green
    } else {
        Write-Host "Hypervisor: Could not modify" -ForegroundColor Yellow
    }
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""

    # Determine overall success
    $overallSuccess = $hvciSuccess -and $vbsSuccess
    if ($overallSuccess) {
        Write-Host "Core Isolation re-enabled successfully!" -ForegroundColor Green
    } else {
        Write-Host "Core Isolation partially enabled - some operations failed" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Security features restored:" -ForegroundColor Cyan
    Write-Host "  - Memory Integrity protection against kernel exploits" -ForegroundColor White
    Write-Host "  - Virtualization Based Security isolation" -ForegroundColor White
    Write-Host "  - Hyper-V, WSL2, and Windows Sandbox support" -ForegroundColor White
    Write-Host ""
    Write-Host "Note: A system restart is REQUIRED for changes to take effect." -ForegroundColor Yellow

} catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
    Write-Host "Error details: $($_.Exception)" -ForegroundColor Red
    if ($TranscriptStarted) { Stop-Transcript }
    exit 1
}

if ($TranscriptStarted) { Stop-Transcript }
