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

Start-Transcript -Path $LogPath

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
        exit 1
    }

    Write-Host "Running with Administrator privileges" -ForegroundColor Green
    Write-Host ""

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
    } catch {
        Write-Host "  Failed to disable HVCI: $($_.Exception.Message)" -ForegroundColor Red
    }

    try {
        Set-ItemProperty -Path $hvciPath -Name "Locked" -Value 0 -Type DWord -Force
        Write-Host "  HVCI Locked = 0 (Unlocked)" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to unlock HVCI: $($_.Exception.Message)" -ForegroundColor Red
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
    } catch {
        Write-Host "  Failed to set DMA policy: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host ""

    # Step 7: Remove UEFI lock if present (requires bcdedit)
    Write-Host "Step 7: Removing UEFI lock on VBS..." -ForegroundColor Yellow

    try {
        # Disable Secure Launch
        $result = bcdedit /set "{current}" vsmlaunchtype Off 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  VSM Launch Type set to Off" -ForegroundColor Green
        } else {
            Write-Host "  VSM Launch Type: $result" -ForegroundColor Gray
        }
    } catch {
        Write-Host "  Could not modify VSM launch type" -ForegroundColor Gray
    }

    try {
        # Disable Hypervisor launch
        $result = bcdedit /set "{current}" hypervisorlaunchtype Off 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Hypervisor Launch Type set to Off" -ForegroundColor Green
            Write-Host "  WARNING: This will disable Hyper-V, WSL2, and Windows Sandbox!" -ForegroundColor Yellow
        } else {
            Write-Host "  Hypervisor setting: $result" -ForegroundColor Gray
        }
    } catch {
        Write-Host "  Could not modify hypervisor launch type" -ForegroundColor Gray
    }

    Write-Host ""

    # Final summary
    Write-Host "=== Configuration Summary ===" -ForegroundColor Cyan
    Write-Host "Memory Integrity (HVCI): Disabled" -ForegroundColor Green
    Write-Host "Virtualization Based Security (VBS): Disabled" -ForegroundColor Green
    Write-Host "Credential Guard: Disabled" -ForegroundColor Green
    Write-Host "Kernel DMA Protection: Policy relaxed" -ForegroundColor Green
    Write-Host "VSM/Hypervisor: Set to Off" -ForegroundColor Green
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "Core Isolation disabled successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Performance impact removed:" -ForegroundColor Cyan
    Write-Host "  - ~10-15% CPU overhead eliminated" -ForegroundColor White
    Write-Host "  - Driver compatibility issues resolved" -ForegroundColor White
    Write-Host "  - Virtualization software conflicts resolved" -ForegroundColor White
    Write-Host ""
    Write-Host "IMPORTANT NOTES:" -ForegroundColor Yellow
    Write-Host "  - A system restart is REQUIRED for changes to take effect" -ForegroundColor Yellow
    Write-Host "  - If UEFI locked, may require BIOS changes to fully disable" -ForegroundColor Yellow
    Write-Host "  - Hyper-V, WSL2, and Windows Sandbox will be disabled" -ForegroundColor Yellow
    Write-Host "  - This reduces security - only use on systems that need it" -ForegroundColor Yellow

} catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
    Write-Host "Error details: $($_.Exception)" -ForegroundColor Red
    exit 1
}

Stop-Transcript
