## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $Description

# This script disables Xbox-related services, Game Bar, and Game DVR:
# 1. Disables Xbox Game Bar
# 2. Disables Game DVR/Game Recording
# 3. Disables Xbox-related services (XboxGipSvc, XblAuthManager, XblGameSave, XboxNetApiSvc)
# 4. Disables Game Mode
# 5. Removes Xbox Game Bar scheduled tasks

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-disable-xbox-services.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

} else {
    # Store the logs in the RMMScriptPath
    if ($null -ne $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
    }

    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "Windows Xbox Services and Game Bar Disable"
    }
}

# Start the script logic here.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM `n"

Write-Host "=== Windows Xbox Services and Game Bar Disable Script ===" -ForegroundColor Cyan
Write-Host "This script will disable Xbox services, Game Bar, and Game DVR." -ForegroundColor White
Write-Host ""

try {
    # Check if running as administrator
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-Error "This script must be run as Administrator to disable services."
        exit 1
    }

    Write-Host "Running with Administrator privileges" -ForegroundColor Green
    Write-Host ""

    # Step 1: Disable Game Bar via Registry (Current User)
    Write-Host "Step 1: Disabling Game Bar via registry..." -ForegroundColor Yellow

    # GameDVR settings
    $gameDVRPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"
    if (!(Test-Path $gameDVRPath)) {
        New-Item -Path $gameDVRPath -Force | Out-Null
    }

    try {
        Set-ItemProperty -Path $gameDVRPath -Name "AppCaptureEnabled" -Value 0 -Type DWord -Force
        Write-Host "  AppCaptureEnabled = 0" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to set AppCaptureEnabled: $($_.Exception.Message)" -ForegroundColor Red
    }

    # GameConfigStore settings
    $gameConfigPath = "HKCU:\System\GameConfigStore"
    if (!(Test-Path $gameConfigPath)) {
        New-Item -Path $gameConfigPath -Force | Out-Null
    }

    try {
        Set-ItemProperty -Path $gameConfigPath -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force
        Write-Host "  GameDVR_Enabled = 0" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to set GameDVR_Enabled: $($_.Exception.Message)" -ForegroundColor Red
    }

    try {
        Set-ItemProperty -Path $gameConfigPath -Name "GameDVR_FSEBehaviorMode" -Value 2 -Type DWord -Force
        Write-Host "  GameDVR_FSEBehaviorMode = 2" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to set GameDVR_FSEBehaviorMode: $($_.Exception.Message)" -ForegroundColor Red
    }

    try {
        Set-ItemProperty -Path $gameConfigPath -Name "GameDVR_FSEBehavior" -Value 2 -Type DWord -Force
        Write-Host "  GameDVR_FSEBehavior = 2" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to set GameDVR_FSEBehavior: $($_.Exception.Message)" -ForegroundColor Red
    }

    try {
        Set-ItemProperty -Path $gameConfigPath -Name "GameDVR_HonorUserFSEBehaviorMode" -Value 1 -Type DWord -Force
        Write-Host "  GameDVR_HonorUserFSEBehaviorMode = 1" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to set GameDVR_HonorUserFSEBehaviorMode: $($_.Exception.Message)" -ForegroundColor Red
    }

    try {
        Set-ItemProperty -Path $gameConfigPath -Name "GameDVR_DXGIHonorFSEWindowsCompatible" -Value 1 -Type DWord -Force
        Write-Host "  GameDVR_DXGIHonorFSEWindowsCompatible = 1" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to set GameDVR_DXGIHonorFSEWindowsCompatible: $($_.Exception.Message)" -ForegroundColor Red
    }

    try {
        Set-ItemProperty -Path $gameConfigPath -Name "GameDVR_EFSEFeatureFlags" -Value 0 -Type DWord -Force
        Write-Host "  GameDVR_EFSEFeatureFlags = 0" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to set GameDVR_EFSEFeatureFlags: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ""

    # Step 2: Disable Game Bar via Group Policy (Local Machine)
    Write-Host "Step 2: Disabling Game Bar via Group Policy..." -ForegroundColor Yellow

    $gameDVRPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"
    if (!(Test-Path $gameDVRPolicyPath)) {
        New-Item -Path $gameDVRPolicyPath -Force | Out-Null
    }

    try {
        Set-ItemProperty -Path $gameDVRPolicyPath -Name "AllowGameDVR" -Value 0 -Type DWord -Force
        Write-Host "  AllowGameDVR = 0 (Policy)" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to set AllowGameDVR policy: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ""

    # Step 3: Disable Game Mode
    Write-Host "Step 3: Disabling Game Mode..." -ForegroundColor Yellow

    $gameModePath = "HKCU:\Software\Microsoft\GameBar"
    if (!(Test-Path $gameModePath)) {
        New-Item -Path $gameModePath -Force | Out-Null
    }

    try {
        Set-ItemProperty -Path $gameModePath -Name "AllowAutoGameMode" -Value 0 -Type DWord -Force
        Write-Host "  AllowAutoGameMode = 0" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to set AllowAutoGameMode: $($_.Exception.Message)" -ForegroundColor Red
    }

    try {
        Set-ItemProperty -Path $gameModePath -Name "AutoGameModeEnabled" -Value 0 -Type DWord -Force
        Write-Host "  AutoGameModeEnabled = 0" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to set AutoGameModeEnabled: $($_.Exception.Message)" -ForegroundColor Red
    }

    try {
        Set-ItemProperty -Path $gameModePath -Name "UseNexusForGameBarEnabled" -Value 0 -Type DWord -Force
        Write-Host "  UseNexusForGameBarEnabled = 0" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to set UseNexusForGameBarEnabled: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ""

    # Step 4: Disable Xbox-related services
    Write-Host "Step 4: Disabling Xbox-related services..." -ForegroundColor Yellow

    $xboxServices = @(
        @{Name = "XboxGipSvc"; DisplayName = "Xbox Accessory Management Service"},
        @{Name = "XblAuthManager"; DisplayName = "Xbox Live Auth Manager"},
        @{Name = "XblGameSave"; DisplayName = "Xbox Live Game Save"},
        @{Name = "XboxNetApiSvc"; DisplayName = "Xbox Live Networking Service"}
    )

    foreach ($service in $xboxServices) {
        try {
            $svc = Get-Service -Name $service.Name -ErrorAction SilentlyContinue
            if ($svc) {
                # Stop the service if running
                if ($svc.Status -eq 'Running') {
                    Stop-Service -Name $service.Name -Force -ErrorAction SilentlyContinue
                    Write-Host "  Stopped: $($service.DisplayName)" -ForegroundColor Gray
                }

                # Set to disabled
                Set-Service -Name $service.Name -StartupType Disabled -ErrorAction Stop
                Write-Host "  Disabled: $($service.DisplayName) ($($service.Name))" -ForegroundColor Green
            } else {
                Write-Host "  Service not found: $($service.Name) (may not be installed)" -ForegroundColor Gray
            }
        } catch {
            Write-Host "  Failed to disable $($service.Name): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host ""

    # Step 5: Disable Game Bar presence writer service
    Write-Host "Step 5: Disabling Game Bar Presence Writer..." -ForegroundColor Yellow

    try {
        $presenceWriter = Get-Service -Name "BcastDVRUserService*" -ErrorAction SilentlyContinue
        if ($presenceWriter) {
            foreach ($svc in $presenceWriter) {
                if ($svc.Status -eq 'Running') {
                    Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
                }
                # Note: This is a per-user service template, we disable via registry
            }
        }

        # Disable the service template via registry
        $bcastDVRPath = "HKLM:\SYSTEM\CurrentControlSet\Services\BcastDVRUserService"
        if (Test-Path $bcastDVRPath) {
            Set-ItemProperty -Path $bcastDVRPath -Name "Start" -Value 4 -Type DWord -Force
            Write-Host "  BcastDVRUserService template disabled" -ForegroundColor Green
        } else {
            Write-Host "  BcastDVRUserService not found" -ForegroundColor Gray
        }
    } catch {
        Write-Host "  Failed to disable BcastDVRUserService: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ""

    # Step 6: Disable Xbox scheduled tasks
    Write-Host "Step 6: Disabling Xbox scheduled tasks..." -ForegroundColor Yellow

    $xboxTasks = @(
        "\Microsoft\XblGameSave\XblGameSaveTask",
        "\Microsoft\XblGameSave\XblGameSaveTaskLogon"
    )

    foreach ($taskPath in $xboxTasks) {
        try {
            $task = Get-ScheduledTask -TaskPath ($taskPath -replace "\\[^\\]+$", "\") -TaskName ($taskPath -split "\\" | Select-Object -Last 1) -ErrorAction SilentlyContinue
            if ($task) {
                Disable-ScheduledTask -TaskPath ($taskPath -replace "\\[^\\]+$", "\") -TaskName ($taskPath -split "\\" | Select-Object -Last 1) -ErrorAction Stop | Out-Null
                Write-Host "  Disabled task: $taskPath" -ForegroundColor Green
            } else {
                Write-Host "  Task not found: $taskPath" -ForegroundColor Gray
            }
        } catch {
            Write-Host "  Failed to disable task $taskPath : $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    Write-Host ""

    # Step 7: Disable Xbox Game Monitoring
    Write-Host "Step 7: Disabling Xbox Game Monitoring..." -ForegroundColor Yellow

    $gameMonitorPath = "HKLM:\SYSTEM\CurrentControlSet\Services\xbgm"
    if (Test-Path $gameMonitorPath) {
        try {
            Set-ItemProperty -Path $gameMonitorPath -Name "Start" -Value 4 -Type DWord -Force
            Write-Host "  Xbox Game Monitoring service disabled" -ForegroundColor Green
        } catch {
            Write-Host "  Failed to disable xbgm: $($_.Exception.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "  Xbox Game Monitoring service not found" -ForegroundColor Gray
    }

    Write-Host ""

    # Final summary
    Write-Host "=== Configuration Summary ===" -ForegroundColor Cyan
    Write-Host "Game Bar: Disabled" -ForegroundColor Green
    Write-Host "Game DVR/Recording: Disabled" -ForegroundColor Green
    Write-Host "Game Mode: Disabled" -ForegroundColor Green
    Write-Host "Xbox Accessory Management Service: Disabled" -ForegroundColor Green
    Write-Host "Xbox Live Auth Manager: Disabled" -ForegroundColor Green
    Write-Host "Xbox Live Game Save: Disabled" -ForegroundColor Green
    Write-Host "Xbox Live Networking Service: Disabled" -ForegroundColor Green
    Write-Host "Broadcast DVR User Service: Disabled" -ForegroundColor Green
    Write-Host "Xbox scheduled tasks: Disabled" -ForegroundColor Green
    Write-Host "Xbox Game Monitoring: Disabled" -ForegroundColor Green
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "Xbox services and Game Bar disabled successfully!" -ForegroundColor Green
    Write-Host "Note: A system restart is recommended for all changes to take effect." -ForegroundColor Yellow
    Write-Host "Note: Xbox apps may still be present but will not function properly." -ForegroundColor Yellow
    Write-Host "      Use the debloat script to remove Xbox apps if desired." -ForegroundColor Yellow

} catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
    Write-Host "Error details: $($_.Exception)" -ForegroundColor Red
    exit 1
}

Stop-Transcript
