# oem-hp/lib/hp-detection.ps1
#
# HP-specific detection helpers. Fetched at runtime alongside the shared
# OEM lib by the lib bootstrap block in each HP leaf script.
#
# Provides:
#   Test-HPHardware         True if this machine is HP.
#   Get-HPInstalledModel    Returns Win32_ComputerSystem.Model or $null.
#   Test-HPIAInstalled      True if HPImageAssistant.exe is present at a known path.
#   Get-HPIAVersion         Returns [version] of the installed HPIA, or $null.
#   Get-HPIAPath            Returns the resolved HPIA path, or $null.
#   Get-HPBCUPath           Returns the resolved BCU path, or $null.

$script:hpiaCandidates = @(
    "$env:ProgramFiles\HP\HPIA\HPImageAssistant.exe",
    "${env:ProgramFiles(x86)}\HP\HPIA\HPImageAssistant.exe"
)

$script:bcuCandidates = @(
    "${env:ProgramFiles(x86)}\Hewlett-Packard\BIOS Configuration Utility\BiosConfigUtility64.exe",
    "$env:ProgramFiles\Hewlett-Packard\BIOS Configuration Utility\BiosConfigUtility64.exe",
    "${env:ProgramFiles(x86)}\HP\BIOS Configuration Utility\BiosConfigUtility64.exe",
    "$env:ProgramFiles\HP\BIOS Configuration Utility\BiosConfigUtility64.exe"
)

function Test-HPHardware {
    $manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).Manufacturer
    return ($manufacturer -like "HP*" -or $manufacturer -like "Hewlett*")
}

function Get-HPInstalledModel {
    return (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).Model
}

function Get-HPIAPath {
    foreach ($candidate in $script:hpiaCandidates) {
        if (Test-Path -Path $candidate) { return $candidate }
    }
    return $null
}

function Test-HPIAInstalled {
    return ($null -ne (Get-HPIAPath))
}

function Get-HPIAVersion {
    $path = Get-HPIAPath
    if (-not $path) { return $null }
    try {
        $info = (Get-Item -Path $path -ErrorAction Stop).VersionInfo
        if ($info.ProductVersion) {
            return [version]$info.ProductVersion
        }
        return $null
    } catch {
        return $null
    }
}

function Get-HPBCUPath {
    foreach ($candidate in $script:bcuCandidates) {
        if (Test-Path -Path $candidate) { return $candidate }
    }
    return $null
}
