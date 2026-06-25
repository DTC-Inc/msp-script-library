## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description           / $env:Description           - Ticket # or initials for audit trail
## $DisableScheduledTasks / $env:DisableScheduledTasks - Disable telemetry scheduled tasks (default: $true)
## $RMMScriptPath         / $env:RMMScriptPath         - Optional log directory base provided by the RMM

# This script applies SSD performance optimizations:
# - Disables SysMain (Superfetch) service
# - Disables Prefetch
# - Disables scheduled tasks for telemetry/diagnostics
# Only applies SSD optimizations if SSD is detected
# Use Case: Deploy via RMM for workstations with SSDs

#Requires -RunAsAdministrator

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description           = $env:Description,
    [bool]  $DisableScheduledTasks = $(if ([string]::IsNullOrEmpty($env:DisableScheduledTasks)) { $true } else { [System.Convert]::ToBoolean($env:DisableScheduledTasks) }),
    [string]$RMMScriptPath         = $env:RMMScriptPath
)

$ScriptLogName = "msft-windows-config-performance-ssd.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

if ($null -eq $Description) {
    $Description = "RMM-initiated SSD performance optimization"
}

# Store logs under $RMMScriptPath if provided, otherwise the standard Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host ""

Write-Host "=== SSD Performance Optimization ===" -ForegroundColor Cyan

# Detect SSD (including NVMe drives which may report MediaType as Unspecified)
$ssdDetected = $false
$disks = Get-PhysicalDisk | Select-Object DeviceId, MediaType, BusType, FriendlyName

Write-Host "Detected Disks:" -ForegroundColor Yellow
foreach ($disk in $disks) {
    Write-Host "  $($disk.FriendlyName) - MediaType: $($disk.MediaType) - BusType: $($disk.BusType)" -ForegroundColor Gray
    if ($disk.MediaType -eq "SSD" -or $disk.BusType -eq "NVMe") {
        $ssdDetected = $true
    }
}
Write-Host ""

if ($ssdDetected) {
    Write-Host "SSD detected - applying optimizations" -ForegroundColor Green

    try {
        # Disable SysMain (Superfetch)
        Write-Host "Disabling SysMain (Superfetch)..." -ForegroundColor Yellow
        $sysmain = Get-Service -Name "SysMain" -ErrorAction SilentlyContinue

        if ($sysmain) {
            if ($sysmain.Status -eq "Running") {
                Stop-Service -Name "SysMain" -Force -ErrorAction SilentlyContinue
            }
            Set-Service -Name "SysMain" -StartupType Disabled
            Write-Host "SysMain service disabled" -ForegroundColor Green
        } else {
            Write-Host "SysMain service not found (may already be disabled)" -ForegroundColor Gray
        }

        # Disable Prefetch and Superfetch via registry
        Write-Host "Disabling Prefetch..." -ForegroundColor Yellow
        $prefetchPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters"

        if (Test-Path $prefetchPath) {
            # EnablePrefetcher: 0=Disabled, 1=Application, 2=Boot, 3=All
            Set-ItemProperty -Path $prefetchPath -Name "EnablePrefetcher" -Type DWord -Value 0
            Set-ItemProperty -Path $prefetchPath -Name "EnableSuperfetch" -Type DWord -Value 0
            Write-Host "Prefetch disabled via registry" -ForegroundColor Green
        }

    } catch {
        Write-Host "Error applying SSD optimizations: $_" -ForegroundColor Yellow
    }

} else {
    Write-Host "No SSD detected - skipping SSD-specific optimizations" -ForegroundColor Yellow
}

# Disable scheduled tasks (applies to all systems)
if ($DisableScheduledTasks) {
    Write-Host ""
    Write-Host "Disabling telemetry/diagnostic scheduled tasks..." -ForegroundColor Yellow

    $tasksToDisable = @(
        "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
        "\Microsoft\Windows\Application Experience\ProgramDataUpdater",
        "\Microsoft\Windows\Application Experience\StartupAppTask",
        "\Microsoft\Windows\Autochk\Proxy",
        "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
        "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
        "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
        "\Microsoft\Windows\Maintenance\WinSAT",
        "\Microsoft\Windows\Shell\FamilySafetyUpload",
        "\Microsoft\Windows\Power Efficiency Diagnostics\AnalyzeSystem",
        "\Microsoft\Windows\CloudExperienceHost\CreateObjectTask"
    )

    $disabledCount = 0
    $notFoundCount = 0

    foreach ($taskPath in $tasksToDisable) {
        try {
            $taskName = Split-Path $taskPath -Leaf
            $taskFolder = (Split-Path $taskPath -Parent) + "\"
            $task = Get-ScheduledTask -TaskPath $taskFolder -TaskName $taskName -ErrorAction SilentlyContinue

            if ($task) {
                Disable-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue | Out-Null
                Write-Host "Disabled: $taskPath" -ForegroundColor Green
                $disabledCount++
            } else {
                $notFoundCount++
            }
        } catch {
            Write-Host "Failed to process task: $taskPath - $_" -ForegroundColor Gray
            $notFoundCount++
        }
    }

    Write-Host "Scheduled tasks disabled: $disabledCount" -ForegroundColor Green
    Write-Host "Tasks not found (may not exist on this system): $notFoundCount" -ForegroundColor Gray
}

Write-Host ""
Write-Host "=== Performance Summary ===" -ForegroundColor Cyan
if ($ssdDetected) {
    Write-Host "SSD Optimizations Applied:" -ForegroundColor Green
    Write-Host "  - SysMain (Superfetch) disabled" -ForegroundColor Gray
    Write-Host "  - Prefetch disabled" -ForegroundColor Gray
}
if ($DisableScheduledTasks) {
    Write-Host "Telemetry Tasks: Disabled" -ForegroundColor Green
}
Write-Host "===========================" -ForegroundColor Cyan

Stop-Transcript
