#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Configures enhanced security settings for Chrome, Firefox, and Edge browsers.

.DESCRIPTION
    This unified script sets security policies across all major browsers:
    - Chrome: Enhanced Safe Browsing and strict security policies via registry
    - Firefox: Standard Enhanced Tracking Protection via user profiles
    - Edge: Balanced Enhanced Security Mode via registry
    
    Designed to run from NinjaRMM or other RMM platforms.

.NOTES
    Author: Unified Browser Security Script
    Requires: Administrator privileges
#>

# Error handling
$ErrorActionPreference = "Stop"
$logFile = "$env:ProgramData\BrowserSecurityConfig.log"

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $logFile -Append
    Write-Host $Message -ForegroundColor $Color
}

Write-Log "======================================================================" "Cyan"
Write-Log "=== Unified Browser Security Configuration Started ===" "Cyan"
Write-Log "======================================================================" "Cyan"
Write-Log ""

#region Chrome Configuration

Write-Log "--- CHROME CONFIGURATION ---" "Yellow"

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
        $chromeVersion = (Get-Item $path).VersionInfo.FileVersion
        Write-Log "Chrome found at: $path (Version: $chromeVersion)" "Green"
        break
    }
}

if (-not $chromeInstalled) {
    Write-Log "Chrome is not installed - skipping Chrome configuration" "Gray"
} else {
    Write-Log "Proceeding with Chrome security configuration..." "Cyan"
    
    # Define Chrome policy registry path
    $chromePolicyPath = "HKLM:\SOFTWARE\Policies\Google\Chrome"
    
    # Create registry path if it doesn't exist
    try {
        if (-not (Test-Path $chromePolicyPath)) {
            New-Item -Path $chromePolicyPath -Force | Out-Null
            Write-Log "Created Chrome policy registry path" "Green"
        }
    } catch {
        Write-Log "ERROR: Failed to create Chrome registry path - $_" "Red"
    }
    
    # Enhanced Security Settings
    $securitySettings = @{
        "BlockThirdPartyCookies" = 1
        "SafeBrowsingProtectionLevel" = 2
        "SafeBrowsingForTrustedSourcesEnabled" = 0
        "AllowOutdatedPlugins" = 0
        "HttpsOnlyMode" = "force_enabled"
        "DnsOverHttpsMode" = "automatic"
        "SitePerProcess" = 1
        "AutofillCreditCardEnabled" = 0
        "AutofillAddressEnabled" = 0
        "RendererCodeIntegrityEnabled" = 1
        "DefaultPopupsSetting" = 2
        "DefaultPluginsSetting" = 2
        "UpdatesSuppressed" = 0
        "InsecureDownloadAllowed" = 0
        "BrowserGuestModeEnabled" = 0
        "ChromeCleanupEnabled" = 1
        "ChromeCleanupReportingEnabled" = 1
    }
    
    # Apply settings
    $chromeSuccessCount = 0
    $chromeFailCount = 0
    
    foreach ($setting in $securitySettings.GetEnumerator()) {
        try {
            $value = $setting.Value
            $valueType = if ($value -is [int]) { "DWord" } else { "String" }
            
            Set-ItemProperty -Path $chromePolicyPath -Name $setting.Key -Value $value -Type $valueType -Force
            Write-Log "  Set: $($setting.Key) = $value" "Green"
            $chromeSuccessCount++
        } catch {
            Write-Log "  Failed to set $($setting.Key) - $_" "Red"
            $chromeFailCount++
        }
    }
    
    # Handle array-based policies
    try {
        $insecureContentPath = "$chromePolicyPath\InsecureContentBlockedForUrls"
        if (-not (Test-Path $insecureContentPath)) {
            New-Item -Path $insecureContentPath -Force | Out-Null
        }
        Set-ItemProperty -Path $insecureContentPath -Name "1" -Value "*" -Type String -Force
        Write-Log "  Configured InsecureContentBlockedForUrls" "Green"
    } catch {
        Write-Log "  Could not configure InsecureContentBlockedForUrls - $_" "Red"
    }
    
    Write-Log "Chrome: Successfully applied $chromeSuccessCount settings, $chromeFailCount failed" "Cyan"
}

Write-Log ""

#endregion

#region Firefox Configuration

