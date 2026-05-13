## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $env:RMM                   - "1" to skip the interactive Read-Host prompt
## $env:Description           - Ticket # / initials for the transcript audit trail
## $env:RMMScriptPath         - Optional transcript root (e.g. Datto). Falls back to $env:WINDIR\logs
## $env:ScreenTimeoutSeconds  - Monitor (display) idle timeout in seconds, applied AC+DC to every scheme.
##                              0 = never turn off. Valid range 0..86400. Default 900 (15 minutes).

# This script configures Windows power management settings:
# 1. Disables hybrid sleep across all plans
# 2. Disables fast startup globally
# 3. Disables hibernation globally on all systems (dental PMS / older LOB apps crash
#    on resume from hibernation due to stale network state; Fast Startup amplifies it)
# 4. Stops hard disks from turning off on all plans
# 5. Disables sleeping completely across all plans
# 6. Sets lid close action (laptops only): AC = do nothing (docked / external monitor stays
#    awake); DC = sleep
# 7. Sets critical battery action to shutdown (3) across all chassis, AC and DC
# 8. Disables USB selective suspend across all plans
# 9. Disables PCIE Link State Power Management across all plans
# 10. Enables all wake timers across all plans
# 11. Sets wireless adapters to maximum performance across all plans
# 12. Sets video playback to maximum quality across all plans
# 13. Optimizes multimedia settings for best performance across all plans
# 14. Sets monitor (display) idle timeout from $env:ScreenTimeoutSeconds (default 900s)
#     across all plans, AC+DC. 0 = never turn off.
# 15. Sets the Balanced power plan as the active scheme after per-scheme config (if present).
# 16. Sets power button action to shutdown (laptops only, AC + DC)
# 17. Enables Energy Saver auto-on at 20% battery (laptops only, DC; aggressive policy)

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-power-management-config.log"

# Default monitor (display) timeout in seconds when nothing is passed in.
# 0 = never; brief picked 900 (15 minutes) as the canonical workstation default.
$DefaultScreenTimeoutSeconds = 900
$MinScreenTimeoutSeconds     = 0
$MaxScreenTimeoutSeconds     = 86400  # 24h ceiling; anything above is almost certainly an operator typo

# Auto-detect non-interactive PowerShell (e.g. NinjaOne, Datto, scheduled tasks).
# When -NonInteractive is on the command line, Read-Host throws and would kill the
# script, so treat that as RMM mode even if $env:RMM was not explicitly passed.
try {
    $cmdLineArgs = [Environment]::GetCommandLineArgs()
    if ($cmdLineArgs | Where-Object { $_ -match '^-NonInteractive$' }) {
        if ($env:RMM -ne "1") {
            Write-Host "Non-interactive PowerShell detected; treating as RMM mode."
            $env:RMM = "1"
        }
    }
} catch {
    # If detection itself fails, leave $env:RMM as-is and proceed.
}

if ($env:RMM -ne "1") {
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

    # Interactive prompt for monitor timeout. Empty / Enter accepts the default.
    $ValidTimeout = 0
    while ($ValidTimeout -ne 1) {
        $raw = Read-Host "Monitor timeout in seconds (0 = never, default $DefaultScreenTimeoutSeconds)"
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $ScreenTimeoutSeconds = $DefaultScreenTimeoutSeconds
            $ValidTimeout = 1
        } else {
            $parsed = 0
            if ([int]::TryParse($raw, [ref]$parsed) -and $parsed -ge $MinScreenTimeoutSeconds -and $parsed -le $MaxScreenTimeoutSeconds) {
                $ScreenTimeoutSeconds = $parsed
                $ValidTimeout = 1
            } else {
                Write-Host "[WARN] ScreenTimeoutSeconds value '$raw' invalid (expected integer in $MinScreenTimeoutSeconds..$MaxScreenTimeoutSeconds)."
            }
        }
    }

    $LogPath = "$env:WINDIR\logs\$ScriptLogName"

} else {
    # Prefer RMMScriptPath when the RMM provides one (e.g. Datto), otherwise fall back to WINDIR.
    if (-not [string]::IsNullOrWhiteSpace($env:RMMScriptPath)) {
        $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$env:WINDIR\logs\$ScriptLogName"
    }

    if ([string]::IsNullOrWhiteSpace($env:Description)) {
        Write-Host "Description is empty/null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "Windows Power Management Configuration"
    } else {
        $Description = $env:Description
    }

    # Resolve screen timeout from env-var with range validation. Reject non-integer,
    # negative, or absurdly large values; fall back to the default rather than fail.
    if ([string]::IsNullOrWhiteSpace($env:ScreenTimeoutSeconds)) {
        $ScreenTimeoutSeconds = $DefaultScreenTimeoutSeconds
    } else {
        $parsed = 0
        if ([int]::TryParse($env:ScreenTimeoutSeconds, [ref]$parsed) -and $parsed -ge $MinScreenTimeoutSeconds -and $parsed -le $MaxScreenTimeoutSeconds) {
            $ScreenTimeoutSeconds = $parsed
        } else {
            Write-Host "[WARN] ScreenTimeoutSeconds value '$env:ScreenTimeoutSeconds' invalid (expected integer in $MinScreenTimeoutSeconds..$MaxScreenTimeoutSeconds), using default ${DefaultScreenTimeoutSeconds}s."
            $ScreenTimeoutSeconds = $DefaultScreenTimeoutSeconds
        }
    }
}

