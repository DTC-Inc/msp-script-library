## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $RMM = 1
## $RMMScriptPath
## $Description

# This script enables System Restore on the system drive and creates an initial restore point.
# Use Case: Deploy via RMM during initial workstation setup or as remediation

#Requires -RunAsAdministrator

$ScriptLogName = "msft-windows-config-system-restore.log"

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
        $Description = "RMM-initiated System Restore configuration"
    }
}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host ""

Write-Host "=== System Restore Configuration ===" -ForegroundColor Cyan

try {
    # Enable System Restore on system drive
    $systemDrive = $env:SYSTEMDRIVE + "\"
    Write-Host "Enabling System Restore on $systemDrive..." -ForegroundColor Yellow

    Enable-ComputerRestore -Drive $systemDrive -ErrorAction Stop
    Write-Host "System Restore enabled on $systemDrive" -ForegroundColor Green

    # Enable periodic registry backup
    Write-Host "Enabling periodic registry backup..." -ForegroundColor Yellow
    $regPath = 'HKLM:\System\CurrentControlSet\Control\Session Manager\Configuration Manager\'
    if (!(Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    New-ItemProperty -Path $regPath -Name 'EnablePeriodicBackup' -PropertyType DWORD -Value 1 -Force | Out-Null
    Write-Host "Periodic registry backup enabled" -ForegroundColor Green

    # Create initial restore point
    Write-Host "Creating initial restore point..." -ForegroundColor Yellow
    try {
        Checkpoint-Computer -Description "Initial Setup - $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Host "Initial restore point created" -ForegroundColor Green
    } catch {
        # Check for specific error conditions
        $errorCode = $_.Exception.HResult
        $errorMessage = $_.Exception.Message

        # Error 1058 (0x8007041A) = Service is disabled
        if ($errorCode -eq 0x8007041A -or $errorCode -eq 1058) {
            Write-Host "ERROR: System Restore service is disabled. Cannot create restore point." -ForegroundColor Red
            Write-Host "Please enable the 'Volume Shadow Copy' and 'Microsoft Software Shadow Copy Provider' services." -ForegroundColor Yellow
            throw
        }
        # 24-hour throttle error
        elseif ($errorMessage -match "already been created within the past 24 hours") {
            Write-Host "Restore point creation throttled (24-hour limit) - this is expected behavior" -ForegroundColor Yellow
            Write-Host "A restore point was created within the last 24 hours. No action needed." -ForegroundColor Gray
        }
        # Other errors
        else {
            throw
        }
    }

    # Verify configuration
    Write-Host ""
    Write-Host "=== Configuration Summary ===" -ForegroundColor Cyan
    $status = Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($status) {
        Write-Host "Latest restore point: $($status.Description)" -ForegroundColor Gray
        Write-Host "Created: $($status.CreationTime)" -ForegroundColor Gray
    }
    Write-Host "System Restore: Enabled" -ForegroundColor Green
    Write-Host "Registry Backup: Enabled" -ForegroundColor Green
    Write-Host "==============================" -ForegroundColor Cyan

} catch {
    Write-Host "Error configuring System Restore: $_" -ForegroundColor Red
    Stop-Transcript
    exit 1
}

Stop-Transcript
