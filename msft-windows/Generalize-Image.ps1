# Generalize-Image.ps1
# Run as Administrator!

# 1. Remove specific registry value for NinjaRMM
$regPath = 'HKLM:\Software\Wow6432Node\NinjaRMM LLC\NinjaRMMAgent\Agent'
$regValue = 'MachineId'
if (Test-Path $regPath) {
    Remove-ItemProperty -Path $regPath -Name $regValue -ErrorAction SilentlyContinue
}

# 2. Remove specific ProgramData folder for NinjaRMMAgent
$folder = 'C:\ProgramData\NinjaRMMAgent'
if (Test-Path $folder) {
    Remove-Item -Path $folder -Recurse -Force
}

# 3. Clean up user profiles except for necessary ones
$keepProfiles = @(
    "Public",
    "Administrator",
    "Guest",
    "WDAGUtilityAccount",
    "DefaultAccount"
)
$profileList = Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.Special -eq $false -and $_.LocalPath -like "C:\\Users\\*" }
foreach ($profile in $profileList) {
    $user = Split-Path $profile.LocalPath -Leaf
    if ($keepProfiles -notcontains $user) {
        Write-Host "Deleting profile: $user"
        Remove-CimInstance -InputObject $profile
    }
}

# 4. Clean up Windows logs
$logPath = "C:\Windows\System32\winevt\Logs\*"
Remove-Item -Path $logPath -Force -Recurse -ErrorAction SilentlyContinue

# 5. Clean up Panther folder
$pantherPath = "$env:SystemRoot\Panther\*"
Remove-Item -Path $pantherPath -Force -Recurse -ErrorAction SilentlyContinue

# 6. Clean up Windows Temp folder
Remove-Item -Path "C:\Windows\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue

# 7. Clean up each user's Temp folder
Get-ChildItem 'C:\Users' | ForEach-Object {
    $temp = "$($_.FullName)\AppData\Local\Temp"
    if (Test-Path $temp) {
        Remove-Item -Path "$temp\*" -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# 8. Clean up Prefetch
Remove-Item -Path "C:\Windows\Prefetch\*" -Recurse -Force -ErrorAction SilentlyContinue

# 9. Clean up Windows Update cache
Remove-Item -Path "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue

# 10. Check for pending reboot flags
function Test-PendingReboot {
    $reboot = $false

    # Windows Update
    $wu = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    if (Test-Path $wu) { $reboot = $true }

    # Component Based Servicing
    $cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    if (Test-Path $cbs) { $reboot = $true }

    # Pending File Rename Operations
    $pendingFileRename = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue)
    if ($pendingFileRename) { $reboot = $true }

    # Pending Computer Rename
    $computerName = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'
    $activeName = (Get-ItemProperty -Path $computerName -Name 'ComputerName' -ErrorAction SilentlyContinue).ComputerName
    $pendingName = (Get-ItemProperty -Path $computerName -Name 'ActiveComputerName' -ErrorAction SilentlyContinue).ActiveComputerName
    if ($activeName -ne $pendingName) { $reboot = $true }

    return $reboot
}

if (Test-PendingReboot) {
    Write-Warning "A pending reboot is detected! Please reboot the system before running Sysprep."
} else {
    Write-Host "No pending reboot detected. Safe to proceed with Sysprep."
}

# Create unattend.xml for Sysprep
$unattendContent = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <TimeZone>Eastern Standard Time</TimeZone>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>installadmin</Name>
            <Group>Administrators</Group>
            <Password>
              <Value>DTC@dental2025</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Username>installadmin</Username>
        <Password>
          <Value>DTC@dental2025</Value>
          <PlainText>true</PlainText>
        </Password>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
      </AutoLogon>
    </component>
  </settings>

  <settings pass="specialize">
    <component name="Microsoft-Windows-Feedback" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <DisableFeedback>true</DisableFeedback>
    </component>
    <component name="Microsoft-Windows-CEIPEnable" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <CEIPEnable>false</CEIPEnable>
    </component>
    <component name="Microsoft-Windows-ApplicationExperience" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <AITEnable>false</AITEnable>
    </component>
    <component name="Microsoft-Windows-ErrorReportingCore" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <DisableWerReporting>true</DisableWerReporting>
    </component>
  </settings>
</unattend>
"@

$unattendPath = "C:\Windows\System32\Sysprep\unattend.xml"
$unattendContent | Set-Content -Path $unattendPath -Encoding UTF8
Write-Host "unattend.xml created at $unattendPath"

Write-Host "Cleanup complete. You can now run Sysprep." 