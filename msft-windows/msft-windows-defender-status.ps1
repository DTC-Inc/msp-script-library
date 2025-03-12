# Windows Defender Protection Check and Enable Script
# This script checks for third-party antivirus, verifies Windows Defender status,
# removes registry keys that disable Windows Defender, and enables protection if necessary.
# Note: Run PowerShell as Administrator.

# Function to check and remove registry keys
function Remove-DefenderRegistryKeys {
    $registryPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
    $keysToCheck = @("DisableAntiSpyware", "DisableAntiVirus")

    foreach ($key in $keysToCheck) {
        if (Test-Path "$registryPath") {
            $value = Get-ItemProperty -Path "$registryPath" -Name $key -ErrorAction SilentlyContinue
            if ($value) {
                Write-Host "Found registry key: $key. Removing..."
                try {
                    Remove-ItemProperty -Path "$registryPath" -Name $key -ErrorAction Stop
                    Write-Host "Successfully removed $key."
                } catch {
                    Write-Host ("Error removing {0}: {1}" -f $key, $_.Exception.Message)
                }
            }
        }
    }
}

# Check for existing third-party antivirus products
$avProducts = Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntivirusProduct
$thirdPartyAVs = @()

if ($avProducts) {
    foreach ($product in $avProducts) {
        # Exclude Windows Defender / Microsoft Defender
        if ($product.displayName -notmatch "defender" -and $product.displayName -notmatch "microsoft defender") {
            $thirdPartyAVs += $product
        }
    }
}

if ($thirdPartyAVs.Count -gt 0) {
    Write-Host "Detected third-party antivirus product(s):" -ForegroundColor Yellow
    foreach ($product in $thirdPartyAVs) {
        # Attempt to retrieve the timestamp property, if available.
        $timestamp = $null
        if ($product.PSObject.Properties.Name -contains "timestamp") {
            $timestamp = $product.timestamp
        }
        Write-Host "Name: $($product.displayName) - Product State: $($product.productState) - Timestamp: $timestamp"
    }
    Write-Host "Skipping Windows Defender status check and enable section because a third-party AV is active."
    exit
}

# Check and remove registry keys that disable Windows Defender
Remove-DefenderRegistryKeys

# Retrieve the current status of Windows Defender
$status = Get-MpComputerStatus

Write-Host "===== Windows Defender Status Report =====" -ForegroundColor Cyan
Write-Host "Antivirus Enabled:             $($status.AntivirusEnabled)"
Write-Host "Antispyware Enabled:           $($status.AntispywareEnabled)"
Write-Host "Real-time Protection Enabled:  $($status.RealTimeProtectionEnabled)"
Write-Host "Behavior Monitor Enabled:      $($status.BehaviorMonitorEnabled)"
Write-Host "On-Access Protection Enabled:  $($status.OnAccessProtectionEnabled)"
Write-Host "Signature Version:             $($status.AntivirusSignatureVersion)"
Write-Host "Last Signature Update:         $($status.AntivirusSignatureLastUpdated)"
Write-Host "NIS Enabled:                   $($status.NISEnabled)"
Write-Host "---------------------------------------------"
Write-Host "Status snapshot complete."

# If all protections are enabled, do not update the status.
if ($status.AntivirusEnabled -and $status.AntispywareEnabled -and `
    $status.RealTimeProtectionEnabled -and $status.BehaviorMonitorEnabled -and `
    $status.OnAccessProtectionEnabled) {
    Write-Host "All Windows Defender protections are enabled. No updates performed."
    exit
}

# Attempt to enable Real-Time Protection if it is disabled
if (-not $status.RealTimeProtectionEnabled) {
    Write-Host "Attempting to enable Real-Time Protection..."
    try {
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        Write-Host "Real-Time Protection enabled successfully."
    } catch {
        Write-Host ("Error enabling Real-Time Protection: {0}" -f $_.Exception.Message)
    }
}

# Attempt to enable Behavior Monitoring if it is disabled
if (-not $status.BehaviorMonitorEnabled) {
    Write-Host "Attempting to enable Behavior Monitoring..."
    try {
        Set-MpPreference -DisableBehaviorMonitoring $false -ErrorAction Stop
        Write-Host "Behavior Monitoring enabled successfully."
    } catch {
        Write-Host ("Error enabling Behavior Monitoring: {0}" -f $_.Exception.Message)
    }
}

# For On-Access Protection, no direct Set-MpPreference parameter exists.
if (-not $status.OnAccessProtectionEnabled) {
    Write-Host "On-Access Protection is currently disabled."
    Write-Host "Note: On-Access Protection cannot be toggled via Set-MpPreference. Check Group Policy or local settings if needed."
}

# Pause briefly to allow settings to update (if applicable)
Start-Sleep -Seconds 5

# Retrieve updated status to confirm changes
$statusUpdated = Get-MpComputerStatus

Write-Host ""
Write-Host "===== Windows Defender Status Report (After Enabling) =====" -ForegroundColor Cyan
Write-Host "Antivirus Enabled:             $($statusUpdated.AntivirusEnabled)"
Write-Host "Antispyware Enabled:           $($statusUpdated.AntispywareEnabled)"
Write-Host "Real-time Protection Enabled:  $($statusUpdated.RealTimeProtectionEnabled)"
Write-Host "Behavior Monitor Enabled:      $($statusUpdated.BehaviorMonitorEnabled)"
Write-Host "On-Access Protection Enabled:  $($statusUpdated.OnAccessProtectionEnabled)"
Write-Host "--------------------------------------------------------------"
Write-Host "Script execution complete."
