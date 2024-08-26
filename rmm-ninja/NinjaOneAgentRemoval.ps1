#Get current user context
$CurrentUser = New-Object Security.Principal.WindowsPrincipal $([Security.Principal.WindowsIdentity]::GetCurrent())
#Check user that is running the script is a member of Administrator Group
if (!($CurrentUser.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator))) {
    #UAC Prompt will occur for the user to input Administrator credentials and relaunch the powershell session
    Write-Output 'This script must be ran with administrative privileges'
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs; Exit
}

$Now = Get-Date -format 'dd-MM-yyyy_HHmmss'
$LogPath = "$env:windir\temp\NinjaRemoval_$Now.txt"
Start-Transcript -Path $LogPath -Force
$ErrorActionPreference = 'SilentlyContinue'
function Uninstall-NinjaMSI {
    $Arguments = @(
        "/x$($UninstallString)"
        '/quiet'
        '/L*V'
        'C:\windows\temp\NinjaRMMAgent_uninstall.log'
        "WRAPPED_ARGUMENTS=`"--mode unattended`""
    )

    Start-Process "$NinjaInstallLocation\NinjaRMMAgent.exe" -ArgumentList "-disableUninstallPrevention NOUI"
    Start-Sleep 10
    Start-Process "msiexec.exe" -ArgumentList $Arguments -Wait -NoNewWindow
    Write-Output 'Finished running uninstaller. Continuing to clean up...'
    Start-Sleep 30
}

$NinjaRegPath = 'HKLM:\SOFTWARE\WOW6432Node\NinjaRMM LLC\NinjaRMMAgent'
$NinjaDataDirectory = "$($env:ProgramData)\NinjaRMMAgent"
$UninstallRegPath = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'

Write-Output 'Beginning NinjaRMM Agent removal...'

if (!([System.Environment]::Is64BitOperatingSystem)) {
    $NinjaRegPath = 'HKLM:\SOFTWARE\NinjaRMM LLC\NinjaRMMAgent'
    $UninstallRegPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
}

$NinjaInstallLocation = (Get-ItemPropertyValue $NinjaRegPath -Name Location).Replace('/', '\') 

if (!(Test-Path "$($NinjaInstallLocation)\NinjaRMMAgent.exe")) {
    $NinjaServicePath = ((Get-Service | Where-Object { $_.Name -eq 'NinjaRMMAgent' }).BinaryPathName).Trim('"')
    if (!(Test-Path $NinjaServicePath)) {
        Write-Output 'Unable to locate Ninja installation path. Continuing with cleanup...'
    }
    else {
        $NinjaInstallLocation = $NinjaServicePath | Split-Path
    }
}

$UninstallString = (Get-ItemProperty $UninstallRegPath  | Where-Object { ($_.DisplayName -eq 'NinjaRMMAgent') -and ($_.UninstallString -match 'msiexec') }).UninstallString

if (!($UninstallString)) {
    Write-Output 'Unable to to determine uninstall string. Continuing with cleanup...' 
}
else {
    $UninstallString = $UninstallString.Split('X')[1]
    Uninstall-NinjaMSI
}

$NinjaServices = @('NinjaRMMAgent', 'nmsmanager', 'lockhart')
$Processes = @("NinjaRMMAgent", "NinjaRMMAgentPatcher", "njbar", "NinjaRMMProxyProcess64")


foreach ($Process in $Processes) {
    Get-Process $Process | Stop-Process -Force 
}

foreach ($NS in $NinjaServices) {
    if (($NS -eq 'lockhart') -and !(Test-Path "$NinjaInstallLocation\lockhart\bin\lockhart.exe")) {
        continue
    }
    if (Get-Service $NS) {
        & sc.exe DELETE $NS
        Start-Sleep 2
        if (Get-Service $NS) {
            Write-Output "Failed to remove service: $($NS). Continuing with removal attempt..."
        }
    }
}

if (Test-Path $NinjaInstallLocation) {
    Remove-Item $NinjaInstallLocation -Recurse -Forc
    if (Test-Path $NinjaInstallLocation) {
        Write-Output 'Failed to remove Ninja Installation Directory:'
        Write-Output "$NinjaInstallLocation"
        Write-Output 'Continuing with removal attempt...'
    } 
}

if (Test-Path $NinjaDataDirectory) {
    Remove-Item $NinjaDataDirectory -Recurse -Force
    if (Test-Path $NinjaDataDirectory) {
        Write-Output 'Failed to remove Ninja Data Directory:'
        Write-Output "$NinjaDataDirectory"
        Write-Output 'Continuing with removal attempt...'
    }
}

$MSIWrapperReg = 'HKLM:\SOFTWARE\WOW6432Node\EXEMSI.COM\MSI Wrapper\Installed'
$ProductInstallerReg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products'

$RegKeysToRemove = [System.Collections.Generic.List[object]]::New()

(Get-ItemProperty $UninstallRegPath | Where-Object { $_.DisplayName -eq 'NinjaRMMAgent' }).PSPath | ForEach-Object { $RegKeysToRemove.Add($_) }
(Get-ItemProperty $ProductInstallerReg | Where-Object { $_.ProductName -eq 'NinjaRMMAgent' }).PSPath | ForEach-Object { $RegKeysToRemove.Add($_) }
(Get-ChildItem $MSIWrapperReg | Where-Object { $_.Name -match 'NinjaRMMAgent' }).PSPAth | ForEach-Object { $RegKeysToRemove.Add($_) }


$ProductInstallerKeys = Get-ChildItem $ProductInstallerReg | Select-Object *
foreach ($Key in $ProductInstallerKeys) {
    $KeyName = $($Key.Name).Replace('HKEY_LOCAL_MACHINE', 'HKLM:') + "\InstallProperties"
    if (Get-ItemProperty $KeyName | Where-Object { $_.DisplayName -eq 'NinjaRMMAgent' }) {
        $RegKeysToRemove.Add($Key.PSPath)
    }
}

Write-Output 'Removing registry items if found...'
foreach ($RegKey in $RegKeysToRemove) {
    if (!([string]::IsNullOrEmpty($RegKey))) {
        Write-Output "Removing: $($RegKey)"
        Remove-Item $RegKey -Recurse -Force
    }
}

if (Test-Path $NinjaRegPath) {
    Get-Item ($NinjaRegPath | Split-Path) | Remove-Item -Recurse -Force
    Write-Output "Removing: $($NinjaRegPath)"
}

foreach ($RegKey in $RegKeysToRemove) {
    if (!([string]::IsNullOrEmpty($RegKey))) {
        if (Test-Path $RegKey) {
            Write-Output 'Failed to remove the following registry key:'
            Write-Output "$($RegKey)"
        }
    }   
}

if (Test-Path $NinjaRegPath) {
    Write-Output "$NinjaRegPath"
}

Write-Output 'Removal script completed. Please review if any errors displayed.'
Stop-Transcript