# oem-dell/lib/dell-bios-translation.ps1
#
# Dell BIOS settings translation table. Maps the canonical $env:BIOS_* variable
# names defined in CLAUDE.md to the Dell Command Configure (cctk.exe) argument
# syntax. Inlined into dell-configure.ps1 at CI build time.
#
# Provides:
#   $script:DellBiosSettingsMap   hashtable: canonical name -> cctk descriptor.
#   Get-DellBiosSetting           returns the descriptor for a canonical name.
#
# Descriptor shape:
#   @{
#       Native = '<cctk subcommand or option name>'
#       Values = @{ <CanonicalValue> = '<cctk value>' ; ... }
#       Form   = 'KeyValue' | 'Subcommand'
#   }
#
# Form='KeyValue'  emits  --<Native>=<value>          (e.g. --tpm=on)
# Form='Subcommand' emits <Native> --<paramName>=<v>  for things that need their
#                  own cctk subcommand line (e.g. bootorder --activebootlist=uefi).
#
# Password handling for $env:BIOS_AdminPassword / $env:BIOS_AdminPasswordNew is
# not in this table; dell-configure.ps1 emits the cctk password flags directly
# because the password mechanic is its own special case (current pw + new pw +
# clear pw all map to different cctk syntax).
#
# Settings that Dell does not support (or that we have not validated yet) are
# intentionally absent. dell-configure.ps1 logs and skips unknown canonical
# names so operators can set forward-looking vars without breaking the run.

$script:DellBiosSettingsMap = @{
    BIOS_TPMEnabled = @{
        Native = 'tpm'
        Values = @{ Enabled = 'on'; Disabled = 'off' }
        Form   = 'KeyValue'
    }
    BIOS_TPMActivation = @{
        Native = 'tpmactivation'
        Values = @{ Activated = 'activate'; Deactivated = 'deactivate' }
        Form   = 'KeyValue'
    }
    BIOS_SecureBoot = @{
        Native = 'secureboot'
        Values = @{ Enabled = 'enabled'; Disabled = 'disabled' }
        Form   = 'KeyValue'
    }
    BIOS_VirtualizationCPU = @{
        Native = 'virtualization'
        Values = @{ Enabled = 'enable'; Disabled = 'disable' }
        Form   = 'KeyValue'
    }
    BIOS_VirtualizationIOMMU = @{
        Native = 'vtfordirectio'
        Values = @{ Enabled = 'enable'; Disabled = 'disable' }
        Form   = 'KeyValue'
    }
    BIOS_WakeOnLAN = @{
        Native = 'wakeonlan'
        Values = @{
            Enabled  = 'lan'
            Disabled = 'disable'
            LANOnly  = 'lan'
            LANWLAN  = 'lanwlan'
        }
        Form = 'KeyValue'
    }
    BIOS_BootMode = @{
        Native = 'bootorder'
        Values = @{ UEFI = 'uefi'; Legacy = 'legacy' }
        Form   = 'Subcommand'
        Param  = 'activebootlist'
    }
}

function Get-DellBiosSetting {
    param([Parameter(Mandatory)] [string] $CanonicalName)
    if ($script:DellBiosSettingsMap.ContainsKey($CanonicalName)) {
        return $script:DellBiosSettingsMap[$CanonicalName]
    }
    return $null
}
