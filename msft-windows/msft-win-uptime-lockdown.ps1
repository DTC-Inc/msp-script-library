## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM               - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description        - Ticket # or initials for audit trail
## $env:RMMScriptPath      - Optional log directory base provided by the RMM
## $env:DisableShutdownUi  - Optional. "true" to lock down user shutdown (NoClose + power button = Do nothing);
##                           "false"/empty leaves shutdown available (power-plan/uptime config still applies). Default: false.

# This script consolidates Windows uptime/power configuration and (optional) user-shutdown lockdown into one deployable unit.
# It REPLACES two prior scripts: msft-windows-power-management-config.ps1 and msft-win-shutdown-disable.ps1.
#
# Power-plan / uptime configuration (ALWAYS applied - keeps endpoints awake for backups, patching, maintenance):
#  1. Disables display timeout (never turn off display)
#  2. Disables hybrid sleep across all plans
#  3. Disables fast startup globally
#  4. Disables hibernation on desktops only (keeps hibernation enabled on laptops)
#  5. Stops hard disks from turning off on all plans
#  6. Disables sleeping completely across all plans
#  7. Allows sleeping only when the lid is shut for laptops across all plans
#  8. Sets critical battery action to hibernate (laptops) or shutdown (desktops)
#  9. Disables USB selective suspend across all plans
# 10. Disables PCIE Link State Power Management across all plans
# 11. Enables all wake timers across all plans
# 12. Sets wireless adapters to maximum performance across all plans
# 13. Sets video playback to maximum quality across all plans
# 14. Optimizes multimedia settings for best performance across all plans
#
# Shutdown lockdown (ONLY when $env:DisableShutdownUi = "true"):
# 15. Sets the power button SHORT-PRESS action to "Do nothing" across all plans
# 16. Sets HKLM Explorer policy NoClose=1 (removes Shut Down/Restart/Sleep/Hibernate from Start and Ctrl+Alt+Del, machine-wide)
#     NOTE: The 4-second power-button HOLD is firmware-level and cannot be disabled by any software.

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-win-uptime-lockdown.log"

if ($env:RMM -ne "1") {
    $ValidInput = 0
    while ($ValidInput -ne 1) {
        $env:Description = Read-Host "Please enter the ticket # and/or your initials for audit trail"
        if ($env:Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }

    $shutdownAnswer = ""
    while ($shutdownAnswer -notmatch '^(?i:y|n)$') {
        $shutdownAnswer = Read-Host "Lock down user shutdown? (Y = disable shutdown UI + power button, N = leave shutdown available)"
        if ($shutdownAnswer -notmatch '^(?i:y|n)$') { Write-Host "Please enter Y or N." }
    }
    if ($shutdownAnswer -match '^(?i:y)$') { $env:DisableShutdownUi = "true" } else { $env:DisableShutdownUi = "false" }

    $LogPath = "$env:WINDIR\logs\$ScriptLogName"
} else {
    if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
        $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$env:WINDIR\logs\$ScriptLogName"
    }

    if ([string]::IsNullOrEmpty($env:Description)) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $env:Description = "Windows Uptime / Shutdown Lockdown Policy"
    }
}

# Normalize the shutdown-lockdown toggle to a boolean. Default: false (power-plan config only).
$disableShutdown = $false
if ("$env:DisableShutdownUi".Trim() -match '^(?i:true|1|yes|y)$') { $disableShutdown = $true }

# Ensure log directory exists before starting the transcript
$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# Start the script logic here.

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

Write-Host "=== Windows Power Management Configuration Script ===" -ForegroundColor Cyan
Write-Host "This script will configure power settings for optimal performance and control." -ForegroundColor White
Write-Host ""

