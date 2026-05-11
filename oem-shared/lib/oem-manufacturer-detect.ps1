# oem-shared/lib/oem-manufacturer-detect.ps1
#
# Shared helpers for OEM-specific scripts. Fetched at runtime via the lib
# bootstrap pattern (see CLAUDE.md -> Lib Bootstrap Pattern).
#
# Provides:
#   Get-OEMManufacturer    Returns "Dell" / "HP" / "Lenovo" / "Unknown".
#   Get-VerifiedDownload   Downloads a URL to a path and verifies SHA256.

function Get-OEMManufacturer {
    $manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).Manufacturer
    if ([string]::IsNullOrEmpty($manufacturer)) {
        return "Unknown"
    }
    switch -Wildcard ($manufacturer) {
        "Dell*"    { return "Dell" }
        "HP*"      { return "HP" }
        "Hewlett*" { return "HP" }
        "Lenovo*"  { return "Lenovo" }
        default    { return "Unknown" }
    }
}

function Get-VerifiedDownload {
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $OutFile,
        [Parameter(Mandatory)] [string] $Sha256
    )

    $dir = Split-Path -Path $OutFile -Parent
    if ($dir -and -not (Test-Path -Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop

    $actual = (Get-FileHash -Path $OutFile -Algorithm SHA256).Hash
    if ($actual -ne $Sha256) {
        Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue
        throw "SHA256 mismatch for $Url. Expected $Sha256, got $actual."
    }

    return $OutFile
}
