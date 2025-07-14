# PowerShell Script to Configure 30-Minute Inactivity Lock for Azure AD Joined Devices
# This script sets screen saver timeout and lock screen policies for enhanced security

# Requires administrative privileges
#Requires -RunAsAdministrator

# Function to write log messages
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $(
        switch ($Level) {
            "ERROR" { "Red" }
            "WARNING" { "Yellow" }
            "SUCCESS" { "Green" }
            default { "White" }
        }
    )
}

# Function to set registry value with error handling
function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [string]$Type = "DWORD"
    )
    
    try {
        if (!(Test-Path $Path)) {
            New-Item -Path $Path -Force | Out-Null
            Write-Log "Created registry path: $Path"
        }
        
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type
        Write-Log "Set $Path\$Name = $Value" -Level "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Failed to set $Path\$Name = $Value. Error: $($_.Exception.Message)" -Level "ERROR"
        return $false
    }
}

# Main configuration function
function Set-InactivityLock {
    Write-Log "Starting Azure AD Device Inactivity Lock Configuration"
    Write-Log "Target: 30-minute (1800 seconds) inactivity timeout"
    
    $success = $true
    $timeoutSeconds = 1800  # 30 minutes in seconds
    
    # Registry paths for different policies
    $policies = @{
        # Screen saver settings (User level)
        "UserScreenSaver" = @{
            Path = "HKCU:\Control Panel\Desktop"
            Settings = @{
                "ScreenSaveActive" = @{ Value = "1"; Type = "String" }
                "ScreenSaveTimeOut" = @{ Value = $timeoutSeconds.ToString(); Type = "String" }
                "ScreenSaverIsSecure" = @{ Value = "1"; Type = "String" }
            }
        }
        
        # Machine-level policies (affects all users)
        "MachineScreenSaver" = @{
            Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
            Settings = @{
                "InactivityTimeoutSecs" = @{ Value = $timeoutSeconds; Type = "DWORD" }
            }
        }
        
        # Group Policy equivalent settings
        "GroupPolicyScreenSaver" = @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop"
            Settings = @{
                "ScreenSaveActive" = @{ Value = "1"; Type = "String" }
                "ScreenSaveTimeOut" = @{ Value = $timeoutSeconds.ToString(); Type = "String" }
                "ScreenSaverIsSecure" = @{ Value = "1"; Type = "String" }
            }
        }
        
        # Additional security settings
        "SecuritySettings" = @{
            Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
            Settings = @{
                "MaxInactivity" = @{ Value = $timeoutSeconds; Type = "DWORD" }
                "InactivityTimeoutSecs" = @{ Value = $timeoutSeconds; Type = "DWORD" }
            }
        }
    }
    
    # Apply each policy
    foreach ($policyName in $policies.Keys) {
        Write-Log "Applying policy: $policyName"
        $policy = $policies[$policyName]
        
        foreach ($settingName in $policy.Settings.Keys) {
            $setting = $policy.Settings[$settingName]
            $result = Set-RegistryValue -Path $policy.Path -Name $settingName -Value $setting.Value -Type $setting.Type
            if (!$result) {
                $success = $false
            }
        }
    }
    
    # Set power management settings to complement screen lock
    Write-Log "Configuring complementary power settings"
    
    try {
        # Set display timeout to 30 minutes when plugged in
        & powercfg.exe /change monitor-timeout-ac 30
        Write-Log "Set AC display timeout to 30 minutes" -Level "SUCCESS"
        
        # Set display timeout to 30 minutes when on battery
        & powercfg.exe /change monitor-timeout-dc 30
        Write-Log "Set DC display timeout to 30 minutes" -Level "SUCCESS"
        
        # Disable sleep to ensure lock screen activates instead
        & powercfg.exe /change standby-timeout-ac 0
        & powercfg.exe /change standby-timeout-dc 0
        Write-Log "Disabled automatic sleep" -Level "SUCCESS"
    }
    catch {
        Write-Log "Failed to configure power settings: $($_.Exception.Message)" -Level "WARNING"
    }
    
    return $success
}