Write-Log "--- FIREFOX CONFIGURATION ---" "Yellow"

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
    Write-Log "Firefox is not installed - skipping Firefox configuration" "Gray"
} else {
    Write-Log "Proceeding with Firefox configuration..." "Cyan"
    
    # Get all user profiles on the system
    $userProfiles = Get-ChildItem "C:\Users" -Directory | Where-Object { 
        $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') 
    }
    
    Write-Log "Found $($userProfiles.Count) user profile(s)" "Cyan"
    
    $firefoxSuccessCount = 0
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
                    
                    if (Test-Path $prefsFile) {
                        Write-Log "    Processing profile: $($profile.Name)" "White"
                        
                        try {
                            # Read the prefs.js file
                            $content = Get-Content $prefsFile -Raw -ErrorAction Stop
                            
                            # Settings for Standard tracking protection
                            $standardSettings = @(
                                'user_pref("browser.contentblocking.category", "standard");',
                                'user_pref("privacy.trackingprotection.enabled", false);',
                                'user_pref("privacy.trackingprotection.pbmode.enabled", true);',
                                'user_pref("privacy.trackingprotection.socialtracking.enabled", true);',
                                'user_pref("privacy.trackingprotection.cryptomining.enabled", true);',
                                'user_pref("privacy.trackingprotection.fingerprinting.enabled", true);'
                            )
                            
                            # Remove existing related preferences
                            $content = $content -replace 'user_pref\("browser\.contentblocking\.category",.*?\);', ''
                            $content = $content -replace 'user_pref\("privacy\.trackingprotection\.enabled",.*?\);', ''
                            $content = $content -replace 'user_pref\("privacy\.trackingprotection\.pbmode\.enabled",.*?\);', ''
                            
                            # Add standard settings
                            $newContent = $content.TrimEnd() + "`n" + ($standardSettings -join "`n") + "`n"
                            
                            # Backup original file
                            Copy-Item $prefsFile "$prefsFile.backup" -Force
                            
                            # Write new content
                            Set-Content $prefsFile $newContent -NoNewline -Force
                            
                            Write-Log "    Set to Standard for $userName" "Green"
                            $firefoxSuccessCount++
                            
                        } catch {
                            Write-Log "    Could not modify prefs.js - $($_.Exception.Message)" "Red"
                            $firefoxFailCount++
                        }
                    }
                }
            } else {
                Write-Log "    No Firefox profiles found for this user" "Gray"
            }
        } else {
            Write-Log "    No Firefox profile path found for this user" "Gray"
        }
    }
    
    Write-Log "Firefox: Successfully configured $firefoxSuccessCount profile(s), $firefoxFailCount failed" "Cyan"
    
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

#region Edge Configuration

Write-Log "--- MICROSOFT EDGE CONFIGURATION ---" "Yellow"

# Check if Edge is installed
$edgeInstalled = $false
$edgePaths = @(
    "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
)

foreach ($path in $edgePaths) {
    if (Test-Path $path) {
        $edgeInstalled = $true
        $edgeVersion = (Get-Item $path).VersionInfo.FileVersion
        Write-Log "Edge found at: $path (Version: $edgeVersion)" "Green"
        break
    }
}

if (-not $edgeInstalled) {
    Write-Log "Microsoft Edge is not installed - skipping Edge configuration" "Gray"
} else {
    Write-Log "Proceeding with Edge security configuration..." "Cyan"
    
    # Registry path for Edge policies
    $edgeRegistryPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    
    # Check if registry path exists, create if it doesn't
    if (-not (Test-Path $edgeRegistryPath)) {
        New-Item -Path $edgeRegistryPath -Force | Out-Null
        Write-Log "Created Edge registry path: $edgeRegistryPath" "Green"
    }
    
    # Set EnhanceSecurityMode to 1 (Balanced)
    # Values: 0 = Basic (off), 1 = Balanced, 2 = Strict
    try {
        Set-ItemProperty -Path $edgeRegistryPath -Name "EnhanceSecurityMode" -Value 1 -Type DWord -Force
        Write-Log "  Set 'Enhance your security on the web' to Balanced" "Green"
        
        # Verify the setting
        $currentValue = Get-ItemProperty -Path $edgeRegistryPath -Name "EnhanceSecurityMode" -ErrorAction SilentlyContinue
        if ($currentValue) {
            $modeText = switch ($currentValue.EnhanceSecurityMode) {
                0 { "Basic (Off)" }
                1 { "Balanced" }
                2 { "Strict" }
            }
            Write-Log "  Current value: $modeText" "Cyan"
        }
        
        $edgeSuccess = $true
    }
    catch {
        Write-Log "  Error setting Edge registry value: $_" "Red"
        $edgeSuccess = $false
    }
}

Write-Log ""

#endregion

#region Summary

Write-Log "======================================================================" "Cyan"
Write-Log "=== Configuration Summary ===" "Cyan"
Write-Log "======================================================================" "Cyan"

if ($chromeInstalled) {
    Write-Log "Chrome: $chromeSuccessCount settings applied, $chromeFailCount failed" "White"
}
if ($firefoxInstalled) {
    Write-Log "Firefox: $firefoxSuccessCount profiles configured, $firefoxFailCount failed" "White"
}
if ($edgeInstalled) {
    if ($edgeSuccess) {
        Write-Log "Edge: Enhanced Security Mode set to Balanced" "White"
    } else {
        Write-Log "Edge: Configuration failed" "White"
    }
}

Write-Log ""
Write-Log "Log file location: $logFile" "Cyan"
Write-Log ""
Write-Log "IMPORTANT: Please restart all browsers for changes to take effect" "Yellow"
Write-Log ""
Write-Log "Script completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "Cyan"
Write-Log "======================================================================" "Cyan"

# Determine exit code
$overallSuccess = $true
if ($chromeInstalled -and $chromeFailCount -gt 0) { $overallSuccess = $false }
if ($firefoxInstalled -and $firefoxFailCount -gt 0) { $overallSuccess = $false }
if ($edgeInstalled -and -not $edgeSuccess) { $overallSuccess = $false }

if ($overallSuccess) {
    exit 0
} else {
    exit 1
}

#endregion
