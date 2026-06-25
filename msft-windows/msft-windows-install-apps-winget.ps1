## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $AppList               / $env:AppList               - Comma-separated WinGet app IDs
## $CleanDesktopShortcuts / $env:CleanDesktopShortcuts - Remove desktop shortcuts after installation (default: true)
## $Description           / $env:Description           - Ticket # or initials for audit trail
## $RMMScriptPath         / $env:RMMScriptPath         - Optional log directory base provided by the RMM

# This script installs applications using WinGet:
# - Accepts a comma-separated list of WinGet app IDs
# - Installs silently with auto-accept
# - Optionally cleans up desktop shortcuts
# Use Case: Deploy standard applications via RMM

#Requires -RunAsAdministrator

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-AppList ...) or from an RMM that supplies values as env variables.
    [string]$AppList               = $env:AppList,
    [string]$CleanDesktopShortcuts = $env:CleanDesktopShortcuts,
    [string]$Description           = $env:Description,
    [string]$RMMScriptPath         = $env:RMMScriptPath
)

$ScriptLogName = "msft-windows-install-apps-winget.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default app list (standard business applications)
$defaultApps = @(
    "7zip.7zip",
    "VideoLAN.VLC",
    "Notepad++.Notepad++",
    "Microsoft.VCRedist.2015+.x64"
)

# Parse app list if provided
if ($null -eq $AppList -or $AppList -eq "") {
    $apps = $defaultApps
} else {
    $apps = $AppList -split "," | ForEach-Object { $_.Trim() }
}

# Default desktop-shortcut cleanup to enabled; treat "false"/"0" as disabled.
if ([string]::IsNullOrEmpty($CleanDesktopShortcuts)) {
    $CleanDesktopShortcuts = $true
} else {
    $CleanDesktopShortcuts = $CleanDesktopShortcuts -notmatch '^\s*(false|0|no)\s*$'
}

# Default the audit-trail description if it was not supplied.
if ([string]::IsNullOrEmpty($Description)) {
    $Description = "RMM-initiated WinGet application installation"
}

# Store the logs in the RMMScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host ""

Write-Host "=== WinGet Application Installation ===" -ForegroundColor Cyan
Write-Host "Applications to install: $($apps.Count)" -ForegroundColor Yellow
foreach ($app in $apps) {
    Write-Host "  - $app" -ForegroundColor Gray
}
Write-Host ""

# Check if WinGet is available
$wingetPath = Get-Command winget -ErrorAction SilentlyContinue

if (!$wingetPath) {
    Write-Host "ERROR: WinGet not found" -ForegroundColor Red
    Write-Host "WinGet is included with Windows 11 22H2+ and Windows 10 (App Installer)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To install WinGet manually:" -ForegroundColor Yellow
    Write-Host "1. Install 'App Installer' from Microsoft Store" -ForegroundColor Gray
    Write-Host "2. Or download from: https://github.com/microsoft/winget-cli/releases" -ForegroundColor Gray
    Stop-Transcript
    exit 1
}

Write-Host "WinGet found at: $($wingetPath.Source)" -ForegroundColor Green
Write-Host ""

$installedCount = 0
$failedCount = 0
$skippedCount = 0

# Snapshot existing shortcuts before installation (to only remove new ones later)
$desktopPaths = @(
    "$env:PUBLIC\Desktop",
    "$env:USERPROFILE\Desktop"
)
$existingShortcuts = @()
foreach ($desktopPath in $desktopPaths) {
    if (Test-Path $desktopPath) {
        $existingShortcuts += Get-ChildItem -Path $desktopPath -Filter "*.lnk" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
    }
}

foreach ($appId in $apps) {
    Write-Host "Installing: $appId" -ForegroundColor Yellow

    try {
        # Check if already installed
        $checkInstalled = winget list --id $appId --exact --accept-source-agreements 2>&1

        if ($checkInstalled -like "*$appId*") {
            Write-Host "  Already installed, checking for updates..." -ForegroundColor Gray
            $result = winget upgrade --id $appId --exact --silent --accept-package-agreements --accept-source-agreements 2>&1

            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Updated: $appId" -ForegroundColor Green
            } else {
                Write-Host "  No updates available or already up to date" -ForegroundColor Gray
            }
            $skippedCount++
        } else {
            # Install the application
            $result = winget install --id $appId --exact --silent --accept-package-agreements --accept-source-agreements 2>&1

            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Installed: $appId" -ForegroundColor Green
                $installedCount++
            } else {
                Write-Host "  Failed to install: $appId" -ForegroundColor Yellow
                Write-Host "  Error: $result" -ForegroundColor Gray
                $failedCount++
            }
        }
    } catch {
        Write-Host "  Error installing $appId : $_" -ForegroundColor Red
        $failedCount++
    }
}

# Clean up desktop shortcuts (only those created during this installation)
if ($CleanDesktopShortcuts) {
    Write-Host ""
    Write-Host "Cleaning new desktop shortcuts..." -ForegroundColor Yellow

    $shortcutsRemoved = 0

    foreach ($desktopPath in $desktopPaths) {
        if (Test-Path $desktopPath) {
            $currentShortcuts = Get-ChildItem -Path $desktopPath -Filter "*.lnk" -ErrorAction SilentlyContinue
            foreach ($shortcut in $currentShortcuts) {
                # Only remove shortcuts that didn't exist before installation
                if ($shortcut.FullName -notin $existingShortcuts) {
                    try {
                        Remove-Item -Path $shortcut.FullName -Force -ErrorAction Stop
                        Write-Host "  Removed: $($shortcut.Name)" -ForegroundColor Gray
                        $shortcutsRemoved++
                    } catch {
                        # Ignore errors for shortcuts in use
                    }
                }
            }
        }
    }

    Write-Host "Removed $shortcutsRemoved new desktop shortcut(s)" -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Installation Summary ===" -ForegroundColor Cyan
Write-Host "Apps installed: $installedCount" -ForegroundColor Green
Write-Host "Apps already installed/updated: $skippedCount" -ForegroundColor Gray
if ($failedCount -gt 0) {
    Write-Host "Apps failed: $failedCount" -ForegroundColor Yellow
}
Write-Host "============================" -ForegroundColor Cyan

Stop-Transcript
