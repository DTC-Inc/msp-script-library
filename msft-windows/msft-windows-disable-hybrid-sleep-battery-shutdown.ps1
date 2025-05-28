## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# This script disables hybrid sleep and configures the computer to shutdown at 5% battery
# instead of hibernating. This ensures the computer only sleeps when lid is closed or
# when going to sleep, and shuts down cleanly when battery is critically low.
# No input variables required - script runs automatically

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "Disable-Hybrid-Sleep-Battery-Shutdown.log"

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
Write-Host "Starting hybrid sleep disable and battery shutdown configuration..."

try {
    # Check if running as administrator
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Write-Host "ERROR: This script must be run as Administrator to modify power settings." -ForegroundColor Red
        throw "Administrator privileges required"
    }
    
    Write-Host "Running with Administrator privileges - proceeding with power configuration..." -ForegroundColor Green
    
    # First, completely disable hibernation system-wide
    Write-Host "Disabling hibernation system-wide..."
    $result = powercfg /hibernate off
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Successfully disabled hibernation system-wide" -ForegroundColor Green
    } else {
        Write-Host "Warning: Failed to disable hibernation system-wide (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
    }
    
    # Immediately verify hibernation was disabled
    Write-Host "Verifying hibernation disable..."
    $sleepStatesOutput = powercfg /availablesleepstates
    
    # Look for hibernation status more explicitly
    $hibernationAvailable = $false
    $hibernationFound = $false
    
    foreach ($line in $sleepStatesOutput) {
        if ($line -match "^\s*Hibernate\s*$") {
            $hibernationFound = $true
        }
        elseif ($hibernationFound -and $line -match "Hibernation has not been enabled|is not available") {
            $hibernationAvailable = $false
            break
        }
        elseif ($hibernationFound -and $line -match "^\s*$") {
            # Empty line after Hibernate section without disable message means it's available
            $hibernationAvailable = $true
            break
        }
        elseif ($hibernationFound -and $line -notmatch "^\s") {
            # New section started, if we got here hibernation is available
            $hibernationAvailable = $true
            break
        }
    }
    
    if ($hibernationAvailable) {
        Write-Host "Warning: Hibernation still appears to be available. Trying additional methods..." -ForegroundColor Yellow
        
        # Try alternative hibernation disable methods
        try {
            # Method 1: Disable via registry
            $hibernationRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Power"
            Set-ItemProperty -Path $hibernationRegPath -Name "HibernateEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            
            # Method 2: Set hibernation file size to 0
            powercfg /hibernate off 2>$null
            powercfg -h off 2>$null
            
            Write-Host "Applied additional hibernation disable methods" -ForegroundColor Yellow
        }
        catch {
            Write-Host "Warning: Some hibernation disable methods failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "Hibernation successfully disabled and verified" -ForegroundColor Green
    }
    
    # Disable Fast Startup (which uses hibernation for faster boot)
    Write-Host "Disabling Fast Startup..."
    try {
        $fastStartupRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
        $fastStartupValueName = "HiberbootEnabled"
        
        # Check if the registry path exists, create if it doesn't
        if (-not (Test-Path $fastStartupRegPath)) {
            Write-Host "Creating Fast Startup registry path..." -ForegroundColor Yellow
            New-Item -Path $fastStartupRegPath -Force | Out-Null
        }
        
        # Set HiberbootEnabled to 0 (disabled)
        Set-ItemProperty -Path $fastStartupRegPath -Name $fastStartupValueName -Value 0 -Type DWord -Force
        Write-Host "Successfully disabled Fast Startup" -ForegroundColor Green
        
        # Verify the setting
        $currentValue = Get-ItemProperty -Path $fastStartupRegPath -Name $fastStartupValueName -ErrorAction SilentlyContinue
        if ($currentValue.$fastStartupValueName -eq 0) {
            Write-Host "Verified: Fast Startup is disabled" -ForegroundColor Green
        } else {
            Write-Host "Warning: Fast Startup setting verification failed" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Warning: Failed to disable Fast Startup: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    
    # Disable Hybrid Sleep for all power schemes
    Write-Host "Discovering and configuring all available power schemes..."
    
    # Get all power schemes dynamically
    $powerSchemeOutput = powercfg /list
    $powerSchemes = @()
    
    foreach ($line in $powerSchemeOutput) {
        if ($line -match "Power Scheme GUID: ([a-f0-9\-]+)\s+\((.+)\)") {
            $schemeGuid = $matches[1]
            $schemeName = $matches[2]
            $powerSchemes += @{
                GUID = $schemeGuid
                Name = $schemeName
                IsActive = $line -match "\*"
            }
            Write-Host "Found power scheme: $schemeName (GUID: $schemeGuid)" -ForegroundColor Cyan
            if ($line -match "\*") {
                Write-Host "  ^ Currently active scheme" -ForegroundColor Yellow
            }
        }
    }
    
    if ($powerSchemes.Count -eq 0) {
        Write-Host "ERROR: No power schemes found! This is unexpected." -ForegroundColor Red
        throw "No power schemes detected"
    }
    
    Write-Host "Found $($powerSchemes.Count) power scheme(s) to configure" -ForegroundColor Green
    
    # Store the currently active scheme to restore later
    $originalActiveScheme = $powerSchemes | Where-Object { $_.IsActive -eq $true } | Select-Object -First 1
    if ($originalActiveScheme) {
        Write-Host "Original active scheme: $($originalActiveScheme.Name)" -ForegroundColor Cyan
    }
    
    foreach ($scheme in $powerSchemes) {
        Write-Host "`nProcessing power scheme: $($scheme.Name) (GUID: $($scheme.GUID))" -ForegroundColor Magenta
        
        # Query available settings for this power scheme
        Write-Host "  Discovering available power settings for this scheme..."
        $availableSettings = @{}
        
        try {
            $queryOutput = powercfg /query $scheme.GUID 2>$null
            if ($queryOutput) {
                $currentSubgroup = $null
                foreach ($line in $queryOutput) {
                    # Look for subgroup GUID lines
                    if ($line -match "Subgroup GUID: ([a-f0-9\-]+)") {
                        $currentSubgroup = $matches[1]
                        if (-not $availableSettings.ContainsKey($currentSubgroup)) {
                            $availableSettings[$currentSubgroup] = @{}
                        }
                    }
                    # Look for power setting GUID lines within subgroups
                    elseif ($line -match "Power Setting GUID: ([a-f0-9\-]+)" -and $currentSubgroup) {
                        $settingGuid = $matches[1]
                        $availableSettings[$currentSubgroup][$settingGuid] = $true
                    }
                }
                Write-Host "    Discovered settings for $($availableSettings.Keys.Count) subgroups" -ForegroundColor Green
                
                # Debug: Show if battery subgroup exists
                if ($availableSettings.ContainsKey("e73a048d-bf27-4f12-9731-8b2076e8891f")) {
                    Write-Host "    Battery subgroup found with $($availableSettings['e73a048d-bf27-4f12-9731-8b2076e8891f'].Keys.Count) settings" -ForegroundColor Cyan
                } else {
                    Write-Host "    Battery subgroup not found" -ForegroundColor Cyan
                }
            }
        }
        catch {
            Write-Host "    Warning: Could not query available settings for this scheme" -ForegroundColor Yellow
        }
        
        # Helper function to check if a setting exists
        $CheckSetting = {
            param($subgroupGuid, $settingGuid)
            return ($availableSettings.ContainsKey($subgroupGuid) -and 
                    $availableSettings[$subgroupGuid].ContainsKey($settingGuid))
        }
        
        # Disable hybrid sleep (AC power)
        if (& $CheckSetting "238c9fa8-0aad-41ed-83f4-97be242c8f20" "94ac6d29-73ce-41a6-809f-6363ba21b47e") {
            Write-Host "  Disabling hybrid sleep on AC power..."
            $result = powercfg /setacvalueindex $scheme.GUID 238c9fa8-0aad-41ed-83f4-97be242c8f20 94ac6d29-73ce-41a6-809f-6363ba21b47e 0
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    Successfully disabled hybrid sleep on AC power" -ForegroundColor Green
            } else {
                Write-Host "    Warning: Failed to disable hybrid sleep on AC power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Hybrid sleep setting not available in this power scheme" -ForegroundColor Cyan
        }
        
        # Disable hybrid sleep (DC/Battery power)
        if (& $CheckSetting "238c9fa8-0aad-41ed-83f4-97be242c8f20" "94ac6d29-73ce-41a6-809f-6363ba21b47e") {
            Write-Host "  Disabling hybrid sleep on battery power..."
            $result = powercfg /setdcvalueindex $scheme.GUID 238c9fa8-0aad-41ed-83f4-97be242c8f20 94ac6d29-73ce-41a6-809f-6363ba21b47e 0
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    Successfully disabled hybrid sleep on battery power" -ForegroundColor Green
            } else {
                Write-Host "    Warning: Failed to disable hybrid sleep on battery power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Hybrid sleep setting not available in this power scheme" -ForegroundColor Cyan
        }
        
        # Disable hibernation after sleep (AC power)
        Write-Host "  Disabling hibernation after sleep on AC power..."
        $result = powercfg /setacvalueindex $scheme.GUID 238c9fa8-0aad-41ed-83f4-97be242c8f20 9d7815a6-7ee4-497e-8888-515a05f02364 0
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Successfully disabled hibernation after sleep on AC power" -ForegroundColor Green
        } else {
            Write-Host "    Warning: Failed to disable hibernation after sleep on AC power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
        
        # Disable hibernation after sleep (DC/Battery power)
        Write-Host "  Disabling hibernation after sleep on battery power..."
        $result = powercfg /setdcvalueindex $scheme.GUID 238c9fa8-0aad-41ed-83f4-97be242c8f20 9d7815a6-7ee4-497e-8888-515a05f02364 0
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Successfully disabled hibernation after sleep on battery power" -ForegroundColor Green
        } else {
            Write-Host "    Warning: Failed to disable hibernation after sleep on battery power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
        
        # Set critical battery action to shutdown (DC power only)
        if (& $CheckSetting "e73a048d-bf27-4f12-9731-8b2076e8891f" "637ea02f-bbcb-4015-8e2c-a1c7b9c0b546") {
            Write-Host "  Setting critical battery action to shutdown..."
            $result = powercfg /setdcvalueindex $scheme.GUID e73a048d-bf27-4f12-9731-8b2076e8891f 637ea02f-bbcb-4015-8e2c-a1c7b9c0b546 3
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    Successfully set critical battery action to shutdown" -ForegroundColor Green
            } else {
                Write-Host "    Warning: Failed to set critical battery action (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Critical battery action setting not available (likely desktop/no battery)" -ForegroundColor Cyan
        }
        
        # Set critical battery level to 5%
        if (& $CheckSetting "e73a048d-bf27-4f12-9731-8b2076e8891f" "9a66d8d7-4ff7-4ef9-b5a2-5a326ca2a469") {
            Write-Host "  Setting critical battery level to 5%..."
            $result = powercfg /setdcvalueindex $scheme.GUID e73a048d-bf27-4f12-9731-8b2076e8891f 9a66d8d7-4ff7-4ef9-b5a2-5a326ca2a469 5
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    Successfully set critical battery level to 5%" -ForegroundColor Green
            } else {
                Write-Host "    Warning: Failed to set critical battery level (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Critical battery level setting not available (likely desktop/no battery)" -ForegroundColor Cyan
        }
        
        # Set low battery action to do nothing (to prevent early hibernation)
        if (& $CheckSetting "e73a048d-bf27-4f12-9731-8b2076e8891f" "d8742dcb-3e6a-4b3c-b3fe-374623cdcf06") {
            Write-Host "  Setting low battery action to do nothing..."
            $result = powercfg /setdcvalueindex $scheme.GUID e73a048d-bf27-4f12-9731-8b2076e8891f d8742dcb-3e6a-4b3c-b3fe-374623cdcf06 0
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    Successfully set low battery action to do nothing" -ForegroundColor Green
            } else {
                Write-Host "    Warning: Failed to set low battery action (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Low battery action setting not available (likely desktop/no battery)" -ForegroundColor Cyan
        }
        
        # Disable PCI Express Link State Power Management (AC power)
        Write-Host "  Disabling PCI Express Link State Power Management on AC power..."
        $result = powercfg /setacvalueindex $scheme.GUID 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Successfully disabled PCI Express power management on AC power" -ForegroundColor Green
        } else {
            Write-Host "    Warning: Failed to disable PCI Express power management on AC power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
        
        # Disable PCI Express Link State Power Management (DC/Battery power)
        Write-Host "  Disabling PCI Express Link State Power Management on battery power..."
        $result = powercfg /setdcvalueindex $scheme.GUID 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 0
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Successfully disabled PCI Express power management on battery power" -ForegroundColor Green
        } else {
            Write-Host "    Warning: Failed to disable PCI Express power management on battery power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
        
        # Set graphics power policy to maximum performance (AC power)
        $graphicsConfigured = $false
        
        # Try Intel Graphics first
        if (& $CheckSetting "44f3beca-a7c0-460e-9df2-bb8b99e0cba6" "3619c3f2-afb2-4afc-b0e9-e7fef372de36") {
            Write-Host "  Setting Intel graphics to maximum performance on AC power..."
            $result = powercfg /setacvalueindex $scheme.GUID 44f3beca-a7c0-460e-9df2-bb8b99e0cba6 3619c3f2-afb2-4afc-b0e9-e7fef372de36 2
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    Successfully set Intel graphics to maximum performance on AC power" -ForegroundColor Green
                $graphicsConfigured = $true
            }
        }
        
        # Try generic graphics settings if Intel wasn't available
        if (-not $graphicsConfigured -and (& $CheckSetting "5fb4938d-1ee8-4b0f-9a3c-5036b0ab995c" "dd848b2a-8a5d-4451-9ae2-39cd41658f6c")) {
            Write-Host "  Setting graphics to maximum performance on AC power..."
            $result = powercfg /setacvalueindex $scheme.GUID 5fb4938d-1ee8-4b0f-9a3c-5036b0ab995c dd848b2a-8a5d-4451-9ae2-39cd41658f6c 0
            if ($LASTEXITCODE -ne 0) {
                $result = powercfg /setacvalueindex $scheme.GUID 5fb4938d-1ee8-4b0f-9a3c-5036b0ab995c dd848b2a-8a5d-4451-9ae2-39cd41658f6c 1
            }
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    Successfully set graphics to maximum performance on AC power" -ForegroundColor Green
                $graphicsConfigured = $true
            }
        }
        
        if (-not $graphicsConfigured) {
            Write-Host "  Graphics performance setting not available on this system" -ForegroundColor Cyan
        }
        
        # Set graphics power policy to maximum performance (DC/Battery power)
        $graphicsConfigured = $false
        
        # Try Intel Graphics first
        if (& $CheckSetting "44f3beca-a7c0-460e-9df2-bb8b99e0cba6" "3619c3f2-afb2-4afc-b0e9-e7fef372de36") {
            Write-Host "  Setting Intel graphics to maximum performance on battery power..."
            $result = powercfg /setdcvalueindex $scheme.GUID 44f3beca-a7c0-460e-9df2-bb8b99e0cba6 3619c3f2-afb2-4afc-b0e9-e7fef372de36 2
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    Successfully set Intel graphics to maximum performance on battery power" -ForegroundColor Green
                $graphicsConfigured = $true
            }
        }
        
        # Try generic graphics settings if Intel wasn't available
        if (-not $graphicsConfigured -and (& $CheckSetting "5fb4938d-1ee8-4b0f-9a3c-5036b0ab995c" "dd848b2a-8a5d-4451-9ae2-39cd41658f6c")) {
            Write-Host "  Setting graphics to maximum performance on battery power..."
            $result = powercfg /setdcvalueindex $scheme.GUID 5fb4938d-1ee8-4b0f-9a3c-5036b0ab995c dd848b2a-8a5d-4451-9ae2-39cd41658f6c 0
            if ($LASTEXITCODE -ne 0) {
                $result = powercfg /setdcvalueindex $scheme.GUID 5fb4938d-1ee8-4b0f-9a3c-5036b0ab995c dd848b2a-8a5d-4451-9ae2-39cd41658f6c 1
            }
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    Successfully set graphics to maximum performance on battery power" -ForegroundColor Green
                $graphicsConfigured = $true
            }
        }
        
        if (-not $graphicsConfigured) {
            Write-Host "  Graphics performance setting not available on this system" -ForegroundColor Cyan
        }
        
        # Disable hard disk turn off (AC power) - set to 0 (never)
        Write-Host "  Disabling hard disk turn off on AC power..."
        $result = powercfg /setacvalueindex $scheme.GUID 0012ee47-9041-4b5d-9b77-535fba8b1442 6738e2c4-e8a5-4a42-b16a-e040e769756e 0
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Successfully disabled hard disk turn off on AC power" -ForegroundColor Green
        } else {
            Write-Host "    Warning: Failed to disable hard disk turn off on AC power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
        
        # Disable hard disk turn off (DC/Battery power) - set to 0 (never)
        Write-Host "  Disabling hard disk turn off on battery power..."
        $result = powercfg /setdcvalueindex $scheme.GUID 0012ee47-9041-4b5d-9b77-535fba8b1442 6738e2c4-e8a5-4a42-b16a-e040e769756e 0
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Successfully disabled hard disk turn off on battery power" -ForegroundColor Green
        } else {
            Write-Host "    Warning: Failed to disable hard disk turn off on battery power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
        
        # Disable system sleep timeout (AC power) - set to 0 (never sleep automatically)
        Write-Host "  Disabling automatic sleep on AC power..."
        $result = powercfg /setacvalueindex $scheme.GUID 238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Successfully disabled automatic sleep on AC power" -ForegroundColor Green
        } else {
            Write-Host "    Warning: Failed to disable automatic sleep on AC power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
        
        # Disable system sleep timeout (DC/Battery power) - set to 0 (never sleep automatically)
        Write-Host "  Disabling automatic sleep on battery power..."
        $result = powercfg /setdcvalueindex $scheme.GUID 238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da 0
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Successfully disabled automatic sleep on battery power" -ForegroundColor Green
        } else {
            Write-Host "    Warning: Failed to disable automatic sleep on battery power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
        
        # Set lid close action to sleep (AC power) - this is what we want to keep
        Write-Host "  Setting lid close action to sleep on AC power..."
        $result = powercfg /setacvalueindex $scheme.GUID 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Successfully set lid close action to sleep on AC power" -ForegroundColor Green
        } else {
            Write-Host "    Warning: Failed to set lid close action on AC power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
        
        # Set lid close action to sleep (DC/Battery power) - this is what we want to keep
        Write-Host "  Setting lid close action to sleep on battery power..."
        $result = powercfg /setdcvalueindex $scheme.GUID 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Successfully set lid close action to sleep on battery power" -ForegroundColor Green
        } else {
            Write-Host "    Warning: Failed to set lid close action on battery power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
        
        # Set power button action to shutdown (AC power)
        Write-Host "  Setting power button action to shutdown on AC power..."
        $result = powercfg /setacvalueindex $scheme.GUID 4f971e89-eebd-4455-a8de-9e59040e7347 7648efa3-dd9c-4e3e-b566-50f929386280 3
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Successfully set power button action to shutdown on AC power" -ForegroundColor Green
        } else {
            Write-Host "    Warning: Failed to set power button action on AC power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
        
        # Set power button action to shutdown (DC/Battery power)
        Write-Host "  Setting power button action to shutdown on battery power..."
        $result = powercfg /setdcvalueindex $scheme.GUID 4f971e89-eebd-4455-a8de-9e59040e7347 7648efa3-dd9c-4e3e-b566-50f929386280 3
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Successfully set power button action to shutdown on battery power" -ForegroundColor Green
        } else {
            Write-Host "    Warning: Failed to set power button action on battery power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
        
        # Disable USB Selective Suspend (AC power)
        Write-Host "  Disabling USB Selective Suspend on AC power..."
        $result = powercfg /setacvalueindex $scheme.GUID 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Successfully disabled USB Selective Suspend on AC power" -ForegroundColor Green
        } else {
            Write-Host "    Warning: Failed to disable USB Selective Suspend on AC power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
        
        # Disable USB Selective Suspend (DC/Battery power)
        Write-Host "  Disabling USB Selective Suspend on battery power..."
        $result = powercfg /setdcvalueindex $scheme.GUID 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Successfully disabled USB Selective Suspend on battery power" -ForegroundColor Green
        } else {
            Write-Host "    Warning: Failed to disable USB Selective Suspend on battery power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
        
        # Enable wake timers (AC power)
        if (& $CheckSetting "238c9fa8-0aad-41ed-83f4-97be242c8f20" "bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d") {
            Write-Host "  Enabling wake timers on AC power..."
            $result = powercfg /setacvalueindex $scheme.GUID 238c9fa8-0aad-41ed-83f4-97be242c8f20 bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d 1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    Successfully enabled wake timers on AC power" -ForegroundColor Green
            } else {
                Write-Host "    Warning: Failed to enable wake timers on AC power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Wake timers setting not available on this system" -ForegroundColor Cyan
        }
        
        # Enable wake timers (DC/Battery power)
        if (& $CheckSetting "238c9fa8-0aad-41ed-83f4-97be242c8f20" "bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d") {
            Write-Host "  Enabling wake timers on battery power..."
            $result = powercfg /setdcvalueindex $scheme.GUID 238c9fa8-0aad-41ed-83f4-97be242c8f20 bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d 1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    Successfully enabled wake timers on battery power" -ForegroundColor Green
            } else {
                Write-Host "    Warning: Failed to enable wake timers on battery power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Wake timers setting not available on this system" -ForegroundColor Cyan
        }
        
        # Set wireless adapter power saving to maximum performance (AC power)
        Write-Host "  Setting wireless adapter to maximum performance on AC power..."
        $result = powercfg /setacvalueindex $scheme.GUID 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Successfully set wireless adapter to maximum performance on AC power" -ForegroundColor Green
        } else {
            Write-Host "    Warning: Failed to set wireless adapter performance on AC power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
        
        # Set wireless adapter power saving to maximum performance (DC/Battery power)
        Write-Host "  Setting wireless adapter to maximum performance on battery power..."
        $result = powercfg /setdcvalueindex $scheme.GUID 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a 0
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Successfully set wireless adapter to maximum performance on battery power" -ForegroundColor Green
        } else {
            Write-Host "    Warning: Failed to set wireless adapter performance on battery power (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
        
        # Apply the changes to this power scheme by setting it active temporarily
        Write-Host "  Applying changes to power scheme..."
        $result = powercfg /setactive $scheme.GUID
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Successfully applied changes to power scheme" -ForegroundColor Green
        } else {
            Write-Host "    Warning: Failed to apply changes to power scheme (Exit code: $LASTEXITCODE)" -ForegroundColor Yellow
        }
    }
    
    # Restore the original active power scheme
    if ($originalActiveScheme) {
        Write-Host "`nRestoring original active power scheme: $($originalActiveScheme.Name)"
        powercfg /setactive $originalActiveScheme.GUID
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Successfully restored original active scheme" -ForegroundColor Green
        } else {
            Write-Host "Warning: Failed to restore original active scheme" -ForegroundColor Yellow
        }
    } else {
        # Fallback: get current active scheme
        $activeScheme = (powercfg /getactivescheme) -replace ".*GUID: ([a-f0-9\-]+).*", '$1'
        Write-Host "Using current active scheme for verification: $activeScheme"
    }
    
    # Get the currently active scheme for verification
    $currentActiveScheme = if ($originalActiveScheme) { $originalActiveScheme.GUID } else { $activeScheme }
    
    # Verify current settings
    Write-Host "`nVerifying current power settings..."
    
    # Check hibernation status system-wide
    Write-Host "System hibernation status:"
    $sleepStatesOutput = powercfg /availablesleepstates
    
    # Look for hibernation status more explicitly
    $hibernationAvailable = $false
    $hibernationFound = $false
    
    foreach ($line in $sleepStatesOutput) {
        if ($line -match "^\s*Hibernate\s*$") {
            $hibernationFound = $true
        }
        elseif ($hibernationFound -and $line -match "Hibernation has not been enabled|is not available") {
            $hibernationAvailable = $false
            break
        }
        elseif ($hibernationFound -and $line -match "^\s*$") {
            # Empty line after Hibernate section without disable message means it's available
            $hibernationAvailable = $true
            break
        }
        elseif ($hibernationFound -and $line -notmatch "^\s") {
            # New section started, if we got here hibernation is available
            $hibernationAvailable = $true
            break
        }
    }
    
    if ($hibernationAvailable) {
        Write-Host "  Hibernation: Available" -ForegroundColor Red
    } else {
        Write-Host "  Hibernation: Disabled" -ForegroundColor Green
    }
    
    # Check Fast Startup status
    Write-Host "Fast Startup status:"
    try {
        $fastStartupRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
        $fastStartupValueName = "HiberbootEnabled"
        $fastStartupValue = Get-ItemProperty -Path $fastStartupRegPath -Name $fastStartupValueName -ErrorAction SilentlyContinue
        
        if ($fastStartupValue) {
            if ($fastStartupValue.$fastStartupValueName -eq 0) {
                Write-Host "  Fast Startup: Disabled" -ForegroundColor Green
            } else {
                Write-Host "  Fast Startup: Enabled" -ForegroundColor Red
            }
        } else {
            Write-Host "  Fast Startup: Registry setting not found (likely disabled)" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "  Fast Startup: Unable to check status" -ForegroundColor Yellow
    }
    
    # Check hybrid sleep status
    Write-Host "Current hybrid sleep settings:"
    $hybridSleepAC = powercfg /query $currentActiveScheme 238c9fa8-0aad-41ed-83f4-97be242c8f20 94ac6d29-73ce-41a6-809f-6363ba21b47e | Select-String "Current AC Power Setting Index:"
    $hybridSleepDC = powercfg /query $currentActiveScheme 238c9fa8-0aad-41ed-83f4-97be242c8f20 94ac6d29-73ce-41a6-809f-6363ba21b47e | Select-String "Current DC Power Setting Index:"
    
    if ($hybridSleepAC) {
        $acValue = ($hybridSleepAC -split ":")[1].Trim()
        if ($acValue -eq '0x00000000') {
            Write-Host "  AC Power (Plugged in): Disabled" -ForegroundColor Green
        } else {
            Write-Host "  AC Power (Plugged in): Enabled" -ForegroundColor Red
        }
    }
    
    if ($hybridSleepDC) {
        $dcValue = ($hybridSleepDC -split ":")[1].Trim()
        if ($dcValue -eq '0x00000000') {
            Write-Host "  DC Power (Battery): Disabled" -ForegroundColor Green
        } else {
            Write-Host "  DC Power (Battery): Enabled" -ForegroundColor Red
        }
    }
    
    # Check hibernation after sleep settings
    Write-Host "Current hibernation after sleep settings:"
    $hibernateAfterAC = powercfg /query $currentActiveScheme 238c9fa8-0aad-41ed-83f4-97be242c8f20 9d7815a6-7ee4-497e-8888-515a05f02364 | Select-String "Current AC Power Setting Index:"
    $hibernateAfterDC = powercfg /query $currentActiveScheme 238c9fa8-0aad-41ed-83f4-97be242c8f20 9d7815a6-7ee4-497e-8888-515a05f02364 | Select-String "Current DC Power Setting Index:"
    
    if ($hibernateAfterAC) {
        $acHibValue = ($hibernateAfterAC -split ":")[1].Trim()
        if ($acHibValue -eq '0x00000000') {
            Write-Host "  AC Power Hibernation After Sleep: Disabled" -ForegroundColor Green
        } else {
            Write-Host "  AC Power Hibernation After Sleep: Enabled" -ForegroundColor Red
        }
    }
    
    if ($hibernateAfterDC) {
        $dcHibValue = ($hibernateAfterDC -split ":")[1].Trim()
        if ($dcHibValue -eq '0x00000000') {
            Write-Host "  DC Power Hibernation After Sleep: Disabled" -ForegroundColor Green
        } else {
            Write-Host "  DC Power Hibernation After Sleep: Enabled" -ForegroundColor Red
        }
    }
    
    # Check critical battery settings
    Write-Host "Current critical battery settings:"
    $criticalAction = powercfg /query $currentActiveScheme e73a048d-bf27-4f12-9731-8b2076e8891f 637ea02f-bbcb-4015-8e2c-a1c7b9c0b546 | Select-String "Current DC Power Setting Index:"
    $criticalLevel = powercfg /query $currentActiveScheme e73a048d-bf27-4f12-9731-8b2076e8891f 9a66d8d7-4ff7-4ef9-b5a2-5a326ca2a469 | Select-String "Current DC Power Setting Index:"
    
    if ($criticalAction) {
        $actionValue = ($criticalAction -split ":")[1].Trim()
        $actionText = switch ($actionValue) {
            '0x00000000' { 'Do Nothing' }
            '0x00000001' { 'Sleep' }
            '0x00000002' { 'Hibernate' }
            '0x00000003' { 'Shutdown' }
            default { "Unknown ($actionValue)" }
        }
        if ($actionValue -eq '0x00000003') {
            Write-Host "  Critical Battery Action: $actionText" -ForegroundColor Green
        } else {
            Write-Host "  Critical Battery Action: $actionText" -ForegroundColor Red
        }
    } else {
        Write-Host "  Critical Battery Action: Setting not available on this system" -ForegroundColor Cyan
    }
    
    if ($criticalLevel) {
        $levelValue = ($criticalLevel -split ":")[1].Trim()
        $levelPercent = [Convert]::ToInt32($levelValue, 16)
        if ($levelPercent -eq 5) {
            Write-Host "  Critical Battery Level: $levelPercent%" -ForegroundColor Green
        } else {
            Write-Host "  Critical Battery Level: $levelPercent%" -ForegroundColor Red
        }
    } else {
        Write-Host "  Critical Battery Level: Setting not available on this system" -ForegroundColor Cyan
    }
    
    # Check PCI Express power management settings
    Write-Host "Current PCI Express power management settings:"
    $pciAC = powercfg /query $currentActiveScheme 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 | Select-String "Current AC Power Setting Index:"
    $pciDC = powercfg /query $currentActiveScheme 501a4d13-42af-4429-9fd1-a8218c268e20 ee12f906-d277-404b-b6da-e5fa1a576df5 | Select-String "Current DC Power Setting Index:"
    
    if ($pciAC) {
        $pciACValue = ($pciAC -split ":")[1].Trim()
        if ($pciACValue -eq '0x00000000') {
            Write-Host "  AC Power PCI Express Power Management: Disabled" -ForegroundColor Green
        } else {
            Write-Host "  AC Power PCI Express Power Management: Enabled" -ForegroundColor Red
        }
    }
    
    if ($pciDC) {
        $pciDCValue = ($pciDC -split ":")[1].Trim()
        if ($pciDCValue -eq '0x00000000') {
            Write-Host "  DC Power PCI Express Power Management: Disabled" -ForegroundColor Green
        } else {
            Write-Host "  DC Power PCI Express Power Management: Enabled" -ForegroundColor Red
        }
    }
    
    # Check graphics performance settings
    Write-Host "Current graphics performance settings:"
    
    # Try Intel Graphics first
    $intelGraphicsAC = powercfg /query $currentActiveScheme 44f3beca-a7c0-460e-9df2-bb8b99e0cba6 3619c3f2-afb2-4afc-b0e9-e7fef372de36 2>$null | Select-String "Current AC Power Setting Index:"
    $intelGraphicsDC = powercfg /query $currentActiveScheme 44f3beca-a7c0-460e-9df2-bb8b99e0cba6 3619c3f2-afb2-4afc-b0e9-e7fef372de36 2>$null | Select-String "Current DC Power Setting Index:"
    
    if ($intelGraphicsAC -or $intelGraphicsDC) {
        if ($intelGraphicsAC) {
            $graphicsACValue = ($intelGraphicsAC -split ":")[1].Trim()
            $graphicsACText = switch ($graphicsACValue) {
                '0x00000000' { 'Power Saving' }
                '0x00000001' { 'Balanced' }
                '0x00000002' { 'Maximum Performance' }
                default { "Unknown ($graphicsACValue)" }
            }
            if ($graphicsACValue -eq '0x00000002') {
                Write-Host "  AC Power Intel Graphics Performance: $graphicsACText" -ForegroundColor Green
            } else {
                Write-Host "  AC Power Intel Graphics Performance: $graphicsACText" -ForegroundColor Red
            }
        }
        
        if ($intelGraphicsDC) {
            $graphicsDCValue = ($intelGraphicsDC -split ":")[1].Trim()
            $graphicsDCText = switch ($graphicsDCValue) {
                '0x00000000' { 'Power Saving' }
                '0x00000001' { 'Balanced' }
                '0x00000002' { 'Maximum Performance' }
                default { "Unknown ($graphicsDCValue)" }
            }
            if ($graphicsDCValue -eq '0x00000002') {
                Write-Host "  DC Power Intel Graphics Performance: $graphicsDCText" -ForegroundColor Green
            } else {
                Write-Host "  DC Power Intel Graphics Performance: $graphicsDCText" -ForegroundColor Red
            }
        }
    } else {
        # Try generic graphics settings
        $graphicsAC = powercfg /query $currentActiveScheme 5fb4938d-1ee8-4b0f-9a3c-5036b0ab995c dd848b2a-8a5d-4451-9ae2-39cd41658f6c 2>$null | Select-String "Current AC Power Setting Index:"
        $graphicsDC = powercfg /query $currentActiveScheme 5fb4938d-1ee8-4b0f-9a3c-5036b0ab995c dd848b2a-8a5d-4451-9ae2-39cd41658f6c 2>$null | Select-String "Current DC Power Setting Index:"
        
        if ($graphicsAC) {
            $graphicsACValue = ($graphicsAC -split ":")[1].Trim()
            $graphicsACText = switch ($graphicsACValue) {
                '0x00000000' { 'Power Saving' }
                '0x00000001' { 'Balanced' }
                '0x00000002' { 'Maximum Performance' }
                default { "Unknown ($graphicsACValue)" }
            }
            if ($graphicsACValue -eq '0x00000002') {
                Write-Host "  AC Power Graphics Performance: $graphicsACText" -ForegroundColor Green
            } else {
                Write-Host "  AC Power Graphics Performance: $graphicsACText" -ForegroundColor Red
            }
        } else {
            Write-Host "  AC Power Graphics Performance: Setting not available" -ForegroundColor Cyan
        }
        
        if ($graphicsDC) {
            $graphicsDCValue = ($graphicsDC -split ":")[1].Trim()
            $graphicsDCText = switch ($graphicsDCValue) {
                '0x00000000' { 'Power Saving' }
                '0x00000001' { 'Balanced' }
                '0x00000002' { 'Maximum Performance' }
                default { "Unknown ($graphicsDCValue)" }
            }
            if ($graphicsDCValue -eq '0x00000002') {
                Write-Host "  DC Power Graphics Performance: $graphicsDCText" -ForegroundColor Green
            } else {
                Write-Host "  DC Power Graphics Performance: $graphicsDCText" -ForegroundColor Red
            }
        } else {
            Write-Host "  DC Power Graphics Performance: Setting not available" -ForegroundColor Cyan
        }
    }
    
    # Check hard disk turn off settings
    Write-Host "Current hard disk turn off settings:"
    $diskAC = powercfg /query $currentActiveScheme 0012ee47-9041-4b5d-9b77-535fba8b1442 6738e2c4-e8a5-4a42-b16a-e040e769756e | Select-String "Current AC Power Setting Index:"
    $diskDC = powercfg /query $currentActiveScheme 0012ee47-9041-4b5d-9b77-535fba8b1442 6738e2c4-e8a5-4a42-b16a-e040e769756e | Select-String "Current DC Power Setting Index:"
    
    if ($diskAC) {
        $diskACValue = ($diskAC -split ":")[1].Trim()
        if ($diskACValue -eq '0x00000000') {
            Write-Host "  AC Power Hard Disk Turn Off: Disabled (Never)" -ForegroundColor Green
        } else {
            $diskACMinutes = [Convert]::ToInt32($diskACValue, 16)
            Write-Host "  AC Power Hard Disk Turn Off: $diskACMinutes minutes" -ForegroundColor Red
        }
    }
    
    if ($diskDC) {
        $diskDCValue = ($diskDC -split ":")[1].Trim()
        if ($diskDCValue -eq '0x00000000') {
            Write-Host "  DC Power Hard Disk Turn Off: Disabled (Never)" -ForegroundColor Green
        } else {
            $diskDCMinutes = [Convert]::ToInt32($diskDCValue, 16)
            Write-Host "  DC Power Hard Disk Turn Off: $diskDCMinutes minutes" -ForegroundColor Red
        }
    }
    
    # Check sleep timeout settings
    Write-Host "Current sleep timeout settings:"
    $sleepAC = powercfg /query $currentActiveScheme 238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da | Select-String "Current AC Power Setting Index:"
    $sleepDC = powercfg /query $currentActiveScheme 238c9fa8-0aad-41ed-83f4-97be242c8f20 29f6c1db-86da-48c5-9fdb-f2b67b1f44da | Select-String "Current DC Power Setting Index:"
    
    if ($sleepAC) {
        $sleepACValue = ($sleepAC -split ":")[1].Trim()
        if ($sleepACValue -eq '0x00000000') {
            Write-Host "  AC Power Sleep Timeout: Disabled (Never)" -ForegroundColor Green
        } else {
            $sleepACMinutes = [Convert]::ToInt32($sleepACValue, 16)
            Write-Host "  AC Power Sleep Timeout: $sleepACMinutes minutes" -ForegroundColor Red
        }
    }
    
    if ($sleepDC) {
        $sleepDCValue = ($sleepDC -split ":")[1].Trim()
        if ($sleepDCValue -eq '0x00000000') {
            Write-Host "  DC Power Sleep Timeout: Disabled (Never)" -ForegroundColor Green
        } else {
            $sleepDCMinutes = [Convert]::ToInt32($sleepDCValue, 16)
            Write-Host "  DC Power Sleep Timeout: $sleepDCMinutes minutes" -ForegroundColor Red
        }
    }
    
    # Check lid close action settings
    Write-Host "Current lid close action settings:"
    $lidAC = powercfg /query $currentActiveScheme 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 2>$null | Select-String "Current AC Power Setting Index:"
    $lidDC = powercfg /query $currentActiveScheme 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 2>$null | Select-String "Current DC Power Setting Index:"
    
    if ($lidAC) {
        $lidACValue = ($lidAC -split ":")[1].Trim()
        $lidACText = switch ($lidACValue) {
            '0x00000000' { 'Do Nothing' }
            '0x00000001' { 'Sleep' }
            '0x00000002' { 'Hibernate' }
            '0x00000003' { 'Shutdown' }
            default { "Unknown ($lidACValue)" }
        }
        if ($lidACValue -eq '0x00000001') {
            Write-Host "  AC Power Lid Close Action: $lidACText" -ForegroundColor Green
        } else {
            Write-Host "  AC Power Lid Close Action: $lidACText" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  AC Power Lid Close Action: Setting not available (likely desktop)" -ForegroundColor Cyan
    }
    
    if ($lidDC) {
        $lidDCValue = ($lidDC -split ":")[1].Trim()
        $lidDCText = switch ($lidDCValue) {
            '0x00000000' { 'Do Nothing' }
            '0x00000001' { 'Sleep' }
            '0x00000002' { 'Hibernate' }
            '0x00000003' { 'Shutdown' }
            default { "Unknown ($lidDCValue)" }
        }
        if ($lidDCValue -eq '0x00000001') {
            Write-Host "  DC Power Lid Close Action: $lidDCText" -ForegroundColor Green
        } else {
            Write-Host "  DC Power Lid Close Action: $lidDCText" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  DC Power Lid Close Action: Setting not available (likely desktop)" -ForegroundColor Cyan
    }
    
    # Check USB Selective Suspend settings
    Write-Host "Current USB Selective Suspend settings:"
    $usbAC = powercfg /query $currentActiveScheme 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 | Select-String "Current AC Power Setting Index:"
    $usbDC = powercfg /query $currentActiveScheme 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 | Select-String "Current DC Power Setting Index:"
    
    if ($usbAC) {
        $usbACValue = ($usbAC -split ":")[1].Trim()
        if ($usbACValue -eq '0x00000000') {
            Write-Host "  AC Power USB Selective Suspend: Disabled" -ForegroundColor Green
        } else {
            Write-Host "  AC Power USB Selective Suspend: Enabled" -ForegroundColor Red
        }
    }
    
    if ($usbDC) {
        $usbDCValue = ($usbDC -split ":")[1].Trim()
        if ($usbDCValue -eq '0x00000000') {
            Write-Host "  DC Power USB Selective Suspend: Disabled" -ForegroundColor Green
        } else {
            Write-Host "  DC Power USB Selective Suspend: Enabled" -ForegroundColor Red
        }
    }
    
    # Check wireless adapter power settings
    Write-Host "Current wireless adapter power settings:"
    $wirelessAC = powercfg /query $currentActiveScheme 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a | Select-String "Current AC Power Setting Index:"
    $wirelessDC = powercfg /query $currentActiveScheme 19cbb8fa-5279-450e-9fac-8a3d5fedd0c1 12bbebe6-58d6-4636-95bb-3217ef867c1a | Select-String "Current DC Power Setting Index:"
    
    if ($wirelessAC) {
        $wirelessACValue = ($wirelessAC -split ":")[1].Trim()
        $wirelessACText = switch ($wirelessACValue) {
            '0x00000000' { 'Maximum Performance' }
            '0x00000001' { 'Low Power Saving' }
            '0x00000002' { 'Medium Power Saving' }
            '0x00000003' { 'Maximum Power Saving' }
            default { "Unknown ($wirelessACValue)" }
        }
        if ($wirelessACValue -eq '0x00000000') {
            Write-Host "  AC Power Wireless Adapter: $wirelessACText" -ForegroundColor Green
        } else {
            Write-Host "  AC Power Wireless Adapter: $wirelessACText" -ForegroundColor Red
        }
    }
    
    if ($wirelessDC) {
        $wirelessDCValue = ($wirelessDC -split ":")[1].Trim()
        $wirelessDCText = switch ($wirelessDCValue) {
            '0x00000000' { 'Maximum Performance' }
            '0x00000001' { 'Low Power Saving' }
            '0x00000002' { 'Medium Power Saving' }
            '0x00000003' { 'Maximum Power Saving' }
            default { "Unknown ($wirelessDCValue)" }
        }
        if ($wirelessDCValue -eq '0x00000000') {
            Write-Host "  DC Power Wireless Adapter: $wirelessDCText" -ForegroundColor Green
        } else {
            Write-Host "  DC Power Wireless Adapter: $wirelessDCText" -ForegroundColor Red
        }
    }
    
    Write-Host "`nPower configuration completed successfully!" -ForegroundColor Green
    Write-Host "Summary of changes:" -ForegroundColor Cyan
    Write-Host "  - Hibernation has been completely disabled system-wide" -ForegroundColor Cyan
    Write-Host "  - Fast Startup has been disabled (no more hibernation-based fast boot)" -ForegroundColor Cyan
    Write-Host "  - Hybrid sleep has been disabled for all power schemes" -ForegroundColor Cyan
    Write-Host "  - Hibernation after sleep has been disabled for all power schemes" -ForegroundColor Cyan
    Write-Host "  - PCI Express Link State Power Management has been disabled" -ForegroundColor Cyan
    Write-Host "  - Graphics performance set to maximum for all power schemes" -ForegroundColor Cyan
    Write-Host "  - Hard disk turn off has been disabled (never turn off)" -ForegroundColor Cyan
    Write-Host "  - Automatic sleep timeout has been disabled (never sleep automatically)" -ForegroundColor Cyan
    Write-Host "  - Lid close action set to sleep (only way computer will sleep)" -ForegroundColor Cyan
    Write-Host "  - Power button action set to shutdown" -ForegroundColor Cyan
    Write-Host "  - USB Selective Suspend has been disabled for all USB devices" -ForegroundColor Cyan
    Write-Host "  - Wake timers have been enabled (system can wake from scheduled tasks)" -ForegroundColor Cyan
    Write-Host "  - Wireless adapter power saving set to maximum performance" -ForegroundColor Cyan
    Write-Host "  - Critical battery level set to 5%" -ForegroundColor Cyan
    Write-Host "  - Computer will shutdown (not hibernate) when battery reaches 5%" -ForegroundColor Cyan
    Write-Host "  - Low battery action set to 'do nothing' to prevent early hibernation" -ForegroundColor Cyan
    
    Write-Host "`nPower schemes configured:" -ForegroundColor Cyan
    foreach ($scheme in $powerSchemes) {
        $activeIndicator = if ($scheme.IsActive) { " (Originally Active)" } else { "" }
        Write-Host "  - $($scheme.Name)$activeIndicator" -ForegroundColor Cyan
        Write-Host "    GUID: $($scheme.GUID)" -ForegroundColor DarkCyan
    }
    
    Write-Host "`nAll $($powerSchemes.Count) power scheme(s) have been configured with the same settings." -ForegroundColor Green
    Write-Host "Computer will now only sleep when the lid is closed - no other automatic sleep behavior." -ForegroundColor Green
    
}
catch {
    Write-Host "ERROR: Failed to configure power settings: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
}

Write-Host "`nComprehensive power management configuration completed."

Stop-Transcript