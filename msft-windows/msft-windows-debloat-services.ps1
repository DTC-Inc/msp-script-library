## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $RMM = 1

# This script disables unnecessary Windows services that:
# - Are not needed for typical business workstation use
# - Can impact performance or security
# Note: Telemetry services handled by debloat-telemetry-privacy script
# Note: Xbox services handled by disable-xbox-services script
# Use Case: Deploy via RMM during initial workstation setup

#Requires -RunAsAdministrator

$ScriptLogName = "msft-windows-debloat-services.log"

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
        $Description = "RMM-initiated service debloating"
    }
}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host ""

Write-Host "=== Windows Service Debloating ===" -ForegroundColor Cyan

# Services to disable with descriptions
# Note: Telemetry (DiagTrack, dmwappushservice, WerSvc) handled by telemetry-privacy script
# Note: Xbox services handled by disable-xbox-services script
$servicesToDisable = @(
    @{Name = "HomeGroupListener"; Description = "HomeGroup Listener (deprecated)"},
    @{Name = "HomeGroupProvider"; Description = "HomeGroup Provider (deprecated)"},
    @{Name = "lfsvc"; Description = "Geolocation Service"},
    @{Name = "MapsBroker"; Description = "Downloaded Maps Manager"},
    @{Name = "NetTcpPortSharing"; Description = "Net.Tcp Port Sharing Service"},
    @{Name = "RemoteRegistry"; Description = "Remote Registry (security risk)"},
    @{Name = "SharedAccess"; Description = "Internet Connection Sharing (ICS)"},
    @{Name = "TrkWks"; Description = "Distributed Link Tracking Client"},
    @{Name = "WMPNetworkSvc"; Description = "Windows Media Player Network Sharing"},
    @{Name = "wisvc"; Description = "Windows Insider Service"},
    @{Name = "wercplsupport"; Description = "Problem Reports Control Panel Support"},
    @{Name = "WSearch"; Description = "Windows Search (optional - skip by default)"}
)

$disabledCount = 0
$alreadyDisabledCount = 0
$notFoundCount = 0
$failedCount = 0

foreach ($svc in $servicesToDisable) {
    $serviceName = $svc.Name
    $serviceDesc = $svc.Description

    # Skip WSearch by default - it's useful for many users
    if ($serviceName -eq "WSearch") {
        Write-Host "Skipping $serviceName ($serviceDesc) - enable manually if not needed" -ForegroundColor Gray
        continue
    }

    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

    if ($null -eq $service) {
        Write-Host "Service not found: $serviceName ($serviceDesc)" -ForegroundColor Gray
        $notFoundCount++
        continue
    }

    try {
        $currentStatus = Get-Service -Name $serviceName | Select-Object -ExpandProperty StartType

        if ($currentStatus -eq "Disabled") {
            Write-Host "Already disabled: $serviceName ($serviceDesc)" -ForegroundColor Gray
            $alreadyDisabledCount++
        } else {
            # Stop the service if running
            if ($service.Status -eq "Running") {
                Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
            }

            # Disable the service
            Set-Service -Name $serviceName -StartupType Disabled -ErrorAction Stop
            Write-Host "Disabled: $serviceName ($serviceDesc)" -ForegroundColor Green
            $disabledCount++
        }
    } catch {
        Write-Host "Failed to disable: $serviceName - $_" -ForegroundColor Yellow
        $failedCount++
    }
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "Services disabled: $disabledCount" -ForegroundColor Green
Write-Host "Already disabled: $alreadyDisabledCount" -ForegroundColor Gray
Write-Host "Not found (expected on some systems): $notFoundCount" -ForegroundColor Gray
if ($failedCount -gt 0) {
    Write-Host "Failed to disable: $failedCount" -ForegroundColor Yellow
}
Write-Host "===============" -ForegroundColor Cyan

Stop-Transcript