# Function to verify configuration
function Test-InactivityLock {
    Write-Log "Verifying inactivity lock configuration"
    
    $checks = @(
        @{ Path = "HKCU:\Control Panel\Desktop"; Name = "ScreenSaveActive"; Expected = "1" }
        @{ Path = "HKCU:\Control Panel\Desktop"; Name = "ScreenSaveTimeOut"; Expected = "1800" }
        @{ Path = "HKCU:\Control Panel\Desktop"; Name = "ScreenSaverIsSecure"; Expected = "1" }
        @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "InactivityTimeoutSecs"; Expected = 1800 }
    )
    
    $allPassed = $true
    
    foreach ($check in $checks) {
        try {
            $value = Get-ItemProperty -Path $check.Path -Name $check.Name -ErrorAction Stop
            $actualValue = $value.($check.Name)
            
            if ($actualValue -eq $check.Expected) {
                Write-Log "✓ $($check.Path)\$($check.Name) = $actualValue" -Level "SUCCESS"
            } else {
                Write-Log "✗ $($check.Path)\$($check.Name) = $actualValue (expected: $($check.Expected))" -Level "WARNING"
                $allPassed = $false
            }
        }
        catch {
            Write-Log "✗ Could not verify $($check.Path)\$($check.Name)" -Level "WARNING"
            $allPassed = $false
        }
    }
    
    return $allPassed
}

# Function to check if device is Azure AD joined
function Test-AzureADJoined {
    try {
        $dsregStatus = & dsregcmd.exe /status
        $isAzureADJoined = $dsregStatus | Select-String "AzureAdJoined\s*:\s*YES"
        
        if ($isAzureADJoined) {
            Write-Log "Device is Azure AD joined" -Level "SUCCESS"
            return $true
        } else {
            Write-Log "Device is not Azure AD joined" -Level "WARNING"
            return $false
        }
    }
    catch {
        Write-Log "Could not determine Azure AD join status: $($_.Exception.Message)" -Level "WARNING"
        return $false
    }
}

# Main execution
try {
    Write-Log "Azure AD Device Inactivity Lock Configuration Script"
    Write-Log "=============================================="
    
    # Check if running as administrator
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "This script must be run as Administrator" -Level "ERROR"
        Write-Log "Please run PowerShell as Administrator and try again"
        exit 1
    }
    
    # Check Azure AD join status
    $isAzureADJoined = Test-AzureADJoined
    if (!$isAzureADJoined) {
        Write-Log "Warning: Device may not be Azure AD joined. Configuration will still proceed." -Level "WARNING"
    }
    
    # Apply inactivity lock settings
    $configSuccess = Set-InactivityLock
    
    if ($configSuccess) {
        Write-Log "Configuration applied successfully" -Level "SUCCESS"
        
        # Verify configuration
        Start-Sleep -Seconds 2
        $verifySuccess = Test-InactivityLock
        
        if ($verifySuccess) {
            Write-Log "All settings verified successfully" -Level "SUCCESS"
        } else {
            Write-Log "Some settings could not be verified" -Level "WARNING"
        }
        
        Write-Log "=============================================="
        Write-Log "IMPORTANT NOTES:"
        Write-Log "1. Users may need to log off and log back on for all changes to take effect"
        Write-Log "2. The lock screen will activate after 30 minutes of inactivity"
        Write-Log "3. Users will need to authenticate to unlock the screen"
        Write-Log "4. For Intune-managed devices, consider using Device Configuration policies"
        Write-Log "=============================================="
        
    } else {
        Write-Log "Configuration completed with errors. Please review the log above." -Level "ERROR"
        exit 1
    }
}
catch {
    Write-Log "Script execution failed: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}

Write-Log "Script execution completed"