# Emit progress to stdout BEFORE the transcript starts, so even if Start-Transcript
# fails (no log dir, locked file, etc.) the RMM still captures something useful.
Write-Host "msft-windows-power-management-config.ps1 starting"
Write-Host "Description          : $Description"
Write-Host "RMM                  : $env:RMM"
Write-Host "Computer             : $env:COMPUTERNAME"
Write-Host "User context         : $env:USERNAME"
Write-Host "PowerShell           : $($PSVersionTable.PSVersion) ($([IntPtr]::Size * 8)-bit)"
Write-Host "ScreenTimeoutSeconds : $ScreenTimeoutSeconds$(if ($ScreenTimeoutSeconds -eq 0) { ' (never turn off)' })"

# Pre-create the transcript directory so Start-Transcript can't fail on a missing folder.
$logDir = Split-Path -Path $LogPath -Parent
if ($logDir -and -not (Test-Path -Path $logDir)) {
    try {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        Write-Host "Created log directory: $logDir"
    } catch {
        Write-Host "Warning: could not create log directory ${logDir}: $($_.Exception.Message)"
    }
}

# Wrap Start-Transcript so a transcript failure (e.g. ErrorActionPreference=Stop in
# the RMM runner) cannot kill the script.
$transcriptStarted = $false
try {
    Start-Transcript -Path $LogPath -ErrorAction Stop | Out-Null
    $transcriptStarted = $true
    Write-Host "Transcript started: $LogPath"
} catch {
    Write-Host "Warning: Start-Transcript failed for ${LogPath}: $($_.Exception.Message)"
    Write-Host "Continuing without transcript."
}

Write-Host "Log path: $LogPath"

Write-Host "=== Windows Power Management Configuration Script ===" -ForegroundColor Cyan
Write-Host "This script will configure power settings for optimal performance and control." -ForegroundColor White
Write-Host ""

# Main body wrapped in try/catch/finally so any unhandled throw still stops the
# transcript cleanly and returns a real exit code to the RMM.
$exitCode = 0

