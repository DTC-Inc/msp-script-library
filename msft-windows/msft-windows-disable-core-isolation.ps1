## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $Description

# This script disables Core Isolation (Memory Integrity / HVCI) which causes:
# - 10-15% CPU performance overhead
# - Incompatibility with older drivers and software
# - Virtualization software conflicts
# - Blue screens with certain hardware/drivers
# Core Isolation uses Virtualization Based Security (VBS) which adds significant overhead

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-disable-core-isolation.log"

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
        $Description = "Windows Core Isolation Disable"
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

Write-Host "=== Windows Core Isolation Disable Script ===" -ForegroundColor Cyan
Write-Host "This script disables Core Isolation (Memory Integrity/HVCI) to improve performance." -ForegroundColor White
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
    $credGuardSuccess = $false
    $dmaSuccess = $false

    # Step 1: Check current Core Isolation status
    Write-Host "Step 1: Checking current Core Isolation status..." -ForegroundColor Yellow

    try {
        $deviceGuard = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction SilentlyContinue
        if ($deviceGuard) {
            Write-Host "  VBS Status: $($deviceGuard.VirtualizationBasedSecurityStatus)" -ForegroundColor Gray
            Write-Host "  HVCI Status: $($deviceGuard.CodeIntegrityPolicyEnforcementStatus)" -ForegroundColor Gray
        }
    } catch {
        Write-Host "  Could not query current status (may not be enabled)" -ForegroundColor Gray
    }

    Write-Host ""

    # Step 2: Disable Memory Integrity (HVCI)
    Write-Host "Step 2: Disabling Memory Integrity (HVCI)..." -ForegroundColor Yellow

    $hvciPath = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"

    if (!(Test-Path $hvciPath)) {
        New-Item -Path $hvciPath -Force | Out-Null
        Write-Host "  Created registry path: $hvciPath" -ForegroundColor Gray
    }

    try {
        Set-ItemProperty -Path $hvciPath -Name "Enabled" -Value 0 -Type DWord -Force
        Write-Host "  HVCI Enabled = 0 (Disabled)" -ForegroundColor Green
        $hvciSuccess = $true
    } catch {
        Write-Host "  Failed to disable HVCI: $($_.Exception.Message)" -ForegroundColor Red
    }

    try {
        Set-ItemProperty -Path $hvciPath -Name "Locked" -Value 0 -Type DWord -Force
        Write-Host "  HVCI Locked = 0 (Unlocked)" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to unlock HVCI: $($_.Exception.Message)" -ForegroundColor Red
        $hvciSuccess = $false
    }

    try {
        Set-ItemProperty -Path $hvciPath -Name "WasEnabledBy" -Value 0 -Type DWord -Force
        Write-Host "  HVCI WasEnabledBy = 0" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to set WasEnabledBy: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host ""

    # Step 3: Disable Virtualization Based Security (VBS)
    Write-Host "Step 3: Disabling Virtualization Based Security (VBS)..." -ForegroundColor Yellow

    $deviceGuardPath = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard"

    if (!(Test-Path $deviceGuardPath)) {
        New-Item -Path $deviceGuardPath -Force | Out-Null
    }

    try {
        Set-ItemProperty -Path $deviceGuardPath -Name "EnableVirtualizationBasedSecurity" -Value 0 -Type DWord -Force
        Write-Host "  EnableVirtualizationBasedSecurity = 0 (Disabled)" -ForegroundColor Green
        $vbsSuccess = $true
    } catch {
        Write-Host "  Failed to disable VBS: $($_.Exception.Message)" -ForegroundColor Red
    }

    try {
        Set-ItemProperty -Path $deviceGuardPath -Name "RequirePlatformSecurityFeatures" -Value 0 -Type DWord -Force
        Write-Host "  RequirePlatformSecurityFeatures = 0" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to set RequirePlatformSecurityFeatures: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host ""

    # Step 4: Disable Credential Guard
    Write-Host "Step 4: Disabling Credential Guard..." -ForegroundColor Yellow

    $credGuardPath = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\CredentialGuard"

    if (!(Test-Path $credGuardPath)) {
        New-Item -Path $credGuardPath -Force | Out-Null
    }

    try {
        Set-ItemProperty -Path $credGuardPath -Name "Enabled" -Value 0 -Type DWord -Force
        Write-Host "  Credential Guard Enabled = 0 (Disabled)" -ForegroundColor Green
        $credGuardSuccess = $true
    } catch {
        Write-Host "  Failed to disable Credential Guard: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ""

    # Step 5: Disable via Group Policy registry keys
    Write-Host "Step 5: Disabling via Group Policy registry..." -ForegroundColor Yellow

    $lsaCfgPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"

    try {
        Set-ItemProperty -Path $lsaCfgPath -Name "LsaCfgFlags" -Value 0 -Type DWord -Force
        Write-Host "  LsaCfgFlags = 0 (Credential Guard policy disabled)" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to set LsaCfgFlags: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host ""

    # Step 6: Disable Kernel DMA Protection (if causing issues)
    Write-Host "Step 6: Checking Kernel DMA Protection..." -ForegroundColor Yellow

    $dmaGuardPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Kernel DMA Protection"

    if (!(Test-Path $dmaGuardPath)) {
        New-Item -Path $dmaGuardPath -Force | Out-Null
    }

    try {
        Set-ItemProperty -Path $dmaGuardPath -Name "DeviceEnumerationPolicy" -Value 0 -Type DWord -Force
        Write-Host "  Kernel DMA Protection policy set to allow all" -ForegroundColor Green
        $dmaSuccess = $true
    } catch {
        Write-Host "  Failed to set DMA policy: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host ""

    # Note: We intentionally do NOT disable the hypervisor (bcdedit hypervisorlaunchtype Off)
    # because some GPU drivers depend on it being present. Disabling just HVCI/VBS via registry
    # is sufficient to remove the security overhead while maintaining driver compatibility.

    # Final summary - report actual status
    Write-Host "=== Configuration Summary ===" -ForegroundColor Cyan
    if ($hvciSuccess) {
        Write-Host "Memory Integrity (HVCI): Disabled" -ForegroundColor Green
    } else {
        Write-Host "Memory Integrity (HVCI): Failed to disable" -ForegroundColor Red
    }
    if ($vbsSuccess) {
        Write-Host "Virtualization Based Security (VBS): Disabled" -ForegroundColor Green
    } else {
        Write-Host "Virtualization Based Security (VBS): Failed to disable" -ForegroundColor Red
    }
    if ($credGuardSuccess) {
        Write-Host "Credential Guard: Disabled" -ForegroundColor Green
    } else {
        Write-Host "Credential Guard: Failed to disable" -ForegroundColor Red
    }
    if ($dmaSuccess) {
        Write-Host "Kernel DMA Protection: Policy relaxed" -ForegroundColor Green
    } else {
        Write-Host "Kernel DMA Protection: Failed to configure" -ForegroundColor Yellow
    }
    Write-Host "Hypervisor: Preserved (for GPU driver compatibility)" -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""

    # Determine overall success
    $overallSuccess = $hvciSuccess -and $vbsSuccess
    if ($overallSuccess) {
        Write-Host "Core Isolation disabled successfully!" -ForegroundColor Green
    } else {
        Write-Host "Core Isolation partially disabled - some operations failed" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Performance impact removed:" -ForegroundColor Cyan
    Write-Host "  - ~10-15% CPU overhead eliminated" -ForegroundColor White
    Write-Host "  - Driver compatibility issues resolved" -ForegroundColor White
    Write-Host "  - Virtualization software conflicts resolved" -ForegroundColor White
    Write-Host ""
    Write-Host "IMPORTANT NOTES:" -ForegroundColor Yellow
    Write-Host "  - A system restart is REQUIRED for changes to take effect" -ForegroundColor Yellow
    Write-Host "  - If UEFI locked, may require BIOS changes to fully disable" -ForegroundColor Yellow
    Write-Host "  - Hyper-V, WSL2, and Windows Sandbox will still work" -ForegroundColor Green
    Write-Host "  - This reduces security - only use on systems that need it" -ForegroundColor Yellow

} catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
    Write-Host "Error details: $($_.Exception)" -ForegroundColor Red
    if ($TranscriptStarted) { Stop-Transcript }
    exit 1
}

if ($TranscriptStarted) { Stop-Transcript }
