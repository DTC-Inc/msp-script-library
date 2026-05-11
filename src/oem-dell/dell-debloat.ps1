## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                       - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description               - Ticket # or initials for audit trail
## $env:RMMScriptPath             - Optional log directory base provided by the RMM

# %INCLUDE src/oem-shared/lib/oem-manufacturer-detect.ps1

$ScriptLogName = "dell-debloat.log"

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
        $env:Description = "Dell Debloat"
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

if ((Get-OEMManufacturer) -ne "Dell") {
    Write-Host "Not a Dell endpoint. Exiting."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
}

# Dell consumer software to remove. Dell Command Update and Dell Command Configure
# are intentionally NOT in this list ... they are the vendor lifecycle tools the
# Dell configure / DCU scripts deploy.
$dellBloatPatterns = @(
    "SupportAssist",
    "Dell SupportAssist",
    "Dell Update",
    "Dell Mobile Connect",
    "Dell Digital Delivery",
    "Dell Customer Connect",
    "Dell Help & Support",
    "MyDell"
)

# Patterns to keep even when they match a bloat pattern by substring.
$keepPatterns = @(
    "Dell Command \| Update",
    "Dell Command Update",
    "Dell Command \| Configure",
    "Dell Command Configure"
)

function Test-ShouldKeep {
    param([string] $Name)
    foreach ($keep in $keepPatterns) {
        if ($Name -match $keep) { return $true }
    }
    return $false
}

# Survey both 64-bit and 32-bit uninstall hives.
$uninstallPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

$removedCount = 0
$failedCount = 0

foreach ($pattern in $dellBloatPatterns) {
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

# Provisioned UWP / AppX consumer bundles ship preinstalled on Dell consumer SKUs.
$appxPatterns = @(
    "*DellInc.DellMobileConnect*",
    "*DellInc.DellDigitalDelivery*",
    "*DellInc.MyDell*",
    "*DellInc.DellCustomerConnect*"
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
