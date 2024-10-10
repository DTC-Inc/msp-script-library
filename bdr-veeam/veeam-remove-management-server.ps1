# Script to resolve Veeam agent message "Agent is managed by another Veeam server"


# Remove the certificate with the friendly name "Veeam Agent Certificate" from the LocalMachine store without asking for confirmation
Remove-Item -Path $(Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq "Veeam Agent Certificate" }).PSPath -Confirm:$false

# Clear the "License" value in the Veeam Agent for Microsoft Windows registry key
Set-ItemProperty -Path "HKLM:\SOFTWARE\Veeam\Veeam Agent for Microsoft Windows\ManagedMode" -Name "License" -Value "" -ErrorAction Ignore

# Re-enable notifications for Veeam EndPoint Backup by setting the DisableNotifications value to 0
Set-ItemProperty -Path "HKLM:\SOFTWARE\Veeam\Veeam EndPoint Backup" -Name "DisableNotifications" -Value 0 -ErrorAction Ignore

# Remove the "SerializedConnectionParams" property from the Veeam EndPoint Backup registry key
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Veeam\Veeam EndPoint Backup" -name "SerializedConnectionParams" -ErrorAction Ignore

# Remove the "ManagedModeInstallation" property from the Veeam EndPoint Backup registry key
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Veeam\Veeam EndPoint Backup" -name "ManagedModeInstallation" -ErrorAction Ignore

# Remove the "VbrServerName" property from the Veeam EndPoint Backup registry key
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Veeam\Veeam EndPoint Backup" -name "VbrServerName" -ErrorAction Ignore

# Remove the "CatchAllOwnership" property from the Veeam EndPoint Backup registry key
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Veeam\Veeam EndPoint Backup" -name "CatchAllOwnership" -ErrorAction Ignore

# Remove the "VBRServerId" property from the Veeam EndPoint Backup registry key
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Veeam\Veeam EndPoint Backup" -name "VBRServerId" -ErrorAction Ignore

# Remove the "JobSettings" property from the Veeam EndPoint Backup registry key
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Veeam\Veeam EndPoint Backup" -name "JobSettings" -ErrorAction Ignore

# Remove the "BackupServerIPAddress" property from the Veeam EndPoint Backup registry key
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Veeam\Veeam EndPoint Backup" -name "BackupServerIPAddress" -ErrorAction Ignore

# Remove the "RMMProviderMode" property from the Veeam EndPoint Backup registry key
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Veeam\Veeam EndPoint Backup" -name "RMMProviderMode" -ErrorAction Ignore

# Remove the "ReadonlyMode" property from the Veeam EndPoint Backup registry key
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Veeam\Veeam EndPoint Backup" -name "ReadonlyMode" -ErrorAction Ignore

# Restart the Veeam Agent for Microsoft Windows service to apply changes
Restart-Service "Veeam Agent for Microsoft Windows"
