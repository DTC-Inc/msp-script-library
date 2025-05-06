# Navigate to Windows Defender directory
cd "C:\Program Files\Windows Defender"

# Reset Windows Defender components (use .\ to run from current directory)
.\MpCmdRun.exe -Restore -All

# Force a restart of all relevant services
Stop-Service -Name WinDefend -Force
Start-Service -Name WinDefend

# Force Windows Defender to re-register itself
.\MpCmdRun.exe -RegisterAllDlls

# Reset Windows Security Center
Stop-Service -Name wscsvc -Force
Start-Service -Name wscsvc

# Try to reset tamper protection if enabled
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows Defender\Features" -Name "TamperProtection" -Value 0 -Type DWord

# Reset security health service
Stop-Service -Name SecurityHealthService -Force
Start-Service -Name SecurityHealthService

# Reset the Defender platform
.\MpCmdRun.exe -RemoveDefinitions -All
.\MpCmdRun.exe -SignatureUpdate

# Force Defender to run
Start-Process "C:\Program Files\Windows Defender\MSASCui.exe"


# Check if Windows Defender is now enabled
Get-MpComputerStatus | Select-Object AntivirusEnabled, RealTimeProtectionEnabled, IoavProtectionEnabled, NISEnabled
