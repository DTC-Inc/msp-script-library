# Stop and disable ITSPlatform services
& "C:\Program Files (x86)\ITSPlatform\agentcore\platform-agent-core.exe" "C:\Program Files (x86)\ITSPlatform\config\platform_agent_core_cfg.json" "C:\Program Files (x86)\ITSPlatform\log\platform_agent_core.log" stopservice
& "C:\Program Files (x86)\ITSPlatform\agentcore\platform-agent-core.exe" "C:\Program Files (x86)\ITSPlatform\config\platform_agent_core_cfg.json" "C:\Program Files (x86)\ITSPlatform\log\platform_agent_core.log" disableservice
& "C:\Program Files (x86)\ITSPlatform\agentmanager\platform-agent-manager.exe" stopservice "C:\Program Files (x86)\ITSPlatform\log\platform_agent_manager.log" "C:\Program Files (x86)\ITSPlatform\config\platform_agent_core_cfg.json"
& "C:\Program Files (x86)\ITSPlatform\agentmanager\platform-agent-manager.exe" disableservice "C:\Program Files (x86)\ITSPlatform\log\platform_agent_manager.log" "C:\Program Files (x86)\ITSPlatform\config\platform_agent_core_cfg.json"

#Uninstall ITSPlatform agent
& "C:\Program Files (x86)\ITSPlatform\agentcore\platform-agent-core.exe" "C:\Program Files (x86)\ITSPlatform\config\platform_agent_core_cfg.json" "C:\Program Files (x86)\ITSPlatformSetupLogs\platform_agent_core.log" uninstallagent


$serviceNames = @("SAAZappr", "SAAZDPMACTL", "SAAZRemoteSupport", "SAAZScheduler", "SAAZServerPlus", "SAAZWatchDog")

$serviceNames | ForEach-Object {
    # Get the service object with error handling
    $service = Get-Service -Name $_ -ErrorAction SilentlyContinue

    if ($service) {
        # Stop the service if it is running
        if ($service.Status -eq 'Running') {
            Stop-Service -Name $_ -Force -ErrorAction SilentlyContinue
            # Wait for the service to stop
            do {
                Start-Sleep -Seconds 1
            } while ((Get-Service -Name $_ -ErrorAction SilentlyContinue).Status -ne 'Stopped')
        }

        # Set the service to disabled
        Set-Service -Name $_ -StartupType Disabled -ErrorAction SilentlyContinue

	
        } else {
        Write-Output "Service $_ does not exist or cannot be accessed."
    }
}

# Remove services
sc.exe delete -Name "SAAZappr"
sc.exe delete -Name "SAAZDPMACTL"
sc.exe delete -Name "SAAZRemoteSupport"
sc.exe delete -Name "SAAZScheduler"
sc.exe delete -Name "SAAZServerPlus"
sc.exe delete -Name "SAAZWatchDog"

# Remove directories
$paths = @("C:\Program Files (x86)\SAAZOD", "C:\Program Files (x86)\SAAZODBKP")
$paths | ForEach-Object {
    If (Test-Path $_) {
        Remove-Item $_ -Force -Recurse
    }
}

# Remove registry items
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest" -Name "ITSPlatformID" -Force -ErrorAction SilentlyContinue
Remove-Item "HKLM:\SOFTWARE\WOW6432Node\SAAZOD" -Force -ErrorAction SilentlyContinue

$regKeys = @("HKLM:\SYSTEM\CurrentControlSet\Services\SAAZappr", "HKLM:\SYSTEM\CurrentControlSet\Services\SAAZDPMACTL", 
             "HKLM:\SYSTEM\CurrentControlSet\Services\SAAZRemoteSupport", "HKLM:\SYSTEM\CurrentControlSet\Services\SAAZScheduler", 
             "HKLM:\SYSTEM\CurrentControlSet\Services\SAAZServerPlus", "HKLM:\SYSTEM\CurrentControlSet\Services\SAAZWatchDog")
$regKeys | ForEach-Object { Remove-Item $_ -Force -ErrorAction SilentlyContinue }
