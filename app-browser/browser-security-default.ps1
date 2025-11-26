#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Removes enforced security settings for Chrome, Firefox, and Edge browsers.

.DESCRIPTION
    This script removes registry-based security policies to allow users to modify
    their browser settings again:
    - Chrome: Removes all enforced security policies from registry
    - Firefox: Restores backup prefs.js files or removes forced settings
    - Edge: Removes Enhanced Security Mode enforcement
    
    Designed to run from NinjaRMM or other RMM platforms.

.NOTES
    Author: Browser Security Policy Removal Script
    Requires: Administrator privileges
#>

# Error handling
$ErrorActionPreference = "Stop"
$logFile = "$env:ProgramData\BrowserSecurityRemoval.log"

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $logFile -Append
    Write-Host $Message -ForegroundColor $Color
}

Write-Log "======================================================================" "Cyan"
Write-Log "=== Browser Security Policy Removal Started ===" "Cyan"
Write-Log "======================================================================" "Cyan"
Write-Log ""

#region Chrome Policy Removal

Write-Log "--- CHROME POLICY REMOVAL ---" "Yellow"

# Check if Chrome is installed
$chromeInstalled = $false
$chromePaths = @(
    "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)

foreach ($path in $chromePaths) {
    if (Test-Path $path) {
        $chromeInstalled = $true
        Write-Log "Chrome found at: $path" "Green"
        break
    }
}

if (-not $chromeInstalled) {
    Write-Log "Chrome is not installed - skipping Chrome policy removal" "Gray"
} else {
    Write-Log "Removing Chrome security policies..." "Cyan"
    
    $chromePolicyPath = "HKLM:\SOFTWARE\Policies\Google\Chrome"
    
    if (Test-Path $chromePolicyPath) {
        try {
            # List of policies to remove
            $policiesToRemove = @(
                "BlockThirdPartyCookies",
                "SafeBrowsingProtectionLevel",
                "SafeBrowsingForTrustedSourcesEnabled",
                "AllowOutdatedPlugins",
                "HttpsOnlyMode",
                "DnsOverHttpsMode",
                "SitePerProcess",
                "AutofillCreditCardEnabled",
                "AutofillAddressEnabled",
                "RendererCodeIntegrityEnabled",
                "DefaultPopupsSetting",
                "DefaultPluginsSetting",
                "UpdatesSuppressed",
                "InsecureDownloadAllowed",
                "BrowserGuestModeEnabled",
                "ChromeCleanupEnabled",
                "ChromeCleanupReportingEnabled",
                "PasswordManagerEnabled",
                "IncognitoModeAvailability",
                "DeveloperToolsDisabled"
            )
            
            $chromeRemovedCount = 0
            
            foreach ($policy in $policiesToRemove) {
                try {
                    Remove-ItemProperty -Path $chromePolicyPath -Name $policy -ErrorAction SilentlyContinue
                    Write-Log "  Removed: $policy" "Green"
                    $chromeRemovedCount++
                } catch {
                    # Policy might not exist, continue
                }
            }
            
            # Remove InsecureContentBlockedForUrls subkey
            $insecureContentPath = "$chromePolicyPath\InsecureContentBlockedForUrls"
            if (Test-Path $insecureContentPath) {
                Remove-Item -Path $insecureContentPath -Recurse -Force
                Write-Log "  Removed: InsecureContentBlockedForUrls" "Green"
            }
            
            # Optional: Remove entire Chrome policy key if empty
            $remainingPolicies = Get-ItemProperty -Path $chromePolicyPath -ErrorAction SilentlyContinue
            if ($null -eq $remainingPolicies -or ($remainingPolicies.PSObject.Properties.Name | Where-Object { $_ -notlike "PS*" }).Count -eq 0) {
                Remove-Item -Path $chromePolicyPath -Force -ErrorAction SilentlyContinue
                Write-Log "  Removed entire Chrome policy registry key (was empty)" "Green"
            }
            
            Write-Log "Chrome: Successfully removed $chromeRemovedCount policies" "Cyan"
            
        } catch {
            Write-Log "ERROR: Failed to remove Chrome policies - $_" "Red"
        }
    } else {
        Write-Log "No Chrome policies found to remove" "Gray"
    }
}

Write-Log ""

#endregion

#region Firefox Policy Restoration

Write-Log "--- FIREFOX POLICY RESTORATION ---" "Yellow"

# Check if Firefox is installed
$firefoxInstalled = $false
$firefoxPaths = @(
    "C:\Program Files\Mozilla Firefox\firefox.exe",
    "C:\Program Files (x86)\Mozilla Firefox\firefox.exe"
)

# Check traditional installation paths
foreach ($path in $firefoxPaths) {
    if (Test-Path $path) {
        $firefoxInstalled = $true
        Write-Log "Firefox installation found at: $path" "Green"
        break
    }
}

# Check Microsoft Store installation
if (-not $firefoxInstalled) {
    $storeFirefoxPath = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps" -Filter "Mozilla.Firefox*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($storeFirefoxPath) {
        $firefoxInstalled = $true
        Write-Log "Firefox (Microsoft Store) installation found at: $($storeFirefoxPath.FullName)" "Green"
    }
}

if (-not $firefoxInstalled) {
    Write-Log "Firefox is not installed - skipping Firefox restoration" "Gray"
} else {
    Write-Log "Restoring Firefox user preferences..." "Cyan"
    
    # Get all user profiles on the system
    $userProfiles = Get-ChildItem "C:\Users" -Directory | Where-Object { 
        $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') 
    }
    
    Write-Log "Found $($userProfiles.Count) user profile(s)" "Cyan"
    
    $firefoxRestoredCount = 0
    $firefoxFailCount = 0
    
    foreach ($userProfile in $userProfiles) {
        $userName = $userProfile.Name
        $firefoxProfilePath = Join-Path $userProfile.FullName "AppData\Roaming\Mozilla\Firefox\Profiles"
        
        Write-Log "  Checking user: $userName" "White"
        
        if (Test-Path $firefoxProfilePath) {
            # Get Firefox profiles
            $profiles = Get-ChildItem -Path $firefoxProfilePath -Directory | Where-Object { 
                $_.Name -like "*.default*" 
            }
            
            if ($profiles) {
                foreach ($profile in $profiles) {
                    $prefsFile = Join-Path $profile.FullName "prefs.js"
                    $backupFile = "$prefsFile.backup"
                    
                    if (Test-Path $backupFile) {
                        Write-Log "    Found backup for profile: $($profile.Name)" "White"
                        
                        try {
                            # Restore from backup
                            Copy-Item $backupFile $prefsFile -Force
                            Write-Log "    Restored from backup for $userName" "Green"
                            $firefoxRestoredCount++
                            
                            # Optional: Remove backup file
                            # Remove-Item $backupFile -Force
                            
                        } catch {
                            Write-Log "    Could not restore backup - $($_.Exception.Message)" "Red"
                            $firefoxFailCount++
                        }
                    } elseif (Test-Path $prefsFile) {
                        # No backup exists, remove forced settings
                        Write-Log "    No backup found, removing forced settings from: $($profile.Name)" "White"
                        
                        try {
                            $content = Get-Content $prefsFile -Raw -ErrorAction Stop
                            
                            # Remove the forced tracking protection settings
                            $content = $content -replace 'user_pref\("browser\.contentblocking\.category", "standard"\);[\r\n]*', ''
                            $content = $content -replace 'user_pref\("privacy\.trackingprotection\.enabled", false\);[\r\n]*', ''
                            $content = $content -replace 'user_pref\("privacy\.trackingprotection\.pbmode\.enabled", true\);[\r\n]*', ''
                            $content = $content -replace 'user_pref\("privacy\.trackingprotection\.socialtracking\.enabled", true\);[\r\n]*', ''
                            $content = $content -replace 'user_pref\("privacy\.trackingprotection\.cryptomining\.enabled", true\);[\r\n]*', ''
                            $content = $content -replace 'user_pref\("privacy\.trackingprotection\.fingerprinting\.enabled", true\);[\r\n]*', ''
                            
                            # Write cleaned content
                            Set-Content $prefsFile $content -NoNewline -Force
                            
                            Write-Log "    Removed forced settings for $userName" "Green"
                            $firefoxRestoredCount++
                            
                        } catch {
                            Write-Log "    Could not modify prefs.js - $($_.Exception.Message)" "Red"
                            $firefoxFailCount++
                        }
                    } else {
                        Write-Log "    No prefs.js file found" "Gray"
                    }
                }
            } else {
                Write-Log "    No Firefox profiles found for this user" "Gray"
            }
        } else {
            Write-Log "    No Firefox profile path found for this user" "Gray"
        }
    }
    
    Write-Log "Firefox: Successfully restored $firefoxRestoredCount profile(s), $firefoxFailCount failed" "Cyan"
    
    # Optional: Kill Firefox processes to apply changes immediately
    $firefoxProcesses = Get-Process -Name "firefox" -ErrorAction SilentlyContinue
    if ($firefoxProcesses) {
        Write-Log "Closing Firefox processes to apply changes..." "Yellow"
        Stop-Process -Name "firefox" -Force
        Write-Log "Firefox closed - changes will apply on next launch" "Green"
    }
}

Write-Log ""

#endregion

#region Edge Policy Removal

Write-Log "--- MICROSOFT EDGE POLICY REMOVAL ---" "Yellow"

# Check if Edge is installed
$edgeInstalled = $false
$edgePaths = @(
    "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
)

foreach ($path in $edgePaths) {
    if (Test-Path $path) {
        $edgeInstalled = $true
        Write-Log "Edge found at: $path" "Green"
        break
    }
}

if (-not $edgeInstalled) {
    Write-Log "Microsoft Edge is not installed - skipping Edge policy removal" "Gray"
} else {
    Write-Log "Removing Edge security policies..." "Cyan"
    
    $edgeRegistryPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    
    if (Test-Path $edgeRegistryPath) {
        try {
            # Remove EnhanceSecurityMode setting
            Remove-ItemProperty -Path $edgeRegistryPath -Name "EnhanceSecurityMode" -ErrorAction SilentlyContinue
            Write-Log "  Removed: EnhanceSecurityMode" "Green"
            
            # Optional: Remove entire Edge policy key if empty
            $remainingPolicies = Get-ItemProperty -Path $edgeRegistryPath -ErrorAction SilentlyContinue
            if ($null -eq $remainingPolicies -or ($remainingPolicies.PSObject.Properties.Name | Where-Object { $_ -notlike "PS*" }).Count -eq 0) {
                Remove-Item -Path $edgeRegistryPath -Force -ErrorAction SilentlyContinue
                Write-Log "  Removed entire Edge policy registry key (was empty)" "Green"
            }
            
            Write-Log "Edge: Successfully removed Enhanced Security Mode enforcement" "Cyan"
            $edgeSuccess = $true
            
        } catch {
            Write-Log "ERROR: Failed to remove Edge policies - $_" "Red"
            $edgeSuccess = $false
        }
    } else {
        Write-Log "No Edge policies found to remove" "Gray"
        $edgeSuccess = $true
    }
}

Write-Log ""

#endregion

#region Summary

Write-Log "======================================================================" "Cyan"
Write-Log "=== Policy Removal Summary ===" "Cyan"
Write-Log "======================================================================" "Cyan"

if ($chromeInstalled) {
    Write-Log "Chrome: Policies removed - users can now modify settings" "White"
}
if ($firefoxInstalled) {
    Write-Log "Firefox: $firefoxRestoredCount profiles restored, $firefoxFailCount failed" "White"
}
if ($edgeInstalled) {
    if ($edgeSuccess) {
        Write-Log "Edge: Policy removed - users can now modify settings" "White"
    } else {
        Write-Log "Edge: Removal failed" "White"
    }
}

Write-Log ""
Write-Log "Log file location: $logFile" "Cyan"
Write-Log ""
Write-Log "IMPORTANT: Please restart all browsers for changes to take effect" "Yellow"
Write-Log "Users can now modify their browser security settings through browser preferences" "Green"
Write-Log ""
Write-Log "Script completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "Cyan"
Write-Log "======================================================================" "Cyan"

# Determine exit code
$overallSuccess = $true
if ($firefoxInstalled -and $firefoxFailCount -gt 0) { $overallSuccess = $false }
if ($edgeInstalled -and -not $edgeSuccess) { $overallSuccess = $false }

if ($overallSuccess) {
    exit 0
} else {
    exit 1
}

#endregion
