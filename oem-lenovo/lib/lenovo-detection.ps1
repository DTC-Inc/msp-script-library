# oem-lenovo/lib/lenovo-detection.ps1
#
# Lenovo-specific detection helpers. Fetched at runtime alongside the shared
# OEM lib by the lib bootstrap block in each Lenovo leaf script.
#
# Provides:
#   Test-LenovoHardware     True if this machine is Lenovo.
#   Get-LenovoInstalledModel  Returns Win32_ComputerSystem.SystemFamily (e.g. "ThinkPad T14") or $null.
#   Get-LenovoMachineType   Returns Win32_ComputerSystem.Model (4-char machine type prefix) or $null.
#   Test-LSUInstalled       True if Tvsu.exe is present at the canonical path.
#   Get-LSUVersion          Returns [version] of installed LSU (Tvsu.exe ProductVersion), or $null.
#   Get-LSUCliPath          Returns the canonical Tvsu.exe path.

$script:lsuCliPath = "${env:ProgramFiles(x86)}\Lenovo\System Update\Tvsu.exe"

function Test-LenovoHardware {
    $manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).Manufacturer
    return ($manufacturer -like "LENOVO*")
}

function Get-LenovoInstalledModel {
    return (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).SystemFamily
}

function Get-LenovoMachineType {
    return (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).Model
}

function Test-LSUInstalled {
    return (Test-Path -Path $script:lsuCliPath)
}

function Get-LSUVersion {
    if (-not (Test-LSUInstalled)) { return $null }
    try {
        $info = (Get-Item -Path $script:lsuCliPath -ErrorAction Stop).VersionInfo
        if ($info.ProductVersion) {
            return [version]$info.ProductVersion
        }
        return $null
    } catch {
        return $null
    }
}

function Get-LSUCliPath {
    return $script:lsuCliPath
}
