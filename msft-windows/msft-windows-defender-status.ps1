# Windows Defender Protection Check and Enable Script
# This script retrieves the current status of Windows Defender protections,
# attempts to enable any feature that is disabled (for which a Set-MpPreference parameter exists),
# and then displays the updated status.
# Note: Run PowerShell as Administrator. Some settings may be controlled by Group Policy and might not change.

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
        Write-Host "Error enabling Real-Time Protection: $($_.Exception.Message)"
    }
}

# Attempt to enable Behavior Monitoring if it is disabled
if (-not $status.BehaviorMonitorEnabled) {
    Write-Host "Attempting to enable Behavior Monitoring..."
    try {
        Set-MpPreference -DisableBehaviorMonitoring $false -ErrorAction Stop
        Write-Host "Behavior Monitoring enabled successfully."
    } catch {
        Write-Host "Error enabling Behavior Monitoring: $($_.Exception.Message)"
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
