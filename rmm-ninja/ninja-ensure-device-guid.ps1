## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                    - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description            - Ticket # or initials for audit trail
## $env:RMMScriptPath          - Optional log directory base provided by the RMM
## $env:CustomFieldDeviceGuid  - NinjaOne device text field API name for the device OUID (default: "deviceGuid")
##
## Ensures this device has a DTC Operational UUID (OUID), the "Device GUID".
## Mints a UUIDv7 ONCE and persists it in two places per the DTC OUID Standard:
##   - On-device:  registry HKLM\SOFTWARE\DTC\DeviceGuid (self-identify without network)
##   - NinjaOne:   device custom field (authoritative source of truth)
##
## Idempotent and self-healing -- safe to run on every boot:
##   - Both present and equal      -> nothing to do, exit 0.
##   - Both present but DIFFERENT   -> conflict, never overwrite an assigned OUID, exit 1.
##   - Only one present             -> backfill the other from it, exit 0.
##   - Neither present              -> mint a new UUIDv7, write both, exit 0.
##
## The device OUID is assigned once and never changes (DTC OUID Standard). It is
## the stable, recomputable identity that downstream provisioning (e.g. the Veeam
## S3 repo folder) depends on. Run this BEFORE any script that reads the Device GUID.
##
## Requires SYSTEM/admin context: writes HKLM and calls Ninja-Property-Set/Get
## (which only work in SYSTEM context). Configure as a boot trigger in NinjaOne.

$ScriptLogName = "ninja-ensure-device-guid.log"
$GuidRegex = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
$RegPath = "HKLM:\SOFTWARE\DTC"
$RegValueName = "DeviceGuid"

# --- Default optional RMM environment variables --------------------------

if ([string]::IsNullOrEmpty($env:CustomFieldDeviceGuid)) {
    $env:CustomFieldDeviceGuid = "deviceGuid"
}

# --- Helper functions ----------------------------------------------------

