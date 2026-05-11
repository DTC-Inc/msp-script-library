# oem-shared/lib/oem-manufacturer-detect.ps1
#
# Shared OEM manufacturer detection. Inlined into every OEM leaf script at
# CI build time via a `# %INCLUDE` marker. No runtime fetch, no hash check.
#
# Provides:
#   Get-OEMManufacturer    Returns "Dell" / "HP" / "Lenovo" / "Unknown".

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
