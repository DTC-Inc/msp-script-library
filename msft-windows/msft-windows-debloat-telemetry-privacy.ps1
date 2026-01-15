## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $RMM = 1

# This script configures Windows telemetry and privacy settings:
# 1. Disables telemetry via Group Policy registry keys
# 2. Disables diagnostic data collection and CEIP
# 3. Disables Windows Error Reporting
# 4. Disables advertising ID and tailored experiences
# 5. Disables location tracking, Cortana, WiFi Sense
# 6. Disables activity history/timeline
# 7. Disables app suggestions and consumer features
# Use Case: Deploy via RMM for privacy-hardened workstations

#Requires -RunAsAdministrator

$ScriptLogName = "msft-windows-debloat-telemetry-privacy.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    while ($ValidInput -ne 1) {
        $Description = Read-Host "Please enter the ticket # and/or your initials"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
} else {
    if ($null -ne $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
    }

    if ($null -eq $Description) {
        $Description = "RMM-initiated telemetry and privacy configuration"
    }
}

# Ensure log directory exists before starting transcript
$logDir = Split-Path -Path $LogPath -Parent
if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host ""

Write-Host "=== Windows Telemetry & Privacy Configuration ===" -ForegroundColor Cyan

# Helper function to ensure registry path exists
function Ensure-RegistryPath {
    param([string]$Path)
    if (!(Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
}

try {
    #############################################
    # SECTION 1: TELEMETRY & DATA COLLECTION
    #############################################
    Write-Host ""
    Write-Host "--- Telemetry & Data Collection ---" -ForegroundColor Magenta

    # Step 1: Disable telemetry via Group Policy
    Write-Host "Disabling telemetry via Group Policy..." -ForegroundColor Yellow
    Ensure-RegistryPath "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"

    # Check Windows edition - AllowTelemetry=0 only works on Enterprise/Education
    # Pro/Home minimum is 1 (Basic)
    $osEdition = (Get-WmiObject -Class Win32_OperatingSystem).Caption
    $isEnterpriseOrEducation = $osEdition -match "Enterprise|Education"

    if ($isEnterpriseOrEducation) {
        # AllowTelemetry: 0 = Security (Enterprise/Education only)
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Type DWord -Value 0
        Write-Host "  Telemetry policy set to Security/Off (Enterprise/Education)" -ForegroundColor Green
    } else {
        # AllowTelemetry: 1 = Basic (minimum for Pro/Home)
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Type DWord -Value 1
        Write-Host "  Telemetry policy set to Basic (minimum for $osEdition)" -ForegroundColor Yellow
    }

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowDeviceNameInTelemetry" -Type DWord -Value 0
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "DoNotShowFeedbackNotifications" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "DisableTelemetryOptInChangeNotification" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "DisableTelemetryOptInSettingsUx" -Type DWord -Value 1
    Write-Host "  Additional telemetry settings configured" -ForegroundColor Green

    # Step 2: Disable diagnostic data collection
    Write-Host "Disabling diagnostic data collection..." -ForegroundColor Yellow
    Ensure-RegistryPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack" -Name "ShowedToastAtLevel" -Type DWord -Value 1
    Ensure-RegistryPath "HKCU:\SOFTWARE\Microsoft\Siuf\Rules"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Siuf\Rules" -Name "NumberOfSIUFInPeriod" -Type DWord -Value 0
    Write-Host "  Diagnostic data and feedback frequency minimized" -ForegroundColor Green

    # Step 3: Disable CEIP
    Write-Host "Disabling Customer Experience Improvement Program..." -ForegroundColor Yellow
    Ensure-RegistryPath "HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\SQMClient\Windows" -Name "CEIPEnable" -Type DWord -Value 0
    Ensure-RegistryPath "HKLM:\SOFTWARE\Policies\Microsoft\AppCompat"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\AppCompat" -Name "AITEnable" -Type DWord -Value 0
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\AppCompat" -Name "DisableInventory" -Type DWord -Value 1
    Write-Host "  CEIP and App Compatibility telemetry disabled" -ForegroundColor Green

    # Step 4: Disable Windows Error Reporting
    Write-Host "Disabling Windows Error Reporting..." -ForegroundColor Yellow
    Ensure-RegistryPath "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" -Name "Disabled" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" -Name "DontSendAdditionalData" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting" -Name "LoggingDisabled" -Type DWord -Value 1
    Write-Host "  Windows Error Reporting disabled" -ForegroundColor Green

    #############################################
    # SECTION 2: ADVERTISING & PERSONALIZATION
    #############################################
    Write-Host ""
    Write-Host "--- Advertising & Personalization ---" -ForegroundColor Magenta

    # Step 5: Disable Advertising ID
    Write-Host "Disabling Advertising ID..." -ForegroundColor Yellow
    Ensure-RegistryPath "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" -Name "DisabledByGroupPolicy" -Type DWord -Value 1
    Ensure-RegistryPath "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -Type DWord -Value 0
    Write-Host "  Advertising ID disabled" -ForegroundColor Green

    # Step 6: Disable Tailored Experiences
    Write-Host "Disabling Tailored Experiences..." -ForegroundColor Yellow
    Ensure-RegistryPath "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableTailoredExperiencesWithDiagnosticData" -Type DWord -Value 1
    Ensure-RegistryPath "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy"
    Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy" -Name "TailoredExperiencesWithDiagnosticDataEnabled" -Type DWord -Value 0
    $cloudContentPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    if (Test-Path $cloudContentPath) {
        Set-ItemProperty -Path $cloudContentPath -Name "SubscribedContent-338393Enabled" -Type DWord -Value 0 -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $cloudContentPath -Name "SubscribedContent-353694Enabled" -Type DWord -Value 0 -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $cloudContentPath -Name "SubscribedContent-353696Enabled" -Type DWord -Value 0 -ErrorAction SilentlyContinue
    }
    Write-Host "  Tailored experiences disabled" -ForegroundColor Green

    # Step 7: Disable App Suggestions and Consumer Features
    Write-Host "Disabling App Suggestions and Consumer Features..." -ForegroundColor Yellow
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableWindowsConsumerFeatures" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableSoftLanding" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent" -Name "DisableCloudOptimizedContent" -Type DWord -Value 1
    Write-Host "  App suggestions and consumer features disabled" -ForegroundColor Green

    #############################################
    # SECTION 3: LOCATION & TRACKING
    #############################################
    Write-Host ""
    Write-Host "--- Location & Tracking ---" -ForegroundColor Magenta

    # Step 8: Disable Location Tracking
    Write-Host "Disabling Location Tracking..." -ForegroundColor Yellow
    Ensure-RegistryPath "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" -Name "DisableLocation" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors" -Name "DisableLocationScripting" -Type DWord -Value 1
    Write-Host "  Location tracking disabled" -ForegroundColor Green

    # Step 9: Disable Activity History/Timeline
    Write-Host "Disabling Activity History/Timeline..." -ForegroundColor Yellow
    Ensure-RegistryPath "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableActivityFeed" -Type DWord -Value 0
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "PublishUserActivities" -Type DWord -Value 0
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "UploadUserActivities" -Type DWord -Value 0
    Write-Host "  Activity history/timeline disabled" -ForegroundColor Green

    #############################################
    # SECTION 4: CORTANA & SEARCH
    #############################################
    Write-Host ""
    Write-Host "--- Cortana & Search ---" -ForegroundColor Magenta

    # Step 10: Disable Cortana and Web Search
    Write-Host "Disabling Cortana and Web Search..." -ForegroundColor Yellow
    Ensure-RegistryPath "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCortana" -Type DWord -Value 0
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowSearchToUseLocation" -Type DWord -Value 0
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "ConnectedSearchUseWeb" -Type DWord -Value 0
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "DisableWebSearch" -Type DWord -Value 1
    Write-Host "  Cortana and web search disabled" -ForegroundColor Green

    #############################################
    # SECTION 5: NETWORK PRIVACY
    #############################################
    Write-Host ""
    Write-Host "--- Network Privacy ---" -ForegroundColor Magenta

    # Step 11: Disable WiFi Sense
    Write-Host "Disabling WiFi Sense..." -ForegroundColor Yellow
    Ensure-RegistryPath "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowAutoConnectToWiFiSenseHotspots" -Name "value" -Type DWord -Value 0
    Ensure-RegistryPath "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\WiFi\AllowWiFiHotSpotReporting" -Name "value" -Type DWord -Value 0
    Write-Host "  WiFi Sense disabled" -ForegroundColor Green

    # Step 12: Disable SmartScreen for Store Apps
    Write-Host "Disabling SmartScreen for Store Apps..." -ForegroundColor Yellow
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableSmartScreen" -Type DWord -Value 0
    Write-Host "  SmartScreen for Store Apps disabled" -ForegroundColor Green

    #############################################
    # SUMMARY
    #############################################
    Write-Host ""
    Write-Host "=== Configuration Summary ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Telemetry & Data Collection:" -ForegroundColor White
    if ($isEnterpriseOrEducation) {
        Write-Host "  - Telemetry Policy: Security/Off (Enterprise/Education)" -ForegroundColor Green
    } else {
        Write-Host "  - Telemetry Policy: Basic (minimum for Pro/Home)" -ForegroundColor Yellow
        Write-Host "    Note: Pro/Home editions cannot set telemetry to 0 (Security)" -ForegroundColor Gray
    }
    Write-Host "  - Diagnostic Data: Minimized" -ForegroundColor Green
    Write-Host "  - CEIP: Disabled" -ForegroundColor Green
    Write-Host "  - Error Reporting: Disabled" -ForegroundColor Green
    Write-Host ""
    Write-Host "Advertising & Personalization:" -ForegroundColor White
    Write-Host "  - Advertising ID: Disabled" -ForegroundColor Green
    Write-Host "  - Tailored Experiences: Disabled" -ForegroundColor Green
    Write-Host "  - App Suggestions: Disabled" -ForegroundColor Green
    Write-Host ""
    Write-Host "Location & Tracking:" -ForegroundColor White
    Write-Host "  - Location Tracking: Disabled" -ForegroundColor Green
    Write-Host "  - Activity History: Disabled" -ForegroundColor Green
    Write-Host ""
    Write-Host "Cortana & Search:" -ForegroundColor White
    Write-Host "  - Cortana: Disabled" -ForegroundColor Green
    Write-Host "  - Web Search: Disabled" -ForegroundColor Green
    Write-Host ""
    Write-Host "Network Privacy:" -ForegroundColor White
    Write-Host "  - WiFi Sense: Disabled" -ForegroundColor Green
    Write-Host "  - SmartScreen (Store): Disabled" -ForegroundColor Green
    Write-Host ""
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Note: Some settings may require logoff/restart to take full effect" -ForegroundColor Yellow

} catch {
    Write-Host "Error configuring settings: $_" -ForegroundColor Red
    Stop-Transcript
    exit 1
}

Stop-Transcript