try {
    # Check if running as administrator
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        throw "This script must be run as Administrator to modify power settings."
    }

    Write-Host "[OK] Running with Administrator privileges" -ForegroundColor Green
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
    # @(...) forces array semantics so single-scheme hosts (e.g. one Balanced plan only)
    # still render $powerSchemes.Count correctly; PS 5.1 doesn't auto-array-wrap a pipeline
    # that yields exactly one PSCustomObject.
    $powerSchemes = @(powercfg /list | Where-Object { $_ -match "GUID: ([a-f0-9\-]+)" } | ForEach-Object {
        if ($_ -match "GUID: ([a-f0-9\-]+)\s+\((.+?)\)(?:\s+\*)?") {
            [PSCustomObject]@{
                GUID = $matches[1]
                Name = $matches[2].Trim()
                IsActive = $_ -match "\*$"
            }
        }
    })

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
        Write-Host "[OK] Fast Startup disabled globally" -ForegroundColor Green
    } catch {
        Write-Host "[FAIL] Failed to disable Fast Startup: $($_.Exception.Message)" -ForegroundColor Red
    }
    Write-Host ""

    # Step 3: Disable hibernation unconditionally across all chassis.
    # Operator preference: dental PMS and older LOB apps crash on resume from hibernation
    # due to stale network state. Fast Startup's hybrid-shutdown amplifies the same issue.
    Write-Host "Step 3: Disabling hibernation..." -ForegroundColor Yellow
    try {
        $hibernationResult = powercfg /hibernate off 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Hibernation disabled" -ForegroundColor Green
        } else {
            Write-Host "[WARN] Hibernation disable command completed with warnings: $hibernationResult" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[FAIL] Failed to disable hibernation: $($_.Exception.Message)" -ForegroundColor Red
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
            # SUB_VIDEO = 7516b95f-f776-4464-8c53-06167f40cc99
            # VIDEOIDLE = 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e

            # 4a. Disable hybrid sleep for both AC and DC (battery)
            Write-Host "  - Disabling hybrid sleep..." -ForegroundColor White
            powercfg /setacvalueindex $($scheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 94ac6d29-73ce-41a6-809f-6363ba21b47e 0 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 94ac6d29-73ce-41a6-809f-6363ba21b47e 0 | Out-Null

            # 4b. Disable hard disk turn off for both AC and DC
            Write-Host "  - Disabling hard disk turn off..." -ForegroundColor White
            powercfg /setacvalueindex $($scheme.GUID) 0012EE47-9041-4B5D-9B77-535FBA8B1442 6738E2C4-E8A5-4A42-B16A-E040E769756E 0 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 0012EE47-9041-4B5D-9B77-535FBA8B1442 6738E2C4-E8A5-4A42-B16A-E040E769756E 0 | Out-Null

            # 4c. Disable automatic sleep for both AC and DC
            Write-Host "  - Disabling automatic sleep..." -ForegroundColor White
            powercfg /setacvalueindex $($scheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0 | Out-Null

            # 4d. Chassis-scoped: lid close action and power button action only apply on laptops.
            # Desktops don't have a lid, and we don't want to override desktop power-button behavior.
            if ($IsLaptop) {
                # Lid close actions: 0=Do nothing, 1=Sleep, 2=Hibernate, 3=Shut down
                # AC = 0 (do nothing) so docked / external-monitor workflows keep the laptop awake.
                # DC = 1 (sleep) so closing the lid on battery still saves power.
                Write-Host "  - Setting lid close action (AC=do nothing, DC=sleep) [laptop]..." -ForegroundColor White
                powercfg /setacvalueindex $($scheme.GUID) 4F971E89-EEBD-4455-A8DE-9E59040E7347 5CA83367-6E45-459F-A27B-476B1D01C936 0 | Out-Null
                powercfg /setdcvalueindex $($scheme.GUID) 4F971E89-EEBD-4455-A8DE-9E59040E7347 5CA83367-6E45-459F-A27B-476B1D01C936 1 | Out-Null

                # Power button action: 3 = Shut down. AC + DC. Laptops only.
                # PBUTTONACTION GUID: 7648efa3-dd9c-4e3e-b566-50f929386280
                Write-Host "  - Setting power button action to shutdown (AC + DC) [laptop]..." -ForegroundColor White
                powercfg /setacvalueindex $($scheme.GUID) 4F971E89-EEBD-4455-A8DE-9E59040E7347 7648EFA3-DD9C-4E3E-B566-50F929386280 3 | Out-Null
                powercfg /setdcvalueindex $($scheme.GUID) 4F971E89-EEBD-4455-A8DE-9E59040E7347 7648EFA3-DD9C-4E3E-B566-50F929386280 3 | Out-Null
            } else {
                Write-Host "  - Skipping lid + power-button settings (desktop)" -ForegroundColor Gray
            }

            # 4e. Set critical battery action to shutdown across all chassis.
            # Critical battery actions: 0=Do nothing, 1=Sleep, 2=Hibernate, 3=Shut down
            # Operator preference: hibernation breaks dental PMS / LOB app network state on resume.
            Write-Host "  - Setting critical battery action to shutdown..." -ForegroundColor White
            powercfg /setacvalueindex $($scheme.GUID) E73A048D-BF27-4F12-9731-8B2076E8891F 637EA02F-BBCB-4015-8E2C-A1C7B9C0B546 3 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) E73A048D-BF27-4F12-9731-8B2076E8891F 637EA02F-BBCB-4015-8E2C-A1C7B9C0B546 3 | Out-Null

            # 4f. Set monitor (display) idle timeout for both AC and DC
            $timeoutLabel = if ($ScreenTimeoutSeconds -eq 0) { 'never' } else { "$ScreenTimeoutSeconds seconds" }
            Write-Host "  - Setting monitor idle timeout to $timeoutLabel..." -ForegroundColor White
            powercfg /setacvalueindex $($scheme.GUID) 7516b95f-f776-4464-8c53-06167f40cc99 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e $ScreenTimeoutSeconds | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 7516b95f-f776-4464-8c53-06167f40cc99 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e $ScreenTimeoutSeconds | Out-Null

            # Apply the settings to the scheme
            powercfg /setactive $($scheme.GUID) | Out-Null

            Write-Host "[OK] Power scheme '$($scheme.Name)' configured successfully" -ForegroundColor Green

        } catch {
            Write-Host "[FAIL] Failed to configure power scheme '$($scheme.Name)': $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Write-Host ""

    # Step 4z: Set the Balanced power plan as the active scheme.
    # The per-scheme loop above leaves the last-enumerated scheme active as a powercfg
    # commit-side-effect; that's surprising for operators expecting a deterministic active
    # plan. Pick Balanced explicitly when it exists.
    # SCHEME_BALANCED GUID: 381b4222-f694-41f0-9685-ff5bb260df2e
    $balancedGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
    $balancedScheme = $powerSchemes | Where-Object { $_.GUID -eq $balancedGuid } | Select-Object -First 1
    if ($balancedScheme) {
        Write-Host "Step 4z: Setting Balanced power plan as the active scheme..." -ForegroundColor Yellow
        powercfg /setactive $balancedGuid | Out-Null
        Write-Host "[OK] Balanced plan ('$($balancedScheme.Name)') is now active" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Balanced power plan ($balancedGuid) not found on this host. Active scheme left as configured by the per-scheme loop." -ForegroundColor Yellow
    }
    Write-Host ""

    # Additional power settings configuration
    Write-Host "Step 5: Configuring additional power settings..." -ForegroundColor Yellow

    try {
        foreach ($scheme in $powerSchemes) {
            Write-Host "  - Disabling unattended sleep timeout for '$($scheme.Name)'..." -ForegroundColor White
            powercfg /setacvalueindex $($scheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 0 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 7bc4a2f9-d8fc-4469-b07b-33eb785aaca0 0 | Out-Null
        }
        Write-Host "[OK] Unattended sleep timeout disabled for all schemes" -ForegroundColor Green
    } catch {
        Write-Host "[WARN] Some unattended sleep settings may not have been configured" -ForegroundColor Yellow
    }

    try {
        foreach ($scheme in $powerSchemes) {
            Write-Host "  - Disabling USB selective suspend for '$($scheme.Name)'..." -ForegroundColor White
            powercfg /setacvalueindex $($scheme.GUID) 2A737441-1930-4402-8D77-B2BEBBA308A3 48E6B7A6-50F5-4782-A5D4-53BB8F07E226 0 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 2A737441-1930-4402-8D77-B2BEBBA308A3 48E6B7A6-50F5-4782-A5D4-53BB8F07E226 0 | Out-Null
        }
        Write-Host "[OK] USB selective suspend disabled for all schemes" -ForegroundColor Green
    } catch {
        Write-Host "[WARN] USB selective suspend settings may not have been configured" -ForegroundColor Yellow
    }

    try {
        foreach ($scheme in $powerSchemes) {
            Write-Host "  - Disabling PCIE Link State Power Management for '$($scheme.Name)'..." -ForegroundColor White
            # ASPM (Active State Power Management) - 0=Off, 1=Moderate power savings, 2=Maximum power savings
            powercfg /setacvalueindex $($scheme.GUID) 501A4D13-42AF-4429-9FD1-A8218C268E20 EE12F906-D277-404B-B6DA-E5FA1A576DF5 0 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 501A4D13-42AF-4429-9FD1-A8218C268E20 EE12F906-D277-404B-B6DA-E5FA1A576DF5 0 | Out-Null
        }
        Write-Host "[OK] PCIE Link State Power Management disabled for all schemes" -ForegroundColor Green
    } catch {
        Write-Host "[WARN] PCIE Link State Power Management settings may not have been configured" -ForegroundColor Yellow
    }

    try {
        foreach ($scheme in $powerSchemes) {
            Write-Host "  - Enabling wake timers for '$($scheme.Name)'..." -ForegroundColor White
            # Wake timers: 0=Disable, 1=Enable, 2=Important wake timers only
            powercfg /setacvalueindex $($scheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 BD3B718A-0680-4D9D-8AB2-E1D2B4AC806D 1 2>&1 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 BD3B718A-0680-4D9D-8AB2-E1D2B4AC806D 1 2>&1 | Out-Null
        }
        Write-Host "[OK] Wake timers enabled for all schemes" -ForegroundColor Green
    } catch {
        Write-Host "[WARN] Wake timer settings may not have been configured" -ForegroundColor Yellow
    }

    try {
        foreach ($scheme in $powerSchemes) {
            Write-Host "  - Setting wireless adapter to maximum performance for '$($scheme.Name)'..." -ForegroundColor White
            # Wireless adapter power saving: 0=Maximum Performance, 1=Low, 2=Medium, 3=Maximum Power Saving
            powercfg /setacvalueindex $($scheme.GUID) 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>&1 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0 2>&1 | Out-Null
        }
        Write-Host "[OK] Wireless adapter set to maximum performance for all schemes" -ForegroundColor Green
    } catch {
        Write-Host "[WARN] Wireless adapter settings may not have been configured" -ForegroundColor Yellow
    }

    try {
        foreach ($scheme in $powerSchemes) {
            Write-Host "  - Setting video playback to maximum quality for '$($scheme.Name)'..." -ForegroundColor White
            # Video playback quality bias: 0=power-saving bias, 1=performance bias
            powercfg /setacvalueindex $($scheme.GUID) 9596fb26-9850-41fd-ac3e-f7c3c00afd4b 10778347-1370-4ee0-8bbd-33bdacaade49 1 2>&1 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 9596fb26-9850-41fd-ac3e-f7c3c00afd4b 10778347-1370-4ee0-8bbd-33bdacaade49 1 2>&1 | Out-Null
        }
        Write-Host "[OK] Video playback set to maximum quality for all schemes" -ForegroundColor Green
    } catch {
        Write-Host "[WARN] Video playback settings may not have been configured" -ForegroundColor Yellow
    }

    try {
        foreach ($scheme in $powerSchemes) {
            Write-Host "  - Optimizing multimedia settings for '$($scheme.Name)'..." -ForegroundColor White
            # When playing video: 0=Optimize video quality, 1=Balanced, 2=Optimize power savings
            powercfg /setacvalueindex $($scheme.GUID) 9596fb26-9850-41fd-ac3e-f7c3c00afd4b 34C7B99F-9A6D-4b3c-8DC7-B6693B78CEF4 0 2>&1 | Out-Null
            powercfg /setdcvalueindex $($scheme.GUID) 9596fb26-9850-41fd-ac3e-f7c3c00afd4b 34C7B99F-9A6D-4b3c-8DC7-B6693B78CEF4 0 2>&1 | Out-Null
        }
        Write-Host "[OK] Multimedia settings optimized for all schemes" -ForegroundColor Green
    } catch {
        Write-Host "[WARN] Multimedia settings may not have been configured" -ForegroundColor Yellow
    }

    # Chassis-scoped: Energy Saver auto-on at 20% battery, aggressive policy. Laptops only, DC only.
    # Energy Saver doesn't apply on AC; setting AC values is a no-op but we skip them for clarity.
    # SUB_ENERGYSAVER  = de830923-a562-41af-a086-e3a2c6bad2da
    # ESBATTTHRESHOLD  = e69653ca-cf7f-4f05-aa73-cb833fa90ad4  (Charge level percent, 0..100)
    # ESPOLICY         = 5c5bb349-ad29-4ee2-9d0b-2b25270f7a81  (0=User, 1=Aggressive)
    if ($IsLaptop) {
        try {
            foreach ($scheme in $powerSchemes) {
                Write-Host "  - Configuring Energy Saver (DC, threshold=20%, aggressive) for '$($scheme.Name)' [laptop]..." -ForegroundColor White
                powercfg /setdcvalueindex $($scheme.GUID) de830923-a562-41af-a086-e3a2c6bad2da e69653ca-cf7f-4f05-aa73-cb833fa90ad4 20 | Out-Null
                powercfg /setdcvalueindex $($scheme.GUID) de830923-a562-41af-a086-e3a2c6bad2da 5c5bb349-ad29-4ee2-9d0b-2b25270f7a81 1  | Out-Null
            }
            Write-Host "[OK] Energy Saver auto-on at 20% battery (aggressive) configured for all schemes" -ForegroundColor Green
        } catch {
            Write-Host "[WARN] Energy Saver settings may not have been configured" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  - Skipping Energy Saver settings (desktop)" -ForegroundColor Gray
    }
    Write-Host ""

    # Step 6: Verify hibernation status.
    # `powercfg /availablesleepstates` prints TWO sections: "available" and "not available".
    # A naive substring match on "Hibernate" false-positives because the word appears under
    # "not available: Hibernate / Hibernation has not been enabled." Parse the available
    # section only.
    Write-Host "Step 6: Verifying hibernation status..." -ForegroundColor Yellow
    try {
        $sleepRaw = (powercfg /availablesleepstates 2>&1 | Out-String)
        # Split on the "not available" delimiter. The first chunk is the available list.
        $parts = [regex]::Split($sleepRaw, '(?im)^\s*The following sleep states are not available')
        $availableSection = $parts[0]
        if ($availableSection -match '(?im)^\s*Hibernate\s*$') {
            Write-Host "[WARN] Hibernation is still listed as an available sleep state" -ForegroundColor Yellow
            Write-Host "Available states:" -ForegroundColor Gray
            Write-Host $availableSection -ForegroundColor Gray
        } else {
            Write-Host "[OK] Hibernation is properly disabled (not in available sleep states)" -ForegroundColor Green
        }
    } catch {
        Write-Host "Could not verify hibernation status: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    Write-Host ""

    # Step 7: Display current power scheme configuration
    Write-Host "Step 7: Displaying current power configuration..." -ForegroundColor Yellow

    $activeScheme = $powerSchemes | Where-Object { $_.IsActive }
    if ($activeScheme) {
        Write-Host "Active Power Scheme: $($activeScheme.Name)" -ForegroundColor Cyan

        try {
            Write-Host "Current settings for active scheme:" -ForegroundColor White

            $hybridSleepAC = powercfg /q $($activeScheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 94ac6d29-73ce-41a6-809f-6363ba21b47e | Select-String "Current AC Power Setting Index:"
            $hybridSleepDC = powercfg /q $($activeScheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 94ac6d29-73ce-41a6-809f-6363ba21b47e | Select-String "Current DC Power Setting Index:"
            Write-Host "  - Hybrid Sleep (AC): $(if ($hybridSleepAC -match '0x00000000') { 'Disabled' } else { 'Enabled' })" -ForegroundColor Gray
            Write-Host "  - Hybrid Sleep (DC): $(if ($hybridSleepDC -match '0x00000000') { 'Disabled' } else { 'Enabled' })" -ForegroundColor Gray

            $sleepAC = powercfg /q $($activeScheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da | Select-String "Current AC Power Setting Index:"
            $sleepDC = powercfg /q $($activeScheme.GUID) 238C9FA8-0AAD-41ED-83F4-97BE242C8F20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da | Select-String "Current DC Power Setting Index:"
            Write-Host "  - Sleep Timeout (AC): $(if ($sleepAC -match '0x00000000') { 'Never' } else { 'Configured' })" -ForegroundColor Gray
            Write-Host "  - Sleep Timeout (DC): $(if ($sleepDC -match '0x00000000') { 'Never' } else { 'Configured' })" -ForegroundColor Gray

            $diskAC = powercfg /q $($activeScheme.GUID) 0012EE47-9041-4B5D-9B77-535FBA8B1442 6738E2C4-E8A5-4A42-B16A-E040E769756E | Select-String "Current AC Power Setting Index:"
            $diskDC = powercfg /q $($activeScheme.GUID) 0012EE47-9041-4B5D-9B77-535FBA8B1442 6738E2C4-E8A5-4A42-B16A-E040E769756E | Select-String "Current DC Power Setting Index:"
            Write-Host "  - Disk Timeout (AC): $(if ($diskAC -match '0x00000000') { 'Never' } else { 'Configured' })" -ForegroundColor Gray
            Write-Host "  - Disk Timeout (DC): $(if ($diskDC -match '0x00000000') { 'Never' } else { 'Configured' })" -ForegroundColor Gray

            # Monitor (display) timeout readback. Value is hex seconds; 0 = never.
            function Format-VideoIdle {
                param([string]$line)
                if (-not $line) { return 'Unknown' }
                if ($line -match '0x([0-9a-fA-F]+)') {
                    $sec = [Convert]::ToInt32($matches[1], 16)
                    if ($sec -eq 0) { return 'Never' } else { return "$sec seconds" }
                }
                return 'Unknown'
            }
            $videoAC = powercfg /q $($activeScheme.GUID) 7516b95f-f776-4464-8c53-06167f40cc99 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e | Select-String "Current AC Power Setting Index:"
            $videoDC = powercfg /q $($activeScheme.GUID) 7516b95f-f776-4464-8c53-06167f40cc99 3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e | Select-String "Current DC Power Setting Index:"
            Write-Host "  - Monitor Timeout (AC): $(Format-VideoIdle $videoAC.Line)" -ForegroundColor Gray
            Write-Host "  - Monitor Timeout (DC): $(Format-VideoIdle $videoDC.Line)" -ForegroundColor Gray

        } catch {
            Write-Host "Could not retrieve detailed power settings" -ForegroundColor Yellow
        }
    }
    Write-Host ""

    # Final summary
    Write-Host "=== Configuration Summary ===" -ForegroundColor Cyan
    Write-Host "Device Type: $(if ($IsLaptop) { 'Laptop' } else { 'Desktop' })" -ForegroundColor White
    Write-Host "[OK] Hybrid sleep disabled across all power plans" -ForegroundColor Green
    Write-Host "[OK] Fast startup disabled globally" -ForegroundColor Green
    Write-Host "[OK] Hibernation disabled" -ForegroundColor Green
    Write-Host "[OK] Hard disk turn off disabled on all plans" -ForegroundColor Green
    Write-Host "[OK] Automatic sleep disabled across all plans" -ForegroundColor Green
    if ($IsLaptop) {
        Write-Host "[OK] Lid close action: AC = do nothing, DC = sleep (laptop)" -ForegroundColor Green
        Write-Host "[OK] Power button action: shutdown (AC + DC, laptop)" -ForegroundColor Green
        Write-Host "[OK] Energy Saver auto-on at 20% battery, aggressive (laptop, DC)" -ForegroundColor Green
    } else {
        Write-Host "[--] Lid / power-button / Energy Saver: skipped (desktop)" -ForegroundColor Gray
    }
    Write-Host "[OK] Critical battery action set to shutdown (AC + DC, all schemes)" -ForegroundColor Green
    Write-Host "[OK] USB selective suspend disabled for stability" -ForegroundColor Green
    Write-Host "[OK] PCIE Link State Power Management disabled for stability" -ForegroundColor Green
    Write-Host "[OK] Wake timers enabled to allow scheduled tasks" -ForegroundColor Green
    Write-Host "[OK] Wireless adapters set to maximum performance" -ForegroundColor Green
    Write-Host "[OK] Video playback optimized for maximum quality" -ForegroundColor Green
    Write-Host "[OK] Multimedia settings optimized for best performance" -ForegroundColor Green
    if ($balancedScheme) {
        Write-Host "[OK] Balanced power plan set as active" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Balanced power plan not found; active scheme left as last-configured" -ForegroundColor Yellow
    }
    if ($ScreenTimeoutSeconds -eq 0) {
        Write-Host "[OK] Monitor (display) timeout: never (0s)" -ForegroundColor Green
    } else {
        Write-Host "[OK] Monitor (display) timeout: $ScreenTimeoutSeconds seconds AC+DC, all schemes" -ForegroundColor Green
    }
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "[SUCCESS] Power management configuration completed."
    Write-Host "Note: Some settings may require a system restart to take full effect."

} catch {
    Write-Host "[FAILURE] $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    $exitCode = 1
} finally {
    Write-Host "msft-windows-power-management-config.ps1 completed (exit $exitCode)"
    if ($transcriptStarted) { Stop-Transcript }
}

exit $exitCode
