# oem-dell/lib/dell-detection.ps1
#
# Dell-specific detection helpers. Inlined into Dell leaf scripts at CI build
# time via a `# %INCLUDE` marker. No runtime fetch, no hash check.
#
# Provides:
#   Test-DellHardware       True if this machine is Dell.
#   Get-DellInstalledModel  Returns Win32_ComputerSystem.Model or $null.
#   Test-DCUInstalled       True if dcu-cli.exe is present at the canonical path.
#   Get-DCUVersion          Returns [version] of installed DCU, or $null.
#   Get-DCUCliPath          Returns the canonical dcu-cli.exe path.

$script:dcuCliPath = "$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe"

function Test-DellHardware {
    $manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).Manufacturer
    return ($manufacturer -like "Dell*")
}

function Get-DellInstalledModel {
    return (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).Model
}

function Test-DCUInstalled {
    return (Test-Path -Path $script:dcuCliPath)
}

function Get-DCUVersion {
    if (-not (Test-DCUInstalled)) { return $null }
    try {
        $info = (Get-Item -Path $script:dcuCliPath -ErrorAction Stop).VersionInfo
        if ($info.ProductVersion) {
            return [version]$info.ProductVersion
        }
        return $null
    } catch {
        return $null
    }
}

function Get-DCUCliPath {
    return $script:dcuCliPath
}
