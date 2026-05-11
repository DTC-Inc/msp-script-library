## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                       - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description               - Ticket # or initials for audit trail
## $env:RMMScriptPath             - Optional log directory base provided by the RMM

$ScriptLogName = "lenovo-debloat.log"

# --- Default optional RMM environment variables --------------------------

# === LIB BOOTSTRAP ===
# Libs are pinned to a commit SHA in the jsDelivr URL. jsDelivr serves
# immutable content per SHA, so the URL itself is the integrity check.
# TODO: bump SHA when oem-shared/lib changes.
$libBaseUrl = "https://cdn.jsdelivr.net/gh/dtc-inc/msp-script-library@5b1b16c4b19816343145138941c3c5fa51a095e8"
$libs = @(
    "$libBaseUrl/oem-shared/lib/oem-manufacturer-detect.ps1"
)
foreach ($url in $libs) {
    $libPath = Join-Path $env:TEMP ([System.IO.Path]::GetFileName($url))
    Invoke-WebRequest -Uri $url -OutFile $libPath -UseBasicParsing -ErrorAction Stop
    . $libPath
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
        $env:Description = "Lenovo Debloat"
    }
}

$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# --- Script logic --------------------------------------------------------

$TranscriptStarted = $false
try {
    Start-Transcript -Path $LogPath -ErrorAction Stop
    $TranscriptStarted = $true
} catch {
    Write-Host "Warning: Could not start transcript logging to $LogPath - $($_.Exception.Message)"
}

Write-Host "Description: $env:Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $env:RMM"

$manufacturer = Get-OEMManufacturer
if ($manufacturer -ne "Lenovo") {
    Write-Host "Not a Lenovo endpoint. Exiting."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
}

# Lenovo consumer software to remove. Lenovo System Update (the enterprise tool)
# and Commercial Vantage / ThinkShield / enterprise security agents are intentionally
# NOT in this list ... they are the vendor lifecycle and security tools the baseline
# preserves. Consumer Vantage IS removed; Commercial Vantage is kept.
$lenovoBloatPatterns = @(
    "Lenovo Vantage",
    "Lenovo Vantage Service",
    "Lenovo Smart Communication",
    "Lenovo Smart Privacy",
    "Lenovo Smart Appearance",
    "Lenovo Voice",
    "Lenovo Now",
    "Lenovo Welcome",
    "Lenovo Migration Assistant",
    "Lenovo Utility",
    "McAfee Personal Security",
    "McAfee LiveSafe",
    "McAfee WebAdvisor",
    "Norton 360"
)

# Patterns to exclude even if they match a bloat pattern (keep these installed).
$keepPatterns = @(
    "Lenovo System Update",
    "Lenovo Commercial Vantage",
    "Lenovo Patch",
    "Lenovo ThinkShield",
    "Lenovo Endpoint Security"
)

function Test-ShouldKeep {
    param([string] $Name)
    foreach ($keep in $keepPatterns) {
        if ($Name -match $keep) { return $true }
    }
    return $false
}

# Build the registry survey for both 64-bit and 32-bit uninstall hives.
$uninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

$removedCount = 0
$failedCount = 0

foreach ($pattern in $lenovoBloatPatterns) {
    $matched = foreach ($path in $uninstallPaths) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and ($_.DisplayName -match [regex]::Escape($pattern)) }
    }
    foreach ($app in $matched) {
        if (Test-ShouldKeep -Name $app.DisplayName) {
            Write-Host "Keeping: $($app.DisplayName)"
            continue
        }
        Write-Host "Removing: $($app.DisplayName) [$($app.DisplayVersion)]"
        $uninstallString = $app.UninstallString
        if ([string]::IsNullOrEmpty($uninstallString)) {
            Write-Host "  No uninstall string; skipping."
            continue
        }
        try {
            if ($uninstallString -match "msiexec") {
                if ($app.PSChildName -match "^\{[0-9A-Fa-f-]+\}$") {
                    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $($app.PSChildName) /qn /norestart" -Wait -PassThru -NoNewWindow
                    if ($proc.ExitCode -eq 0) { $removedCount++ } else { $failedCount++; Write-Host "  msiexec exit: $($proc.ExitCode)" }
                } else {
                    Write-Host "  Unknown product code shape: $($app.PSChildName)"
                    $failedCount++
                }
            } else {
                # Non-MSI uninstaller; append silent flags if possible.
                $cmd = $uninstallString
                if ($cmd -notmatch "/S" -and $cmd -notmatch "/silent" -and $cmd -notmatch "/quiet") {
                    $cmd = "$cmd /S"
                }
                $proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cmd" -Wait -PassThru -NoNewWindow
                if ($proc.ExitCode -eq 0) { $removedCount++ } else { $failedCount++; Write-Host "  uninstaller exit: $($proc.ExitCode)" }
            }
        } catch {
            Write-Host "  Removal threw: $_"
            $failedCount++
        }
    }
}

# Provisioned UWP / AppX consumer bundles ship preinstalled on Lenovo consumer SKUs.
# Publisher prefix E0469640.* is Lenovo consumer. LenovoCorporation.LenovoVantage is the
# Store-distributed consumer Vantage. Commercial Vantage publisher (LenovoCorporation.LenovoSettings)
# is NOT in this list.
$appxPatterns = @(
    "*E0469640.LenovoSmartCommunication*",
    "*E0469640.LenovoSmartAppearance*",
    "*E0469640.LenovoUtility*",
    "*E0469640.LenovoCompanion*",
    "*LenovoCorporation.LenovoVantage*"
)

foreach ($pattern in $appxPatterns) {
    $pkgs = Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue
    foreach ($pkg in $pkgs) {
        Write-Host "Removing AppX: $($pkg.Name)"
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            $removedCount++
        } catch {
            Write-Host "  Remove-AppxPackage failed: $_"
            $failedCount++
        }
    }
    $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like $pattern.Trim('*') -or $_.PackageName -like $pattern }
    foreach ($prov in $provisioned) {
        Write-Host "Removing provisioned AppX: $($prov.DisplayName)"
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
            $removedCount++
        } catch {
            Write-Host "  Remove-AppxProvisionedPackage failed: $_"
            $failedCount++
        }
    }
}

Write-Host "`nSummary: removed=$removedCount failed=$failedCount"

if ($TranscriptStarted) { Stop-Transcript }

if ($failedCount -gt 0) { exit 1 } else { exit 0 }
