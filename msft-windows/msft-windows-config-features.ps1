## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description    / $env:Description    - Ticket # or initials for audit trail
## $RMMScriptPath  / $env:RMMScriptPath  - Optional log directory base provided by the RMM
## $InstallNetFx3  / $env:InstallNetFx3  - Install .NET Framework 3.5 (default: $true)
## $InstallSandbox / $env:InstallSandbox - Install Windows Sandbox, Pro/Enterprise only (default: $true)
## $InstallHyperV  / $env:InstallHyperV  - Install Hyper-V, requires compatible hardware (default: $false)

# This script installs optional Windows features:
# - .NET Framework 3.5 (for legacy applications)
# - Windows Sandbox (for safe application testing)
# - Hyper-V (optional, for virtualization)
# Use Case: Deploy via RMM during initial workstation setup

#Requires -RunAsAdministrator

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description    = $env:Description,
    [string]$RMMScriptPath  = $env:RMMScriptPath,
    [string]$InstallNetFx3  = $env:InstallNetFx3,
    [string]$InstallSandbox = $env:InstallSandbox,
    [string]$InstallHyperV  = $env:InstallHyperV
)

$ScriptLogName = "msft-windows-config-features.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied.
if ([string]::IsNullOrEmpty($Description)) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "RMM-initiated Windows features installation"
}

# Default the feature toggles, then coerce the string inputs to booleans so the install
# blocks below (which test $InstallNetFx3 etc.) behave as they did originally.
if ([string]::IsNullOrEmpty($InstallNetFx3))  { $InstallNetFx3  = $true }  else { $InstallNetFx3  = [System.Convert]::ToBoolean($InstallNetFx3) }
if ([string]::IsNullOrEmpty($InstallSandbox)) { $InstallSandbox = $true }  else { $InstallSandbox = [System.Convert]::ToBoolean($InstallSandbox) }
if ([string]::IsNullOrEmpty($InstallHyperV))  { $InstallHyperV  = $false } else { $InstallHyperV  = [System.Convert]::ToBoolean($InstallHyperV) }

# Store logs under $RMMScriptPath if provided, otherwise the standard Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host ""

Write-Host "=== Windows Features Installation ===" -ForegroundColor Cyan
Write-Host "Features to install:" -ForegroundColor Yellow
Write-Host "  .NET Framework 3.5: $InstallNetFx3"
Write-Host "  Windows Sandbox: $InstallSandbox"
Write-Host "  Hyper-V: $InstallHyperV"
Write-Host ""

# Check Windows edition
$osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
$isProOrHigher = $osInfo.Caption -match "Pro|Enterprise|Education"
Write-Host "Windows Edition: $($osInfo.Caption)" -ForegroundColor Gray

$restartRequired = $false

# Install .NET Framework 3.5
if ($InstallNetFx3) {
    Write-Host "Installing .NET Framework 3.5..." -ForegroundColor Yellow

    try {
        $netfx3 = Get-WindowsOptionalFeature -Online -FeatureName "NetFx3" -ErrorAction SilentlyContinue

        if ($netfx3.State -eq "Enabled") {
            Write-Host ".NET Framework 3.5 already installed" -ForegroundColor Green
        } else {
            $result = Enable-WindowsOptionalFeature -Online -FeatureName "NetFx3" -All -NoRestart -ErrorAction Stop
            if ($result.RestartNeeded) {
                $restartRequired = $true
            }
            Write-Host ".NET Framework 3.5 installed" -ForegroundColor Green
        }
    } catch {
        Write-Host "Failed to install .NET Framework 3.5: $_" -ForegroundColor Yellow
        Write-Host "This may require Windows installation media or internet access" -ForegroundColor Gray
    }
}

# Install Windows Sandbox
if ($InstallSandbox) {
    Write-Host "Installing Windows Sandbox..." -ForegroundColor Yellow

    if (!$isProOrHigher) {
        Write-Host "Windows Sandbox requires Pro, Enterprise, or Education edition" -ForegroundColor Yellow
        Write-Host "Current edition does not support Windows Sandbox" -ForegroundColor Gray
    } else {
        try {
            $sandbox = Get-WindowsOptionalFeature -Online -FeatureName "Containers-DisposableClientVM" -ErrorAction SilentlyContinue

            if ($sandbox.State -eq "Enabled") {
                Write-Host "Windows Sandbox already installed" -ForegroundColor Green
            } else {
                # Check if virtualization is supported
                $vmSupport = Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object -ExpandProperty HypervisorPresent

                $result = Enable-WindowsOptionalFeature -Online -FeatureName "Containers-DisposableClientVM" -All -NoRestart -ErrorAction Stop
                if ($result.RestartNeeded) {
                    $restartRequired = $true
                }
                Write-Host "Windows Sandbox installed" -ForegroundColor Green
            }
        } catch {
            Write-Host "Failed to install Windows Sandbox: $_" -ForegroundColor Yellow
            Write-Host "Virtualization must be enabled in BIOS/UEFI" -ForegroundColor Gray
        }
    }
}

# Install Hyper-V
if ($InstallHyperV) {
    Write-Host "Installing Hyper-V..." -ForegroundColor Yellow

    if (!$isProOrHigher) {
        Write-Host "Hyper-V requires Pro, Enterprise, or Education edition" -ForegroundColor Yellow
        Write-Host "Current edition does not support Hyper-V" -ForegroundColor Gray
    } else {
        try {
            $hyperv = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Hyper-V" -ErrorAction SilentlyContinue

            if ($hyperv.State -eq "Enabled") {
                Write-Host "Hyper-V already installed" -ForegroundColor Green
            } else {
                $result = Enable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Hyper-V" -All -NoRestart -ErrorAction Stop
                if ($result.RestartNeeded) {
                    $restartRequired = $true
                }
                Write-Host "Hyper-V installed" -ForegroundColor Green
            }
        } catch {
            Write-Host "Failed to install Hyper-V: $_" -ForegroundColor Yellow
            Write-Host "Virtualization must be enabled in BIOS/UEFI" -ForegroundColor Gray
        }
    }
}

Write-Host ""
Write-Host "=== Feature Installation Summary ===" -ForegroundColor Cyan

# List currently enabled features we care about
$features = @(
    @{Name = "NetFx3"; Display = ".NET Framework 3.5"},
    @{Name = "Containers-DisposableClientVM"; Display = "Windows Sandbox"},
    @{Name = "Microsoft-Hyper-V"; Display = "Hyper-V"}
)

foreach ($feature in $features) {
    $status = Get-WindowsOptionalFeature -Online -FeatureName $feature.Name -ErrorAction SilentlyContinue
    if ($status) {
        $stateColor = if ($status.State -eq "Enabled") { "Green" } else { "Gray" }
        Write-Host "  $($feature.Display): $($status.State)" -ForegroundColor $stateColor
    }
}

if ($restartRequired) {
    Write-Host ""
    Write-Host "RESTART REQUIRED to complete feature installation" -ForegroundColor Yellow
}

Write-Host "=====================================" -ForegroundColor Cyan

Stop-Transcript
