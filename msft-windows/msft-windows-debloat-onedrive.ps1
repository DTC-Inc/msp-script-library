## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $RMM = 1
## $Description
## $RMMScriptPath

# This script completely removes OneDrive from Windows:
# - Stops OneDrive processes
# - Uninstalls OneDrive
# - Removes OneDrive folders and registry entries
# - Prevents OneDrive from reinstalling
# Use Case: Deploy via RMM for environments not using OneDrive

#Requires -RunAsAdministrator

$ScriptLogName = "msft-windows-debloat-onedrive.log"

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
        $Description = "RMM-initiated OneDrive removal"
    }
}

# Ensure log directory exists before starting transcript
$logDir = Split-Path -Path $LogPath -Parent
if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host ""

Write-Host "=== OneDrive Removal ===" -ForegroundColor Cyan

try {
    # Stop OneDrive processes
    Write-Host "Stopping OneDrive processes..." -ForegroundColor Yellow
    $onedriveProcess = Get-Process -Name "OneDrive" -ErrorAction SilentlyContinue
    if ($onedriveProcess) {
        Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        Write-Host "OneDrive processes stopped" -ForegroundColor Green
    } else {
        Write-Host "OneDrive not running" -ForegroundColor Gray
    }

    # Find and run OneDrive uninstaller
    Write-Host "Uninstalling OneDrive..." -ForegroundColor Yellow

    $onedriveSetup = "$env:SYSTEMROOT\SysWOW64\OneDriveSetup.exe"
    if (!(Test-Path $onedriveSetup)) {
        $onedriveSetup = "$env:SYSTEMROOT\System32\OneDriveSetup.exe"
    }

    if (Test-Path $onedriveSetup) {
        $process = Start-Process $onedriveSetup -ArgumentList "/uninstall" -NoNewWindow -Wait -PassThru
        Write-Host "OneDrive uninstaller completed with exit code: $($process.ExitCode)" -ForegroundColor Green
    } else {
        Write-Host "OneDrive setup not found - may already be uninstalled" -ForegroundColor Yellow
    }

    # Remove OneDrive leftovers
    Write-Host "Removing OneDrive folders..." -ForegroundColor Yellow

    $foldersToRemove = @(
        "$env:LOCALAPPDATA\Microsoft\OneDrive",
        "$env:PROGRAMDATA\Microsoft OneDrive",
        "$env:SYSTEMDRIVE\OneDriveTemp",
        "C:\Users\Default\AppData\Local\Microsoft\OneDrive"
    )

    # Also check all user profiles
    $userProfiles = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue
    foreach ($profile in $userProfiles) {
        $foldersToRemove += "$($profile.FullName)\AppData\Local\Microsoft\OneDrive"
        $foldersToRemove += "$($profile.FullName)\OneDrive"
    }

    foreach ($folder in $foldersToRemove) {
        if (Test-Path $folder) {
            try {
                Remove-Item -Path $folder -Recurse -Force -ErrorAction Stop
                Write-Host "Removed: $folder" -ForegroundColor Green
            } catch {
                Write-Host "Could not remove $folder (may be in use): $_" -ForegroundColor Yellow
            }
        }
    }

    # Disable OneDrive via Group Policy
    Write-Host "Disabling OneDrive via Group Policy..." -ForegroundColor Yellow

    $onedrivePolicyPath = "HKLM:\SOFTWARE\Wow6432Node\Policies\Microsoft\Windows\OneDrive"
    if (!(Test-Path $onedrivePolicyPath)) {
        New-Item -Path $onedrivePolicyPath -Force | Out-Null
    }
    Set-ItemProperty -Path $onedrivePolicyPath -Name "DisableFileSyncNGSC" -Type DWord -Value 1
    Set-ItemProperty -Path $onedrivePolicyPath -Name "DisableFileSync" -Type DWord -Value 1
    Write-Host "OneDrive disabled via Group Policy" -ForegroundColor Green

    # Remove OneDrive from Explorer sidebar
    Write-Host "Removing OneDrive from Explorer..." -ForegroundColor Yellow

    # 32-bit - use Registry:: provider since HKCR: PSDrive doesn't exist by default
    $clsidPath32 = "Registry::HKEY_CLASSES_ROOT\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}"
    if (Test-Path $clsidPath32) {
        Set-ItemProperty -Path $clsidPath32 -Name "System.IsPinnedToNameSpaceTree" -Type DWord -Value 0 -ErrorAction SilentlyContinue
    }

    # 64-bit
    $clsidPath64 = "Registry::HKEY_CLASSES_ROOT\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}"
    if (Test-Path $clsidPath64) {
        Set-ItemProperty -Path $clsidPath64 -Name "System.IsPinnedToNameSpaceTree" -Type DWord -Value 0 -ErrorAction SilentlyContinue
    }
    Write-Host "OneDrive removed from Explorer sidebar" -ForegroundColor Green

    # Remove OneDrive startup entry
    Write-Host "Removing OneDrive from startup..." -ForegroundColor Yellow
    Remove-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "OneDrive" -ErrorAction SilentlyContinue
    Write-Host "OneDrive removed from startup" -ForegroundColor Green

    Write-Host ""
    Write-Host "=== OneDrive Removal Complete ===" -ForegroundColor Cyan
    Write-Host "OneDrive has been uninstalled and disabled" -ForegroundColor Green
    Write-Host "Group Policy prevents reinstallation" -ForegroundColor Green
    Write-Host "A restart may be required for all changes to take effect" -ForegroundColor Yellow
    Write-Host "=================================" -ForegroundColor Cyan

} catch {
    Write-Host "Error removing OneDrive: $_" -ForegroundColor Red
    exit 1
}

Stop-Transcript
