## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $RMM = 1
## $AppList = "Mozilla.Firefox,7zip.7zip,Google.Chrome"  # Comma-separated WinGet app IDs
## $CleanDesktopShortcuts = $true  # Remove desktop shortcuts after installation

# This script installs applications using WinGet:
# - Accepts a comma-separated list of WinGet app IDs
# - Installs silently with auto-accept
# - Optionally cleans up desktop shortcuts
# Use Case: Deploy standard applications via RMM

#Requires -RunAsAdministrator

$ScriptLogName = "msft-windows-install-apps-winget.log"

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

if ($null -eq $CleanDesktopShortcuts) { $CleanDesktopShortcuts = $true }

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
        $Description = "RMM-initiated WinGet application installation"
    }
}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
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

foreach ($appId in $apps) {
    Write-Host "Installing: $appId" -ForegroundColor Yellow

    try {
        # Check if already installed
        $checkInstalled = winget list --id $appId --exact --accept-source-agreements 2>&1

        if ($checkInstalled -match $appId) {
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

# Clean up desktop shortcuts
if ($CleanDesktopShortcuts) {
    Write-Host ""
    Write-Host "Cleaning desktop shortcuts..." -ForegroundColor Yellow

    $desktopPaths = @(
        "$env:PUBLIC\Desktop",
        "$env:USERPROFILE\Desktop"
    )

    $shortcutsRemoved = 0

    foreach ($desktopPath in $desktopPaths) {
        if (Test-Path $desktopPath) {
            $shortcuts = Get-ChildItem -Path $desktopPath -Filter "*.lnk" -ErrorAction SilentlyContinue
            foreach ($shortcut in $shortcuts) {
                try {
                    Remove-Item -Path $shortcut.FullName -Force -ErrorAction Stop
                    $shortcutsRemoved++
                } catch {
                    # Ignore errors for shortcuts in use
                }
            }
        }
    }

    Write-Host "Removed $shortcutsRemoved desktop shortcut(s)" -ForegroundColor Green
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
