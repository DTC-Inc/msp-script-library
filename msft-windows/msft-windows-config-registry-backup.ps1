## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $RMM = 1
## $RMMScriptPath
## $Description

# This script enables periodic Windows registry backup:
# - Enables the EnablePeriodicBackup registry key
# - Windows will automatically backup registry hives periodically
# - Backups stored in %SystemRoot%\System32\config\RegBack
# Use Case: Deploy via RMM as baseline configuration for recovery

#Requires -RunAsAdministrator

$ScriptLogName = "msft-windows-config-registry-backup.log"

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
        $Description = "RMM-initiated registry backup configuration"
    }
}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host ""

Write-Host "=== Registry Backup Configuration ===" -ForegroundColor Cyan

try {
    $regPath = "HKLM:\System\CurrentControlSet\Control\Session Manager\Configuration Manager"

    # Check current status
    $currentValue = Get-ItemProperty -Path $regPath -Name "EnablePeriodicBackup" -ErrorAction SilentlyContinue

    if ($currentValue.EnablePeriodicBackup -eq 1) {
        Write-Host "Periodic registry backup is already enabled" -ForegroundColor Green
    } else {
        Write-Host "Enabling periodic registry backup..." -ForegroundColor Yellow

        # Ensure registry path exists
        if (!(Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }

        # Enable periodic backup
        New-ItemProperty -Path $regPath -Name "EnablePeriodicBackup" -PropertyType DWORD -Value 1 -Force | Out-Null

        Write-Host "Periodic registry backup enabled" -ForegroundColor Green
    }

    # Check RegBack folder
    $regBackPath = "$env:SystemRoot\System32\config\RegBack"
    Write-Host ""
    Write-Host "Registry backup location: $regBackPath" -ForegroundColor Gray

    if (Test-Path $regBackPath) {
        $backupFiles = Get-ChildItem -Path $regBackPath -ErrorAction SilentlyContinue
        if ($backupFiles) {
            Write-Host "Existing backup files:" -ForegroundColor Gray
            foreach ($file in $backupFiles) {
                $size = if ($file.Length -gt 0) { "{0:N2} KB" -f ($file.Length / 1KB) } else { "0 KB (empty)" }
                Write-Host "  $($file.Name) - $size - $($file.LastWriteTime)" -ForegroundColor Gray
            }
        } else {
            Write-Host "No backup files found yet (will be created by Windows)" -ForegroundColor Gray
        }
    }

    Write-Host ""
    Write-Host "=== Configuration Summary ===" -ForegroundColor Cyan
    Write-Host "Periodic Registry Backup: Enabled" -ForegroundColor Green
    Write-Host "Backup Location: $regBackPath" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Note: Windows will backup registry hives during maintenance" -ForegroundColor Yellow
    Write-Host "Backups include: SAM, SECURITY, SOFTWARE, SYSTEM, DEFAULT" -ForegroundColor Gray
    Write-Host "=============================" -ForegroundColor Cyan

} catch {
    Write-Host "Error configuring registry backup: $_" -ForegroundColor Red
    Stop-Transcript
    exit 1
}

Stop-Transcript