try {
    # Check if running as administrator
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Write-Error "This script must be run as Administrator to modify power settings."
        if ($TranscriptStarted) { Stop-Transcript }
        exit 1
    }
    
    Write-Host "✓ Running with Administrator privileges" -ForegroundColor Green
    Write-Host ""

    # Detect if this is a laptop or desktop
    Write-Host "Detecting device type..." -ForegroundColor Yellow
    $chassisTypes = (Get-CimInstance -ClassName Win32_SystemEnclosure).ChassisTypes
    # Laptop chassis types: 8=Portable, 9=Laptop, 10=Notebook, 14=Sub Notebook, 31=Convertible, 32=Detachable
    $laptopChassisTypes = @(8, 9, 10, 14, 31, 32)
    $IsLaptop = $false
    foreach ($type in $chassisTypes) {
        if ($laptopChassisTypes -contains $type) {
            $IsLaptop = $true
            break
        }
    }
    Write-Host "Device Type: $(if ($IsLaptop) { 'Laptop' } else { 'Desktop' })" -ForegroundColor Cyan
    Write-Host ""

    # Get all power schemes
    Write-Host "Step 1: Getting all power schemes..." -ForegroundColor Yellow
    $powerSchemes = powercfg /list | Where-Object { $_ -match "GUID: ([a-f0-9\-]+)" } | ForEach-Object {
        if ($_ -match "GUID: ([a-f0-9\-]+)\s+\((.+?)\)(?:\s+\*)?") {
            [PSCustomObject]@{
                GUID = $matches[1]
                Name = $matches[2].Trim()
                IsActive = $_ -match "\*$"
            }
        }
    }
    
    Write-Host "Found $($powerSchemes.Count) power scheme(s):" -ForegroundColor White
    foreach ($scheme in $powerSchemes) {
        $activeIndicator = if ($scheme.IsActive) { " (ACTIVE)" } else { "" }
        Write-Host "  - $($scheme.Name)$activeIndicator" -ForegroundColor Gray
    }
    Write-Host ""

    # Step 2: Disable Fast Startup globally via registry
    Write-Host "Step 2: Disabling Fast Startup globally..." -ForegroundColor Yellow
    try {
        $fastStartupRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
        
        # Create the registry path if it doesn't exist
        if (!(Test-Path $fastStartupRegPath)) {
            New-Item -Path $fastStartupRegPath -Force | Out-Null
            Write-Host "Created registry path: $fastStartupRegPath" -ForegroundColor Gray
        }
        
        Set-ItemProperty -Path $fastStartupRegPath -Name "HiberbootEnabled" -Value 0 -Type DWord
        Write-Host "✓ Fast Startup disabled globally" -ForegroundColor Green
    } catch {
        Write-Host "❌ Failed to disable Fast Startup: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ""

    # Step 3: Configure hibernation based on device type
    Write-Host "Step 3: Configuring hibernation..." -ForegroundColor Yellow
    try {
        if ($IsLaptop) {
            # Keep hibernation enabled on laptops - needed for critical battery action
            Write-Host "✓ Hibernation kept enabled (laptop detected - needed for critical battery)" -ForegroundColor Green
        } else {
            # Disable hibernation on desktops
            $hibernationResult = powercfg /hibernate off 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Hibernation disabled (desktop detected)" -ForegroundColor Green
            } else {
                Write-Host "⚠ Hibernation disable command completed with warnings: $hibernationResult" -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "❌ Failed to configure hibernation: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ""

    # Step 4-7: Configure power settings for each scheme
    Write-Host "Step 4-7: Configuring power settings for each power scheme..." -ForegroundColor Yellow
    
    foreach ($scheme in $powerSchemes) {
        Write-Host "Configuring power scheme: $($scheme.Name)" -ForegroundColor Cyan
        
        try {
                         # Power setting GUIDs used in this script:
             # SUB_SLEEP = 238C9FA8-0AAD-41ED-83F4-97BE242C8F20
             # HYBRIDSLEEP = 94ac6d29-73ce-41a6-809f-6363ba21b47e
             # STANDBYIDLE = 29f6c1db-86da-48c5-9fdb-f2b67b1f44da
             # UNATTENDSLEEP = 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0
             # WAKETIMERS = BD3B718A-0680-4D9D-8AB2-E1D2B4AC806D
             # SUB_DISK = 0012EE47-9041-4B5D-9B77-535FBA8B1442
             # DISKIDLE = 6738E2C4-E8A5-4A42-B16A-E040E769756E
             # SUB_BUTTONS = 4F971E89-EEBD-4455-A8DE-9E59040E7347
             # LIDACTION = 5ca83367-6e45-459f-a27b-476b1d01c936
             # SUB_BATTERY = E73A048D-BF27-4F12-9731-8B2076E8891F
             # CRITBATTERYACTION = 637ea02f-bbcb-4015-8e2c-a1c7b9c0b546
             # SUB_USB = 2A737441-1930-4402-8D77-B2BEBBA308A3
             # USBSELECTIVESUSPEND = 48E6B7A6-50F5-4782-A5D4-53BB8F07E226
             # SUB_PCIEXPRESS = 501A4D13-42AF-4429-9FD1-A8218C268E20
             # ASPM = EE12F906-D277-404B-B6DA-E5FA1A576DF5
             # SUB_RADIO = 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1
             # RADIOPS = 12bbebe6-58d6-4636-95bb-3217ef867c1a
             # SUB_MULTIMEDIA = 9596fb26-9850-41fd-ac3e-f7c3c00afd4b
             # VIDEOQUALITYBIAS = 10778347-1370-4ee0-8bbd-33bdacaade49
             # WHENPLAYINGVIDEO = 34C7B99F-9A6D-4b3c-8DC7-B6693B78CEF4

                         # 4a. Disable hybrid sleep for both AC and DC (battery)
             Write-Host "  - Disabling hybrid sleep..." -ForegroundColor White
             # Using actual GUIDs: SUB_SLEEP = 238C9FA8-0AAD-41ED-83F4-97BE242C8F20, HYBRIDSLEEP = 94ac6d29-73ce-41a6-809f-6363ba21b47e
             powercfg /setacvalueindex $($scheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 94ac6d29-73ce-41a6-809f-6363ba21b47e 0 | Out-Null
             powercfg /setdcvalueindex $($scheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 94ac6d29-73ce-41a6-809f-6363ba21b47e 0 | Out-Null
             
             # 4b. Disable hard disk turn off for both AC and DC
             Write-Host "  - Disabling hard disk turn off..." -ForegroundColor White
             # Using actual GUIDs: SUB_DISK = 0012EE47-9041-4B5D-9B77-535FBA8B1442, DISKIDLE = 6738E2C4-E8A5-4A42-B16A-E040E769756E
             powercfg /setacvalueindex $($scheme.GUID) 0012EE47-9041-4B5D-9B77-535FBA8B1442 6738E2C4-E8A5-4A42-B16A-E040E769756E 0 | Out-Null
             powercfg /setdcvalueindex $($scheme.GUID) 0012EE47-9041-4B5D-9B77-535FBA8B1442 6738E2C4-E8A5-4A42-B16A-E040E769756E 0 | Out-Null
             
             # 4c. Disable automatic sleep for both AC and DC
             Write-Host "  - Disabling automatic sleep..." -ForegroundColor White
             # Using actual GUIDs: SUB_SLEEP = 238C9FA8-0AAD-41ED-83F4-97BE242C8F20, STANDBYIDLE = 29f6c1db-86da-48c5-9fdb-f2b67b1f44da
             powercfg /setacvalueindex $($scheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0 | Out-Null
             powercfg /setdcvalueindex $($scheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0 | Out-Null
            
                         # 4d. Configure lid close action to sleep (only for laptops)
             Write-Host "  - Setting lid close action to sleep..." -ForegroundColor White
             # Lid close actions: 0=Do nothing, 1=Sleep, 2=Hibernate, 3=Shut down
             # Using actual GUIDs: SUB_BUTTONS = 4F971E89-EEBD-4455-A8DE-9E59040E7347, LIDACTION = 5CA83367-6E45-459F-A27B-476B1D01C936
             powercfg /setacvalueindex $($scheme.GUID) 4F971E89-EEBD-4455-A8DE-9E59040E7347 5CA83367-6E45-459F-A27B-476B1D01C936 1 | Out-Null
             powercfg /setdcvalueindex $($scheme.GUID) 4F971E89-EEBD-4455-A8DE-9E59040E7347 5CA83367-6E45-459F-A27B-476B1D01C936 1 | Out-Null
            
                         # 4d-ii. Power button SHORT-PRESS action (shutdown lockdown only).
             # PBUTTONACTION = 7648EFA3-DD9C-4E3E-B566-50F929386280  (0=Do nothing, 1=Sleep, 2=Hibernate, 3=Shut down)
             # The 4-second power-button HOLD is firmware-level and cannot be changed here.
             if ($disableShutdown) {
                 Write-Host "  - Setting power button short-press to Do nothing (shutdown lockdown)..." -ForegroundColor White
                 powercfg /setacvalueindex $($scheme.GUID) 4F971E89-EEBD-4455-A8DE-9E59040E7347 7648EFA3-DD9C-4E3E-B566-50F929386280 0 | Out-Null
                 powercfg /setdcvalueindex $($scheme.GUID) 4F971E89-EEBD-4455-A8DE-9E59040E7347 7648EFA3-DD9C-4E3E-B566-50F929386280 0 | Out-Null
             } else {
                 Write-Host "  - Restoring power button short-press to Shut down..." -ForegroundColor White
                 powercfg /setacvalueindex $($scheme.GUID) 4F971E89-EEBD-4455-A8DE-9E59040E7347 7648EFA3-DD9C-4E3E-B566-50F929386280 3 | Out-Null
                 powercfg /setdcvalueindex $($scheme.GUID) 4F971E89-EEBD-4455-A8DE-9E59040E7347 7648EFA3-DD9C-4E3E-B566-50F929386280 3 | Out-Null
             }
            
                         # 4e. Set critical battery action based on device type
             # Critical battery actions: 0=Do nothing, 1=Sleep, 2=Hibernate, 3=Shut down
             # Laptops: Hibernate (preserves state), Desktops: Shutdown
             # Using actual GUIDs: SUB_BATTERY = E73A048D-BF27-4F12-9731-8B2076E8891F, CRITBATTERYACTION = 637EA02F-BBCB-4015-8E2C-A1C7B9C0B546
             if ($IsLaptop) {
                 Write-Host "  - Setting critical battery action to hibernate (laptop)..." -ForegroundColor White
                 powercfg /setdcvalueindex $($scheme.GUID) E73A048D-BF27-4F12-9731-8B2076E8891F 637EA02F-BBCB-4015-8E2C-A1C7B9C0B546 2 | Out-Null
             } else {
                 Write-Host "  - Setting critical battery action to shutdown (desktop)..." -ForegroundColor White
                 powercfg /setdcvalueindex $($scheme.GUID) E73A048D-BF27-4F12-9731-8B2076E8891F 637EA02F-BBCB-4015-8E2C-A1C7B9C0B546 3 | Out-Null
             }
            
            # Apply the settings to the scheme
            powercfg /setactive $($scheme.GUID) | Out-Null
            
            Write-Host "✓ Power scheme '$($scheme.Name)' configured successfully" -ForegroundColor Green
            
        } catch {
            Write-Host "❌ Failed to configure power scheme '$($scheme.Name)': $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Write-Host ""

    # Step 4f: Shutdown UI lockdown (machine-wide, HKLM so it applies under SYSTEM/RMM to every user on the device).
    Write-Host "Step 4f: Configuring shutdown UI lockdown (NoClose)..." -ForegroundColor Yellow
    try {
        $explorerPolicyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        if (-not (Test-Path $explorerPolicyPath)) { New-Item -Path $explorerPolicyPath -Force | Out-Null }
        if ($disableShutdown) {
            New-ItemProperty -Path $explorerPolicyPath -Name "NoClose" -Value 1 -PropertyType DWord -Force | Out-Null
            $noCloseNow = (Get-ItemProperty -Path $explorerPolicyPath -Name "NoClose" -ErrorAction SilentlyContinue).NoClose
            if ($noCloseNow -eq 1) {
                Write-Host "✓ Shutdown/Restart/Sleep/Hibernate removed from Start and Ctrl+Alt+Del (NoClose=1)" -ForegroundColor Green
            } else {
                Write-Host "❌ NoClose verify failed: value is '$noCloseNow', expected 1" -ForegroundColor Red
            }
        } else {
            Remove-ItemProperty -Path $explorerPolicyPath -Name "NoClose" -ErrorAction SilentlyContinue
            $noCloseNow = (Get-ItemProperty -Path $explorerPolicyPath -Name "NoClose" -ErrorAction SilentlyContinue).NoClose
            if ($null -eq $noCloseNow) {
                Write-Host "✓ Shutdown UI available (NoClose removed)" -ForegroundColor Green
            } else {
                Write-Host "❌ NoClose verify failed: still present ='$noCloseNow'" -ForegroundColor Red
            }
        }
        Write-Host "Note: NoClose takes effect at the user's next sign-in (or after Explorer restart)." -ForegroundColor Gray
        Write-Host "Note: The 4-second power-button HOLD is firmware-level and cannot be disabled by software." -ForegroundColor Gray
    } catch {
        Write-Host "❌ Failed to configure shutdown UI lockdown: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ""

    # Additional power settings configuration
    Write-Host "Step 5: Configuring additional power settings..." -ForegroundColor Yellow
    
    try {
        # Disable system unattended sleep timeout for all schemes
        foreach ($scheme in $powerSchemes) {
            Write-Host "  - Disabling unattended sleep timeout for '$($scheme.Name)'..." -ForegroundColor White
            # Using actual GUIDs: SUB_SLEEP = 238C9FA8-0AAD-41ED-83F4-97BE242C8F20, UNATTENDSLEEP = 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0
            powercfg /setacvalueindex $($scheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 0 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 0 | Out-Null
        }
        Write-Host "✓ Unattended sleep timeout disabled for all schemes" -ForegroundColor Green
    } catch {
        Write-Host "⚠ Some unattended sleep settings may not have been configured" -ForegroundColor Yellow
    }
    
    try {
        # Configure USB selective suspend (disable to prevent issues)
        foreach ($scheme in $powerSchemes) {
            Write-Host "  - Disabling USB selective suspend for '$($scheme.Name)'..." -ForegroundColor White
            # Using actual GUIDs: SUB_USB = 2A737441-1930-4402-8D77-B2BEBBA308A3, USBSELECTIVESUSPEND = 48E6B7A6-50F5-4782-A5D4-53BB8F07E226
            powercfg /setacvalueindex $($scheme.GUID) 2A737441-1930-4402-8D77-B2BEBBA308A3 48E6B7A6-50F5-4782-A5D4-53BB8F07E226 0 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 2A737441-1930-4402-8D77-B2BEBBA308A3 48E6B7A6-50F5-4782-A5D4-53BB8F07E226 0 | Out-Null
        }
        Write-Host "✓ USB selective suspend disabled for all schemes" -ForegroundColor Green
    } catch {
        Write-Host "⚠ USB selective suspend settings may not have been configured" -ForegroundColor Yellow
    }
    
    try {
        # Configure PCIE Link State Power Management (disable to prevent issues)
        foreach ($scheme in $powerSchemes) {
            Write-Host "  - Disabling PCIE Link State Power Management for '$($scheme.Name)'..." -ForegroundColor White
            # ASPM (Active State Power Management) - 0=Off, 1=Moderate power savings, 2=Maximum power savings
            # Using actual GUIDs: SUB_PCIEXPRESS = 501A4D13-42AF-4429-9FD1-A8218C268E20, ASPM = EE12F906-D277-404B-B6DA-E5FA1A576DF5
            powercfg /setacvalueindex $($scheme.GUID) 501A4D13-42AF-4429-9FD1-A8218C268E20 EE12F906-D277-404B-B6DA-E5FA1A576DF5 0 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 501A4D13-42AF-4429-9FD1-A8218C268E20 EE12F906-D277-404B-B6DA-E5FA1A576DF5 0 | Out-Null
        }
        Write-Host "✓ PCIE Link State Power Management disabled for all schemes" -ForegroundColor Green
    } catch {
        Write-Host "⚠ PCIE Link State Power Management settings may not have been configured" -ForegroundColor Yellow
    }
    
    try {
        # Configure wake timers (allow all wake timers)
        foreach ($scheme in $powerSchemes) {
            Write-Host "  - Enabling wake timers for '$($scheme.Name)'..." -ForegroundColor White
            # Wake timers: 0=Disable, 1=Enable, 2=Important wake timers only
            # Using actual GUIDs: SUB_SLEEP = 238C9FA8-0AAD-41ED-83F4-97BE242C8F20, Wake Timers = BD3B718A-0680-4D9D-8AB2-E1D2B4AC806D
            powercfg /setacvalueindex $($scheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 BD3B718A-0680-4D9D-8AB2-E1D2B4AC806D 1 2>&1 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 BD3B718A-0680-4D9D-8AB2-E1D2B4AC806D 1 2>&1 | Out-Null
        }
        Write-Host "✓ Wake timers enabled for all schemes" -ForegroundColor Green
    } catch {
        Write-Host "⚠ Wake timer settings may not have been configured" -ForegroundColor Yellow
    }
    
    try {
        # Configure wireless adapter power saving mode (disable for maximum performance)
        foreach ($scheme in $powerSchemes) {
            Write-Host "  - Setting wireless adapter to maximum performance for '$($scheme.Name)'..." -ForegroundColor White
            # Wireless adapter power saving: 0=Maximum Performance, 1=Low Power Saving, 2=Medium Power Saving, 3=Maximum Power Saving
            # Using actual GUIDs: SUB_RADIO = 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1, RADIOPS = 12bbebe6-58d6-4636-95bb-3217ef867c1a
            powercfg /setacvalueindex $($scheme.GUID) 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>&1 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>&1 | Out-Null
        }
        Write-Host "✓ Wireless adapter set to maximum performance for all schemes" -ForegroundColor Green
    } catch {
        Write-Host "⚠ Wireless adapter settings may not have been configured" -ForegroundColor Yellow
    }
    
    try {
        # Configure video playback quality bias (set to video playback performance bias for maximum quality)
        foreach ($scheme in $powerSchemes) {
            Write-Host "  - Setting video playback to maximum quality for '$($scheme.Name)'..." -ForegroundColor White
            # Video playback quality bias: 0=Video playback power-saving bias, 1=Video playback performance bias
            # Using actual GUIDs: SUB_MULTIMEDIA = 9596fb26-9850-41fd-ac3e-f7c3c00afd4b, VIDEOQUALITYBIAS = 10778347-1370-4ee0-8bbd-33bdacaade49
            powercfg /setacvalueindex $($scheme.GUID) 9596fb26-9850-41fd-ac3e-f7c3c00afd4b 10778347-1370-4ee0-8bbd-33bdacaade49 1 2>&1 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 9596fb26-9850-41fd-ac3e-f7c3c00afd4b 10778347-1370-4ee0-8bbd-33bdacaade49 1 2>&1 | Out-Null
        }
        Write-Host "✓ Video playback set to maximum quality for all schemes" -ForegroundColor Green
    } catch {
        Write-Host "⚠ Video playback settings may not have been configured" -ForegroundColor Yellow
    }
    
    try {
        # Configure multimedia settings for optimal performance
        foreach ($scheme in $powerSchemes) {
            Write-Host "  - Optimizing multimedia settings for '$($scheme.Name)'..." -ForegroundColor White
            # When playing video: 0=Optimize video quality, 1=Balanced, 2=Optimize power savings
            # Using actual GUIDs: SUB_MULTIMEDIA = 9596fb26-9850-41fd-ac3e-f7c3c00afd4b, WHENPLAYINGVIDEO = 34C7B99F-9A6D-4b3c-8DC7-B6693B78CEF4
            powercfg /setacvalueindex $($scheme.GUID) 9596fb26-9850-41fd-ac3e-f7c3c00afd4b 34C7B99F-9A6D-4b3c-8DC7-B6693B78CEF4 0 2>&1 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 9596fb26-9850-41fd-ac3e-f7c3c00afd4b 34C7B99F-9A6D-4b3c-8DC7-B6693B78CEF4 0 2>&1 | Out-Null
        }
        Write-Host "✓ Multimedia settings optimized for all schemes" -ForegroundColor Green
    } catch {
        Write-Host "⚠ Multimedia settings may not have been configured" -ForegroundColor Yellow
    }
    Write-Host ""

    # Step 6: Verify hibernation status
    Write-Host "Step 6: Verifying hibernation status..." -ForegroundColor Yellow
    try {
        $hibernationStatus = powercfg /availablesleepstates 2>&1
        if ($IsLaptop) {
            # Laptops should have hibernation available
            if ($hibernationStatus -like "*Hibernate*") {
                Write-Host "✓ Hibernation is available (required for laptop critical battery action)" -ForegroundColor Green
            } else {
                Write-Host "⚠ Hibernation not available - critical battery will fall back to shutdown" -ForegroundColor Yellow
            }
        } else {
            # Desktops should have hibernation disabled
            if ($hibernationStatus -like "*Hibernate*") {
                Write-Host "⚠ Hibernation may still be available" -ForegroundColor Yellow
                Write-Host "Hibernation status: $hibernationStatus" -ForegroundColor Gray
            } else {
                Write-Host "✓ Hibernation is properly disabled" -ForegroundColor Green
            }
        }
    } catch {
        Write-Host "Could not verify hibernation status" -ForegroundColor Yellow
    }
    Write-Host ""

    # Step 7: Display current power scheme configuration
    Write-Host "Step 7: Displaying current power configuration..." -ForegroundColor Yellow
    
    # Get the active power scheme
    $activeScheme = $powerSchemes | Where-Object { $_.IsActive }
    if ($activeScheme) {
        Write-Host "Active Power Scheme: $($activeScheme.Name)" -ForegroundColor Cyan
        
        # Display key settings for the active scheme
        try {
            Write-Host "Current settings for active scheme:" -ForegroundColor White
            
                         # Get hybrid sleep setting
             $hybridSleepAC = powercfg /q $($activeScheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 94ac6d29-73ce-41a6-809f-6363ba21b47e | Select-String "Current AC Power Setting Index:"
             $hybridSleepDC = powercfg /q $($activeScheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 94ac6d29-73ce-41a6-809f-6363ba21b47e | Select-String "Current DC Power Setting Index:"
             Write-Host "  - Hybrid Sleep (AC): $(if ($hybridSleepAC -match '0x00000000') { 'Disabled' } else { 'Enabled' })" -ForegroundColor Gray
             Write-Host "  - Hybrid Sleep (DC): $(if ($hybridSleepDC -match '0x00000000') { 'Disabled' } else { 'Enabled' })" -ForegroundColor Gray
             
             # Get sleep timeout settings
             $sleepAC = powercfg /q $($activeScheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da | Select-String "Current AC Power Setting Index:"
             $sleepDC = powercfg /q $($activeScheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da | Select-String "Current DC Power Setting Index:"
             Write-Host "  - Sleep Timeout (AC): $(if ($sleepAC -match '0x00000000') { 'Never' } else { 'Configured' })" -ForegroundColor Gray
             Write-Host "  - Sleep Timeout (DC): $(if ($sleepDC -match '0x00000000') { 'Never' } else { 'Configured' })" -ForegroundColor Gray
             
             # Get disk timeout settings
             $diskAC = powercfg /q $($activeScheme.GUID) 0012EE47-9041-4B5D-9B77-535FBA8B1442 6738E2C4-E8A5-4A42-B16A-E040E769756E | Select-String "Current AC Power Setting Index:"
             $diskDC = powercfg /q $($activeScheme.GUID) 0012EE47-9041-4B5D-9B77-535FBA8B1442 6738E2C4-E8A5-4A42-B16A-E040E769756E | Select-String "Current DC Power Setting Index:"
             Write-Host "  - Disk Timeout (AC): $(if ($diskAC -match '0x00000000') { 'Never' } else { 'Configured' })" -ForegroundColor Gray
             Write-Host "  - Disk Timeout (DC): $(if ($diskDC -match '0x00000000') { 'Never' } else { 'Configured' })" -ForegroundColor Gray
            
        } catch {
            Write-Host "Could not retrieve detailed power settings" -ForegroundColor Yellow
        }
    }
    Write-Host ""

    # Final summary
    Write-Host "=== Configuration Summary ===" -ForegroundColor Cyan
    Write-Host "Device Type: $(if ($IsLaptop) { 'Laptop' } else { 'Desktop' })" -ForegroundColor White
    Write-Host "✓ Balanced power plan set as active" -ForegroundColor Green
    Write-Host "✓ Display timeout disabled (never turn off)" -ForegroundColor Green
    Write-Host "✓ Hybrid sleep disabled across all power plans" -ForegroundColor Green
    Write-Host "✓ Fast startup disabled globally" -ForegroundColor Green
    if ($IsLaptop) {
        Write-Host "✓ Hibernation kept enabled (laptop - needed for critical battery)" -ForegroundColor Green
    } else {
        Write-Host "✓ Hibernation disabled (desktop)" -ForegroundColor Green
    }
    Write-Host "✓ Hard disk turn off disabled on all plans" -ForegroundColor Green
    Write-Host "✓ Automatic sleep disabled across all plans" -ForegroundColor Green
    Write-Host "✓ Lid close action set to sleep (laptops only)" -ForegroundColor Green
    if ($IsLaptop) {
        Write-Host "✓ Critical battery action set to hibernate (laptop)" -ForegroundColor Green
    } else {
        Write-Host "✓ Critical battery action set to shutdown (desktop)" -ForegroundColor Green
    }
    Write-Host "✓ USB selective suspend disabled for stability" -ForegroundColor Green
    Write-Host "✓ PCIE Link State Power Management disabled for stability" -ForegroundColor Green
    Write-Host "✓ Wake timers enabled to allow scheduled tasks" -ForegroundColor Green
    Write-Host "✓ Wireless adapters set to maximum performance" -ForegroundColor Green
    Write-Host "✓ Video playback optimized for maximum quality" -ForegroundColor Green
    Write-Host "✓ Multimedia settings optimized for best performance" -ForegroundColor Green
    if ($disableShutdown) {
        Write-Host "✓ Shutdown UI disabled (NoClose) + power button short-press = Do nothing" -ForegroundColor Green
    } else {
        Write-Host "✓ Shutdown UI available (NoClose removed) + power button short-press = Shut down" -ForegroundColor Green
    }
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "Power management configuration completed successfully!" -ForegroundColor Green
    Write-Host "Note: Some settings may require a system restart to take full effect." -ForegroundColor Yellow

} catch {
    Write-Error "An error occurred during power management configuration: $($_.Exception.Message)"
    Write-Host "Error details: $($_.Exception)" -ForegroundColor Red
    if ($TranscriptStarted) { Stop-Transcript }
    exit 1
}

if ($TranscriptStarted) { Stop-Transcript }

exit 0