function New-UuidV7 {
    # Generates a UUIDv7 (RFC 9562) as a lowercase dashed string.
    # Prefers the runtime's native generator (.NET 9+); otherwise builds it by
    # hand so the script has no dependency on Node/Python/newer .NET.
    try {
        $method = [System.Guid].GetMethod('CreateVersion7', [Type]::EmptyTypes)
        if ($method) {
            return ([System.Guid]::CreateVersion7()).ToString().ToLower()
        }
    } catch { }

    # Manual RFC 9562 layout:
    #   48 bits Unix epoch ms (big-endian) | 4 bits version 0x7 | 12 bits random
    #   | 2 bits variant 0b10 | 62 bits random
    $unixMs = [long][System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    $bytes = New-Object 'System.Byte[]' 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }

    # Timestamp into the first 6 bytes, most-significant first.
    $bytes[0] = [byte](($unixMs -shr 40) -band 0xFF)
    $bytes[1] = [byte](($unixMs -shr 32) -band 0xFF)
    $bytes[2] = [byte](($unixMs -shr 24) -band 0xFF)
    $bytes[3] = [byte](($unixMs -shr 16) -band 0xFF)
    $bytes[4] = [byte](($unixMs -shr 8)  -band 0xFF)
    $bytes[5] = [byte]( $unixMs          -band 0xFF)

    # Version 7 in the high nibble of byte 6; variant 0b10 in the high bits of byte 8.
    $bytes[6] = [byte](($bytes[6] -band 0x0F) -bor 0x70)
    $bytes[8] = [byte](($bytes[8] -band 0x3F) -bor 0x80)

    # Build the string manually. [System.Guid](byte[]) reads the first three
    # groups little-endian, which would scramble our big-endian timestamp, so
    # format straight from the hex instead.
    $hex = (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    return ("{0}-{1}-{2}-{3}-{4}" -f `
        $hex.Substring(0, 8), $hex.Substring(8, 4), $hex.Substring(12, 4), `
        $hex.Substring(16, 4), $hex.Substring(20, 12))
}

function Get-RegistryGuid {
    try {
        $item = Get-ItemProperty -Path $RegPath -Name $RegValueName -ErrorAction Stop
        $val = "$($item.$RegValueName)"
        if ($val -match $GuidRegex) { return $val.ToLower() }
    } catch { }
    return $null
}

function Set-RegistryGuid {
    param([string]$Value)
    if (-not (Test-Path $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
    }
    New-ItemProperty -Path $RegPath -Name $RegValueName -Value $Value -PropertyType String -Force | Out-Null
}

function Get-NinjaGuid {
    if (-not (Get-Command "Ninja-Property-Get" -ErrorAction SilentlyContinue)) { return $null }
    try {
        $val = "$(Ninja-Property-Get $env:CustomFieldDeviceGuid 2>$null)"
        if ($val -match $GuidRegex) { return $val.ToLower() }
    } catch { }
    return $null
}

function Set-NinjaGuid {
    param([string]$Value)
    if (-not (Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue)) {
        Write-Host "  [SKIP] Ninja-Property-Set not available (not SYSTEM context). Skipped NinjaOne write."
        return $false
    }
    try {
        Ninja-Property-Set $env:CustomFieldDeviceGuid $Value
        Write-Host "  [OK] NinjaOne field '$env:CustomFieldDeviceGuid' = $Value"
        return $true
    } catch {
        Write-Warning "  Failed to write NinjaOne field: $_"
        return $false
    }
}

# --- Input handling: RMM vs interactive ----------------------------------

if ($env:RMM -ne "1") {
    $ValidInput = 0
    while ($ValidInput -ne 1) {
        $env:Description = Read-Host "Please enter the ticket # and/or your initials for audit trail"
        if ($env:Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"
} else {
    if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
        $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$env:WINDIR\logs\$ScriptLogName"
    }
    if ([string]::IsNullOrEmpty($env:Description)) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $env:Description = "No Description"
    }
}

$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# --- Script logic --------------------------------------------------------

Start-Transcript -Path $LogPath

Write-Host "=== Ensure Device OUID (Device GUID) ==="
Write-Host "Description:  $env:Description"
Write-Host "Log path:     $LogPath"
Write-Host "RMM:          $env:RMM"
Write-Host "Ninja field:  $env:CustomFieldDeviceGuid"
Write-Host ""

$regGuid = Get-RegistryGuid
$ninjaGuid = Get-NinjaGuid

Write-Host "Current state:"
Write-Host "  Registry ($RegPath\$RegValueName): $(if ($regGuid) { $regGuid } else { '(empty)' })"
Write-Host "  NinjaOne ($env:CustomFieldDeviceGuid):           $(if ($ninjaGuid) { $ninjaGuid } else { '(empty)' })"
Write-Host ""

$exitCode = 0

if ($regGuid -and $ninjaGuid) {
    if ($regGuid -eq $ninjaGuid) {
        Write-Host "Device OUID already present and consistent. Nothing to do: $regGuid"
    } else {
        # An OUID is assigned once and never changes. Two different values is a
        # genuine conflict that a human must resolve -- do NOT silently overwrite.
        Write-Error "CONFLICT: registry ($regGuid) and NinjaOne ($ninjaGuid) hold DIFFERENT device OUIDs. An OUID is assigned once and never changes. Resolve manually -- do not overwrite without confirming which is the established data path."
        $exitCode = 1
    }
} elseif ($regGuid -and -not $ninjaGuid) {
    Write-Host "Backfilling NinjaOne from on-device registry value..."
    Set-NinjaGuid -Value $regGuid | Out-Null
} elseif (-not $regGuid -and $ninjaGuid) {
    Write-Host "Backfilling on-device registry from NinjaOne value..."
    Set-RegistryGuid -Value $ninjaGuid
    Write-Host "  [OK] Registry $RegPath\$RegValueName = $ninjaGuid"
} else {
    Write-Host "No device OUID found. Minting a new UUIDv7..."
    $newGuid = New-UuidV7
    if ($newGuid -notmatch $GuidRegex) {
        Write-Error "Generated value '$newGuid' is not a valid UUID. Aborting before persisting."
        Stop-Transcript
        exit 1
    }
    Write-Host "  Minted: $newGuid"
    Set-RegistryGuid -Value $newGuid
    Write-Host "  [OK] Registry $RegPath\$RegValueName = $newGuid"
    Set-NinjaGuid -Value $newGuid | Out-Null
}

Write-Host ""
Write-Host "=== Script complete (exit $exitCode) ==="

Stop-Transcript
exit $exitCode
