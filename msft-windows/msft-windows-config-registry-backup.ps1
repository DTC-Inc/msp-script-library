## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description   / $env:Description   - Ticket # or initials for audit trail
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM

# This script enables periodic Windows registry backup:
# - Enables the EnablePeriodicBackup registry key
# - Windows will automatically backup registry hives periodically
# - Backups stored in %SystemRoot%\System32\config\RegBack
# Use Case: Deploy via RMM as baseline configuration for recovery

#Requires -RunAsAdministrator

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description   = $env:Description,
    [string]$RMMScriptPath = $env:RMMScriptPath
)

$ScriptLogName = "msft-windows-config-registry-backup.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Mirror the resolved parameter values into $env: so the rest of the script can reference
# either $Description or $env:Description, whichever form the input arrived in.
if (-not [string]::IsNullOrEmpty($Description))   { $env:Description   = $Description }
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) { $env:RMMScriptPath = $RMMScriptPath }

if ([string]::IsNullOrEmpty($Description)) {
    $Description = "RMM-initiated registry backup configuration"
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
