#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys Schick 33/Elite USB Interface Driver with automatic Eaglesoft version detection.

.DESCRIPTION
    Production deployment script for Schick sensor drivers that:
    - Detects Eaglesoft version to determine IOSS (24.20+) vs Legacy install path
    - Downloads required installers from Backblaze B2 bucket
    - Performs silent installations of CDR Elite, CDR Patch, AE USB driver, and IOSS
    - Configures services with proper startup type and recovery options
    - Validates installation and outputs JSON for HALO ticket integration

.PARAMETER InstallMode
    Force a specific installation mode. Valid values: 'Auto', 'Legacy', 'IOSS'
    Default: Auto (detects based on Eaglesoft version)

.PARAMETER SkipPrerequisites
    Skip prerequisite checks (MSXML, Core Isolation, etc.)

.PARAMETER DownloadOnly
    Only download installers without running installation

.PARAMETER OutputPath
    Path for JSON output file. Default: $env:TEMP\SchickDeploy-Results.json

.EXAMPLE
    .\Deploy-SchickSensor.ps1
    Auto-detect Eaglesoft version and install appropriate drivers

.EXAMPLE
    .\Deploy-SchickSensor.ps1 -InstallMode IOSS
    Force IOSS installation path regardless of detected Eaglesoft version

.EXAMPLE
    .\Deploy-SchickSensor.ps1 -DownloadOnly
    Only download installers for manual installation

.NOTES
    Version:        1.0.0
    Author:         Automated Deployment Script
    Requirements:   PowerShell 5.1+, Administrator rights, Internet connectivity

    File Manifest for CDR Elite 5.16:
    - C:\Program Files (x86)\Schick Technologies\Shared Files\CDRData.dll
    - C:\Program Files (x86)\Schick Technologies\Shared Files\OMEGADLL.dll
    - C:\Program Files (x86)\Schick Technologies\Shared Files\CDRImageProcess.dll
#>

[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Legacy', 'IOSS')]
    [string]$InstallMode = 'Auto',

    [switch]$SkipPrerequisites,

    [switch]$DownloadOnly,

    [string]$OutputPath = "$env:TEMP\SchickDeploy-Results.json"
)

#region Configuration
# ============================================================================
# DOWNLOAD URLS - Backblaze B2 + Microsoft
# ============================================================================
$Script:Config = @{
    # Full download URLs (different subfolders require full paths)
    Downloads = @{
        CDRElite      = @{
            Url      = "https://s3.us-west-002.backblazeb2.com/public-dtc/repo/vendors/Patterson-Eaglesoft/CDRElite5_16/CDRElite/CDR%20Elite%20Setup.exe"
            FileName = "CDR Elite Setup.exe"
        }
        CDRPatch      = @{
            Url      = "https://s3.us-west-002.backblazeb2.com/public-dtc/repo/vendors/Patterson-Eaglesoft/CDRElite5_16/CDRElite/Patch/CDRPatch-2808.msi"
            FileName = "CDRPatch-2808.msi"
        }
        AEUSBDriver   = @{
            Url      = "https://s3.us-west-002.backblazeb2.com/public-dtc/repo/vendors/Patterson-Eaglesoft/AEUSBInterfaceSetup.exe"
            FileName = "AEUSBInterfaceSetup.exe"
        }
        AEUSBFirmware = @{
            Url      = "https://s3.us-west-002.backblazeb2.com/public-dtc/repo/vendors/Patterson-Eaglesoft/AE_USB_Firmware_Upgrade%5B1%5D.exe"
            FileName = "AE_USB_Firmware_Upgrade.exe"
        }
        IOSS          = @{
            Url      = "https://s3.us-west-002.backblazeb2.com/public-dtc/repo/vendors/Patterson-Eaglesoft/IOSS_v3.2/IOSS_v3.2/Autorun.exe"
            FileName = "IOSS_Autorun.exe"
        }
        MSXML4        = @{
            Url      = "https://download.microsoft.com/download/1/E/E/1EE06E22-A56F-4E76-B6F6-E7670B4F8163/msxml4-KB2758694-enu.exe"
            FileName = "msxml4-KB2758694-enu.exe"
        }
    }

    # Installation paths
    Paths = @{
        SharedFiles   = "C:\Program Files (x86)\Schick Technologies\Shared Files"
        SchickBase    = "C:\Program Files (x86)\Schick Technologies"
        TempDownload  = "$env:TEMP\SchickInstall"
    }

    # Protected DLLs - DO NOT DELETE during IOSS cleanup
    ProtectedDLLs = @(
        "CDRData.dll",
        "OMEGADLL.dll"
    )

    # Eaglesoft version threshold for IOSS
    IOSSMinVersion = [Version]"24.20"
}

#endregion

#region Logging Functions
# ============================================================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'White' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
    }

    $prefix = switch ($Level) {
        'Info'    { "[*]" }
        'Warning' { "[!]" }
        'Error'   { "[X]" }
        'Success' { "[+]" }
    }

    Write-Host "$timestamp $prefix $Message" -ForegroundColor $color

    # Add to results log
    $Script:Results.Log += @{
        Timestamp = $timestamp
        Level     = $Level
        Message   = $Message
    }
}

#endregion

#region Detection Functions
# ============================================================================
function Get-EaglesoftVersion {
    <#
    .SYNOPSIS
        Detects installed Eaglesoft version from registry
    #>

    $registryPaths = @(
        "HKLM:\SOFTWARE\Patterson Dental\Eaglesoft",
        "HKLM:\SOFTWARE\WOW6432Node\Patterson Dental\Eaglesoft",
        "HKLM:\SOFTWARE\Patterson\Eaglesoft"
    )

    foreach ($path in $registryPaths) {
        if (Test-Path $path) {
            try {
                $version = Get-ItemProperty -Path $path -Name "Version" -ErrorAction SilentlyContinue
                if ($version.Version) {
                    Write-Log "Found Eaglesoft version $($version.Version) at $path" -Level Info
                    return [Version]$version.Version
                }

                # Try alternate property names
                $displayVersion = Get-ItemProperty -Path $path -Name "DisplayVersion" -ErrorAction SilentlyContinue
                if ($displayVersion.DisplayVersion) {
                    Write-Log "Found Eaglesoft DisplayVersion $($displayVersion.DisplayVersion) at $path" -Level Info
                    return [Version]$displayVersion.DisplayVersion
                }
            }
            catch {
                Write-Log "Error reading registry at $path`: $_" -Level Warning
            }
        }
    }

    # Fallback: Check installed programs
    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    foreach ($path in $uninstallPaths) {
        $eaglesoft = Get-ItemProperty $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*Eaglesoft*" } |
            Select-Object -First 1

        if ($eaglesoft -and $eaglesoft.DisplayVersion) {
            Write-Log "Found Eaglesoft via uninstall registry: $($eaglesoft.DisplayVersion)" -Level Info
            try {
                return [Version]$eaglesoft.DisplayVersion
            }
            catch {
                # Version string might have extra characters
                $cleanVersion = $eaglesoft.DisplayVersion -replace '[^0-9.]', ''
                return [Version]$cleanVersion
            }
        }
    }

    Write-Log "Eaglesoft not detected on this system" -Level Warning
    return $null
}

function Get-CurrentInstallState {
    <#
    .SYNOPSIS
        Checks current installation state of Schick components
    #>

    $state = @{
        SharedFilesExists    = Test-Path $Script:Config.Paths.SharedFiles
        CDRDataDLL           = $false
        OMEGADLL             = $false
        CDRImageProcessDLL   = $false
        IOSSServiceExists    = $false
        IOSSServiceRunning   = $false
        AEUSBDriverInstalled = $false
        MSXML4Installed      = $false
        CoreIsolationEnabled = $false
        RDPSession           = $false
    }

    # Check DLLs
    if ($state.SharedFilesExists) {
        $state.CDRDataDLL = Test-Path (Join-Path $Script:Config.Paths.SharedFiles "CDRData.dll")
        $state.OMEGADLL = Test-Path (Join-Path $Script:Config.Paths.SharedFiles "OMEGADLL.dll")
        $state.CDRImageProcessDLL = Test-Path (Join-Path $Script:Config.Paths.SharedFiles "CDRImageProcess.dll")
    }

    # Check IOSS Service
    $iossService = Get-Service -Name "IOSS*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($iossService) {
        $state.IOSSServiceExists = $true
        $state.IOSSServiceRunning = $iossService.Status -eq 'Running'
    }

    # Check AE USB Driver
    $aeDriver = Get-WmiObject Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceName -like "*AE*USB*" -or $_.Description -like "*Schick*" }
    $state.AEUSBDriverInstalled = $null -ne $aeDriver

    # Check MSXML 4.0
    $msxml = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*MSXML 4*" }
    $state.MSXML4Installed = $null -ne $msxml

    # Check Core Isolation (Memory Integrity)
    try {
        $hvci = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -ErrorAction SilentlyContinue
        $state.CoreIsolationEnabled = $hvci.Enabled -eq 1
    }
    catch {
        $state.CoreIsolationEnabled = $false
    }

    # Check RDP Session
    $state.RDPSession = $env:SESSIONNAME -like "RDP*"

    return $state
}

function Resolve-InstallMode {
    param([Version]$EaglesoftVersion)

    if ($InstallMode -ne 'Auto') {
        Write-Log "Install mode forced to: $InstallMode" -Level Info
        return $InstallMode
    }

    if ($null -eq $EaglesoftVersion) {
        Write-Log "No Eaglesoft detected - defaulting to Legacy mode" -Level Warning
        return 'Legacy'
    }

    if ($EaglesoftVersion -ge $Script:Config.IOSSMinVersion) {
        Write-Log "Eaglesoft $EaglesoftVersion >= $($Script:Config.IOSSMinVersion) - selecting IOSS mode" -Level Info
        return 'IOSS'
    }
    else {
        Write-Log "Eaglesoft $EaglesoftVersion < $($Script:Config.IOSSMinVersion) - selecting Legacy mode" -Level Info
        return 'Legacy'
    }
}

#endregion

#region Prerequisite Functions
# ============================================================================
function Test-Prerequisites {
    <#
    .SYNOPSIS
        Validates system prerequisites before installation
    #>

    $passed = $true
    $checks = @()

    # Check PowerShell version
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        $checks += @{ Name = "PowerShell 5.1+"; Status = "FAIL"; Message = "PowerShell $($PSVersionTable.PSVersion) detected" }
        $passed = $false
    }
    else {
        $checks += @{ Name = "PowerShell 5.1+"; Status = "PASS"; Message = "PowerShell $($PSVersionTable.PSVersion)" }
    }

    # Check Administrator
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        $checks += @{ Name = "Administrator"; Status = "FAIL"; Message = "Script must run as Administrator" }
        $passed = $false
    }
    else {
        $checks += @{ Name = "Administrator"; Status = "PASS"; Message = "Running elevated" }
    }

    # Check TLS 1.2
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $checks += @{ Name = "TLS 1.2"; Status = "PASS"; Message = "Enabled" }
    }
    catch {
        $checks += @{ Name = "TLS 1.2"; Status = "FAIL"; Message = "Could not enable TLS 1.2" }
        $passed = $false
    }

    # Check Internet connectivity
    try {
        $null = Invoke-WebRequest -Uri "https://www.google.com" -UseBasicParsing -TimeoutSec 10
        $checks += @{ Name = "Internet"; Status = "PASS"; Message = "Connected" }
    }
    catch {
        $checks += @{ Name = "Internet"; Status = "FAIL"; Message = "No internet connectivity" }
        $passed = $false
    }

    # Check Core Isolation
    if ($Script:CurrentState.CoreIsolationEnabled) {
        $checks += @{ Name = "Core Isolation"; Status = "WARN"; Message = "Memory Integrity enabled - may cause driver issues" }
        Write-Log "WARNING: Core Isolation (Memory Integrity) is enabled. This may prevent USB drivers from loading." -Level Warning
    }
    else {
        $checks += @{ Name = "Core Isolation"; Status = "PASS"; Message = "Memory Integrity disabled" }
    }

    # Check RDP session
    if ($Script:CurrentState.RDPSession) {
        $checks += @{ Name = "RDP Session"; Status = "WARN"; Message = "Running via RDP - USB devices may not be visible" }
        Write-Log "WARNING: Running via RDP. USB sensor may not be accessible during installation." -Level Warning
    }
    else {
        $checks += @{ Name = "RDP Session"; Status = "PASS"; Message = "Local session" }
    }

    # Output check results
    Write-Host "`n=== Prerequisite Checks ===" -ForegroundColor Cyan
    foreach ($check in $checks) {
        $color = switch ($check.Status) {
            'PASS' { 'Green' }
            'WARN' { 'Yellow' }
            'FAIL' { 'Red' }
        }
        Write-Host "  [$($check.Status)] $($check.Name): $($check.Message)" -ForegroundColor $color
    }
    Write-Host ""

    $Script:Results.Prerequisites = $checks
    return $passed
}

#endregion

#region Download Functions
# ============================================================================
function Initialize-DownloadDirectory {
    if (-not (Test-Path $Script:Config.Paths.TempDownload)) {
        New-Item -ItemType Directory -Path $Script:Config.Paths.TempDownload -Force | Out-Null
        Write-Log "Created temp download directory: $($Script:Config.Paths.TempDownload)" -Level Info
    }
}

function Get-Installer {
    param(
        [string]$Name
    )

    $installerConfig = $Script:Config.Downloads[$Name]
    if (-not $installerConfig) {
        Write-Log "Unknown installer: $Name" -Level Error
        return $null
    }

    $url = $installerConfig.Url
    $fileName = $installerConfig.FileName
    $destination = Join-Path $Script:Config.Paths.TempDownload $fileName

    # Skip if already downloaded
    if (Test-Path $destination) {
        $fileSize = (Get-Item $destination).Length
        if ($fileSize -gt 0) {
            Write-Log "$Name already downloaded ($([math]::Round($fileSize/1MB, 2)) MB)" -Level Info
            return $destination
        }
    }

    Write-Log "Downloading $Name from $url" -Level Info

    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $destination -UseBasicParsing -TimeoutSec 300

        $fileSize = (Get-Item $destination).Length
        Write-Log "Downloaded $Name successfully ($([math]::Round($fileSize/1MB, 2)) MB)" -Level Success
        return $destination
    }
    catch {
        Write-Log "Failed to download $Name`: $_" -Level Error
        return $null
    }
}

function Get-RequiredInstallers {
    param([string]$Mode)

    Initialize-DownloadDirectory

    $downloads = @{}
    $requiredInstallers = @()

    # MSXML 4.0 - required for all installations
    if (-not $Script:CurrentState.MSXML4Installed) {
        $requiredInstallers += "MSXML4"
    }

    # Mode-specific installers
    switch ($Mode) {
        'Legacy' {
            $requiredInstallers += "CDRElite"
            $requiredInstallers += "CDRPatch"      # Creates correct CDRImageProcess.dll v5.15.1877
            $requiredInstallers += "AEUSBDriver"
        }
        'IOSS' {
            $requiredInstallers += "CDRElite"
            $requiredInstallers += "CDRPatch"
            $requiredInstallers += "IOSS"
        }
    }

    Write-Host "`n=== Downloading Installers ===" -ForegroundColor Cyan

    foreach ($installerName in $requiredInstallers) {
        $path = Get-Installer -Name $installerName
        if ($path) {
            $downloads[$installerName] = $path
        }
        else {
            Write-Log "Missing required installer: $installerName" -Level Error
            return $null
        }
    }

    return $downloads
}

#endregion

#region Installation Functions
# ============================================================================
function Install-MSXML4 {
    param([string]$InstallerPath)

    Write-Log "Installing MSXML 4.0 SP3 Security Update..." -Level Info

    # Microsoft KB2758694 is a self-extracting exe, use /q for silent
    $arguments = "/q /norestart"
    $process = Start-Process -FilePath $InstallerPath -ArgumentList $arguments -Wait -PassThru -NoNewWindow

    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
        Write-Log "MSXML 4.0 installed successfully" -Level Success
        return $true
    }
    else {
        Write-Log "MSXML 4.0 installation failed with exit code: $($process.ExitCode)" -Level Error
        return $false
    }
}

function Install-CDRElite {
    param([string]$InstallerPath)

    Write-Log "Installing CDR Elite 5.16..." -Level Info

    # InstallShield silent install parameters
    # Note: May need .iss response file if this prompts - test on lab machine
    $arguments = "/s /v`"/qn REBOOT=ReallySuppress`""

    $process = Start-Process -FilePath $InstallerPath -ArgumentList $arguments -Wait -PassThru -NoNewWindow

    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
        Write-Log "CDR Elite installed successfully" -Level Success

        # Verify DLLs were created
        Start-Sleep -Seconds 2
        $dllsExist = (Test-Path (Join-Path $Script:Config.Paths.SharedFiles "CDRData.dll")) -and
                     (Test-Path (Join-Path $Script:Config.Paths.SharedFiles "OMEGADLL.dll"))

        if ($dllsExist) {
            Write-Log "Verified CDRData.dll and OMEGADLL.dll in Shared Files" -Level Success
        }
        else {
            Write-Log "Warning: Expected DLLs not found in Shared Files folder" -Level Warning
        }

        return $true
    }
    else {
        Write-Log "CDR Elite installation failed with exit code: $($process.ExitCode)" -Level Error
        return $false
    }
}

function Stop-AutoDetectServer {
    <#
    .SYNOPSIS
        Stops AutoDetectServer.exe if running (required before installation per Patterson docs)
    #>

    Write-Log "Checking for AutoDetectServer.exe..." -Level Info

    $process = Get-Process -Name "AutoDetectServer" -ErrorAction SilentlyContinue
    if ($process) {
        Write-Log "  Stopping AutoDetectServer.exe..." -Level Info
        try {
            $process | Stop-Process -Force
            Start-Sleep -Seconds 2
            Write-Log "  AutoDetectServer.exe stopped" -Level Success
        }
        catch {
            Write-Log "  Failed to stop AutoDetectServer.exe: $_" -Level Warning
        }
    }
    else {
        Write-Log "  AutoDetectServer.exe not running" -Level Info
    }
}

function Uninstall-LegacyComponents {
    <#
    .SYNOPSIS
        Uninstalls legacy CDR/Schick components before IOSS installation
        Per Patterson documentation, these must be removed:
        - CDR Patch-2808
        - CDR Intra-Oral TWAIN Data Source
        - CDR Elite USB Driver
        - CDR USB Remote HS Driver
        - Schick AE USB Support for CDR
    #>

    Write-Log "Checking for legacy components to uninstall..." -Level Info

    $legacyProducts = @(
        "*CDR Patch*",
        "*CDR Intra-Oral*",
        "*CDR Elite*",
        "*CDR USB*",
        "*Schick AE USB*",
        "*CDR TWAIN*"
    )

    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $foundProducts = @()

    foreach ($path in $uninstallPaths) {
        foreach ($pattern in $legacyProducts) {
            $products = Get-ItemProperty $path -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like $pattern }
            if ($products) {
                $foundProducts += $products
            }
        }
    }

    if ($foundProducts.Count -eq 0) {
        Write-Log "  No legacy components found" -Level Info
        return $true
    }

    Write-Log "  Found $($foundProducts.Count) legacy component(s) to uninstall:" -Level Info

    foreach ($product in $foundProducts) {
        Write-Log "    - $($product.DisplayName)" -Level Info

        try {
            $uninstallString = $product.UninstallString
            if ($uninstallString -match "msiexec") {
                # MSI uninstall
                $productCode = $product.PSChildName
                $arguments = "/x $productCode /qn /norestart"
                Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -NoNewWindow
                Write-Log "      Uninstalled via MSI" -Level Success
            }
            elseif ($uninstallString) {
                # EXE uninstall - try silent
                $uninstallString = $uninstallString -replace '"', ''
                Start-Process -FilePath $uninstallString -ArgumentList "/S /SILENT /VERYSILENT /NORESTART" -Wait -NoNewWindow -ErrorAction SilentlyContinue
                Write-Log "      Uninstall attempted" -Level Info
            }
        }
        catch {
            Write-Log "      Failed to uninstall: $_" -Level Warning
        }
    }

    return $true
}

function Rename-CDRImageProcessDLL {
    <#
    .SYNOPSIS
        Renames CDRImageProcess.dll to CDRImageProcess.dllOLD before patching
        Per Patterson documentation for Legacy installation path
    #>

    $dllPath = Join-Path $Script:Config.Paths.SharedFiles "CDRImageProcess.dll"
    $oldPath = Join-Path $Script:Config.Paths.SharedFiles "CDRImageProcess.dllOLD"

    if (Test-Path $dllPath) {
        Write-Log "Renaming CDRImageProcess.dll to CDRImageProcess.dllOLD..." -Level Info
        try {
            # Remove old backup if exists
            if (Test-Path $oldPath) {
                Remove-Item -Path $oldPath -Force
            }
            Rename-Item -Path $dllPath -NewName "CDRImageProcess.dllOLD" -Force
            Write-Log "  Renamed successfully" -Level Success
            return $true
        }
        catch {
            Write-Log "  Failed to rename: $_" -Level Error
            return $false
        }
    }
    else {
        Write-Log "CDRImageProcess.dll not found - skipping rename" -Level Info
        return $true
    }
}

function Clear-SharedFilesForIOSS {
    <#
    .SYNOPSIS
        Cleans Shared Files folder for IOSS installation
        PRESERVES CDRData.dll and OMEGADLL.dll
        DELETES everything else including CDRImageProcess.dll
    #>

    Write-Log "Preparing Shared Files folder for IOSS installation..." -Level Info

    $sharedPath = $Script:Config.Paths.SharedFiles

    if (-not (Test-Path $sharedPath)) {
        Write-Log "Shared Files folder does not exist - skipping cleanup" -Level Warning
        return $true
    }

    $files = Get-ChildItem -Path $sharedPath -File -ErrorAction SilentlyContinue
    $deletedCount = 0
    $preservedCount = 0

    foreach ($file in $files) {
        if ($Script:Config.ProtectedDLLs -contains $file.Name) {
            Write-Log "  PRESERVING: $($file.Name)" -Level Info
            $preservedCount++
        }
        else {
            try {
                Remove-Item -Path $file.FullName -Force
                Write-Log "  DELETED: $($file.Name)" -Level Info
                $deletedCount++
            }
            catch {
                Write-Log "  FAILED TO DELETE: $($file.Name) - $_" -Level Error
                return $false
            }
        }
    }

    Write-Log "Cleanup complete: Preserved $preservedCount files, Deleted $deletedCount files" -Level Success
    return $true
}

function Install-CDRPatch {
    param([string]$InstallerPath)

    Write-Log "Installing CDR Patch 2808..." -Level Info

    $arguments = "/i `"$InstallerPath`" /qn /norestart"
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow

    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
        Write-Log "CDR Patch installed successfully" -Level Success

        # Verify CDRImageProcess.dll was created
        Start-Sleep -Seconds 2
        if (Test-Path (Join-Path $Script:Config.Paths.SharedFiles "CDRImageProcess.dll")) {
            Write-Log "Verified CDRImageProcess.dll created by patch" -Level Success
        }
        else {
            Write-Log "Warning: CDRImageProcess.dll not found after patch" -Level Warning
        }

        return $true
    }
    else {
        Write-Log "CDR Patch installation failed with exit code: $($process.ExitCode)" -Level Error
        return $false
    }
}

function Install-AEUSBDriver {
    param([string]$InstallerPath)

    Write-Log "Installing AE USB Interface driver..." -Level Info

    # Try NSIS-style silent install first
    $arguments = "/S"

    $process = Start-Process -FilePath $InstallerPath -ArgumentList $arguments -Wait -PassThru -NoNewWindow

    if ($process.ExitCode -eq 0) {
        Write-Log "AE USB driver installed successfully" -Level Success
        return $true
    }
    else {
        Write-Log "AE USB driver installation returned exit code: $($process.ExitCode)" -Level Warning
        # Some driver installers return non-zero even on success
        return $true
    }
}

function Install-IOSS {
    param([string]$InstallerPath)

    Write-Log "Installing IOSS Imaging Service..." -Level Info

    # Try InstallShield silent parameters
    $arguments = "/s /v`"/qn REBOOT=ReallySuppress`""

    $process = Start-Process -FilePath $InstallerPath -ArgumentList $arguments -Wait -PassThru -NoNewWindow

    if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
        Write-Log "IOSS installed successfully" -Level Success
        return $true
    }
    else {
        Write-Log "IOSS installation returned exit code: $($process.ExitCode)" -Level Warning
        # Continue anyway - service configuration will verify
        return $true
    }
}

function Set-IOSSServiceConfiguration {
    <#
    .SYNOPSIS
        Configures IOSS service with proper settings
    #>

    Write-Log "Configuring IOSS service..." -Level Info

    $iossService = Get-Service -Name "IOSS*" -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $iossService) {
        Write-Log "IOSS service not found - configuration skipped" -Level Error
        return $false
    }

    $serviceName = $iossService.Name

    try {
        # Set delayed auto-start
        & sc.exe config $serviceName start= delayed-auto | Out-Null
        Write-Log "  Set startup type: Delayed Auto-Start" -Level Info

        # Set recovery options: restart on first, second, and subsequent failures
        & sc.exe failure $serviceName reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
        Write-Log "  Set recovery options: Restart on failure (60s delay)" -Level Info

        # Ensure running as Local System
        & sc.exe config $serviceName obj= "LocalSystem" | Out-Null
        Write-Log "  Set logon account: Local System" -Level Info

        # Start the service
        if ($iossService.Status -ne 'Running') {
            Start-Service -Name $serviceName -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3

            $iossService = Get-Service -Name $serviceName
            if ($iossService.Status -eq 'Running') {
                Write-Log "  Service started successfully" -Level Success
            }
            else {
                Write-Log "  Service not running - Status: $($iossService.Status)" -Level Warning
            }
        }
        else {
            Write-Log "  Service already running" -Level Info
        }

        return $true
    }
    catch {
        Write-Log "Error configuring IOSS service: $_" -Level Error
        return $false
    }
}

function Reset-USBSensor {
    <#
    .SYNOPSIS
        Programmatically "replugs" the Schick USB sensor by disabling and re-enabling the device.
        This eliminates the need to physically unplug and replug the sensor.
    #>

    Write-Log "Resetting USB sensor (simulating unplug/replug)..." -Level Info

    # Search patterns for Schick/AE USB devices
    $devicePatterns = @(
        "*Schick*",
        "*CDR*",
        "*AE*USB*",
        "*Dental*Sensor*",
        "*FTDI*"  # Common USB-serial chip used in dental sensors
    )

    $foundDevices = @()

    # Find matching USB devices
    foreach ($pattern in $devicePatterns) {
        $devices = Get-PnpDevice -FriendlyName $pattern -ErrorAction SilentlyContinue |
            Where-Object { $_.Class -in @('USB', 'Image', 'Ports', 'HIDClass') }

        if ($devices) {
            $foundDevices += $devices
        }
    }

    # Also search by hardware ID patterns
    $usbDevices = Get-PnpDevice -Class 'USB', 'Image', 'Ports' -ErrorAction SilentlyContinue
    foreach ($device in $usbDevices) {
        $hwIds = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction SilentlyContinue).Data
        if ($hwIds -match 'VID_0403|VID_20D6|Schick|CDR') {
            if ($device -notin $foundDevices) {
                $foundDevices += $device
            }
        }
    }

    if ($foundDevices.Count -eq 0) {
        Write-Log "No Schick/AE USB devices found to reset" -Level Warning
        Write-Log "  Note: Device may need physical replug, or sensor not connected" -Level Warning
        return $false
    }

    # Remove duplicates
    $foundDevices = $foundDevices | Select-Object -Unique

    Write-Log "Found $($foundDevices.Count) USB device(s) to reset:" -Level Info

    $resetSuccess = $true
    foreach ($device in $foundDevices) {
        Write-Log "  Resetting: $($device.FriendlyName) [$($device.InstanceId)]" -Level Info

        try {
            # Disable the device
            Write-Log "    Disabling device..." -Level Info
            Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction Stop

            # Wait for device to fully disable
            Start-Sleep -Seconds 2

            # Re-enable the device
            Write-Log "    Re-enabling device..." -Level Info
            Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction Stop

            # Wait for device to initialize
            Start-Sleep -Seconds 3

            # Verify device is back online
            $deviceStatus = Get-PnpDevice -InstanceId $device.InstanceId -ErrorAction SilentlyContinue
            if ($deviceStatus.Status -eq 'OK') {
                Write-Log "    Device reset successfully - Status: OK" -Level Success
            }
            else {
                Write-Log "    Device status after reset: $($deviceStatus.Status)" -Level Warning
            }
        }
        catch {
            Write-Log "    Failed to reset device: $_" -Level Error
            $resetSuccess = $false

            # Try to re-enable if disable succeeded but enable failed
            try {
                Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
            }
            catch { }
        }
    }

    if ($resetSuccess) {
        Write-Log "USB sensor reset completed successfully" -Level Success
    }
    else {
        Write-Log "USB sensor reset completed with errors - manual replug may be required" -Level Warning
    }

    return $resetSuccess
}

function Reset-USBSensorFallback {
    <#
    .SYNOPSIS
        Fallback method using pnputil/devcon if Disable-PnpDevice is not available
    #>

    Write-Log "Attempting USB reset via pnputil..." -Level Info

    # Scan for hardware changes (forces re-enumeration)
    $result = & pnputil.exe /scan-devices 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Log "USB device scan completed - devices re-enumerated" -Level Success
        return $true
    }
    else {
        Write-Log "pnputil scan failed: $result" -Level Warning
        return $false
    }
}

function Disable-USBSensorForInstall {
    <#
    .SYNOPSIS
        Disables Schick USB sensor before installation (mimics "disconnect")
        Per Patterson docs: "Close Eaglesoft and disconnect all Schick equipment"
        Stores device IDs in script variable for later re-enablement
    #>

    Write-Log "Checking for connected USB sensors to disable during installation..." -Level Info

    # Search patterns for Schick/AE USB devices
    $devicePatterns = @(
        "*Schick*",
        "*CDR*",
        "*AE*USB*",
        "*Dental*Sensor*",
        "*FTDI*"
    )

    $Script:DisabledDevices = @()

    # Find matching USB devices
    foreach ($pattern in $devicePatterns) {
        $devices = Get-PnpDevice -FriendlyName $pattern -ErrorAction SilentlyContinue |
            Where-Object { $_.Class -in @('USB', 'Image', 'Ports', 'HIDClass') -and $_.Status -eq 'OK' }

        if ($devices) {
            $Script:DisabledDevices += $devices
        }
    }

    # Also search by hardware ID patterns
    $usbDevices = Get-PnpDevice -Class 'USB', 'Image', 'Ports' -Status 'OK' -ErrorAction SilentlyContinue
    foreach ($device in $usbDevices) {
        $hwIds = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction SilentlyContinue).Data
        if ($hwIds -match 'VID_0403|VID_20D6|Schick|CDR') {
            if ($device.InstanceId -notin $Script:DisabledDevices.InstanceId) {
                $Script:DisabledDevices += $device
            }
        }
    }

    if ($Script:DisabledDevices.Count -eq 0) {
        Write-Log "  No active USB sensors detected - proceeding with installation" -Level Info
        return $true
    }

    # Remove duplicates
    $Script:DisabledDevices = $Script:DisabledDevices | Select-Object -Unique

    Write-Log "  Found $($Script:DisabledDevices.Count) USB sensor(s) to disable:" -Level Info

    foreach ($device in $Script:DisabledDevices) {
        Write-Log "    - $($device.FriendlyName)" -Level Info

        try {
            Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction Stop
            Write-Log "      DISABLED (will re-enable after installation)" -Level Success
        }
        catch {
            Write-Log "      Failed to disable: $_" -Level Warning
            Write-Log "      You may need to physically unplug the sensor" -Level Warning
        }
    }

    # Brief pause for devices to fully disable
    Start-Sleep -Seconds 2

    return $true
}

function Enable-USBSensorAfterInstall {
    <#
    .SYNOPSIS
        Re-enables USB sensors that were disabled before installation (mimics "reconnect")
    #>

    if (-not $Script:DisabledDevices -or $Script:DisabledDevices.Count -eq 0) {
        Write-Log "No devices to re-enable (none were disabled)" -Level Info
        # Still run a device scan in case sensor was connected during install
        Reset-USBSensorFallback | Out-Null
        return $true
    }

    Write-Log "Re-enabling USB sensors after installation..." -Level Info

    $enableSuccess = $true

    foreach ($device in $Script:DisabledDevices) {
        Write-Log "  Re-enabling: $($device.FriendlyName)" -Level Info

        try {
            Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction Stop

            # Wait for device to initialize
            Start-Sleep -Seconds 2

            # Verify status
            $currentDevice = Get-PnpDevice -InstanceId $device.InstanceId -ErrorAction SilentlyContinue
            if ($currentDevice.Status -eq 'OK') {
                Write-Log "    Status: OK - Device reconnected successfully" -Level Success
            }
            else {
                Write-Log "    Status: $($currentDevice.Status)" -Level Warning
            }
        }
        catch {
            Write-Log "    Failed to re-enable: $_" -Level Error
            $enableSuccess = $false
        }
    }

    # Also trigger a device scan for good measure
    & pnputil.exe /scan-devices 2>&1 | Out-Null

    if ($enableSuccess) {
        Write-Log "All USB sensors re-enabled successfully" -Level Success
    }
    else {
        Write-Log "Some devices failed to re-enable - may need physical replug" -Level Warning
    }

    return $enableSuccess
}

#endregion

#region Validation Functions
# ============================================================================
function Test-Installation {
    param([string]$Mode)

    Write-Host "`n=== Validating Installation ===" -ForegroundColor Cyan

    $validation = @{
        Success = $true
        Checks  = @()
    }

    # Check Shared Files directory
    if (Test-Path $Script:Config.Paths.SharedFiles) {
        $validation.Checks += @{ Component = "Shared Files Directory"; Status = "PASS" }
    }
    else {
        $validation.Checks += @{ Component = "Shared Files Directory"; Status = "FAIL" }
        $validation.Success = $false
    }

    # Check required DLLs
    $requiredDLLs = @("CDRData.dll", "OMEGADLL.dll")
    if ($Mode -eq 'IOSS') {
        $requiredDLLs += "CDRImageProcess.dll"
    }

    foreach ($dll in $requiredDLLs) {
        $dllPath = Join-Path $Script:Config.Paths.SharedFiles $dll
        if (Test-Path $dllPath) {
            $version = (Get-Item $dllPath).VersionInfo.FileVersion
            $validation.Checks += @{ Component = $dll; Status = "PASS"; Version = $version }
        }
        else {
            $validation.Checks += @{ Component = $dll; Status = "FAIL"; Version = "Not Found" }
            $validation.Success = $false
        }
    }

    # Check IOSS service (IOSS mode only)
    if ($Mode -eq 'IOSS') {
        $iossService = Get-Service -Name "IOSS*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($iossService -and $iossService.Status -eq 'Running') {
            $validation.Checks += @{ Component = "IOSS Service"; Status = "PASS"; Version = $iossService.Status }
        }
        elseif ($iossService) {
            $validation.Checks += @{ Component = "IOSS Service"; Status = "WARN"; Version = $iossService.Status }
        }
        else {
            $validation.Checks += @{ Component = "IOSS Service"; Status = "FAIL"; Version = "Not Found" }
            $validation.Success = $false
        }
    }

    # Output validation results
    foreach ($check in $validation.Checks) {
        $color = switch ($check.Status) {
            'PASS' { 'Green' }
            'WARN' { 'Yellow' }
            'FAIL' { 'Red' }
        }
        $versionInfo = if ($check.Version) { " ($($check.Version))" } else { "" }
        Write-Host "  [$($check.Status)] $($check.Component)$versionInfo" -ForegroundColor $color
    }

    $Script:Results.Validation = $validation
    return $validation.Success
}

#endregion

#region Main Execution
# ============================================================================
function Invoke-LegacyInstallation {
    param([hashtable]$Installers)

    Write-Host "`n=== Legacy Installation Mode ===" -ForegroundColor Cyan

    # Step 0a: Stop AutoDetectServer.exe if running
    Stop-AutoDetectServer

    # Step 0b: Disable USB sensor if connected (per Patterson: "disconnect all Schick equipment")
    Write-Host "`n=== Pre-Installation: Disconnecting Sensor ===" -ForegroundColor Cyan
    Disable-USBSensorForInstall

    # Step 1: MSXML 4.0 (if needed)
    if ($Installers.ContainsKey('MSXML4')) {
        if (-not (Install-MSXML4 -InstallerPath $Installers.MSXML4)) {
            return $false
        }
    }

    # Step 2: CDR Elite
    if (-not (Install-CDRElite -InstallerPath $Installers.CDRElite)) {
        return $false
    }

    # Step 3: Rename CDRImageProcess.dll to .dllOLD (per Patterson docs)
    Rename-CDRImageProcessDLL

    # Step 4: CDR Patch (creates correct CDRImageProcess.dll v5.15.1877)
    if ($Installers.ContainsKey('CDRPatch')) {
        if (-not (Install-CDRPatch -InstallerPath $Installers.CDRPatch)) {
            return $false
        }
    }

    # Step 5: AE USB Driver
    if (-not (Install-AEUSBDriver -InstallerPath $Installers.AEUSBDriver)) {
        return $false
    }

    # Step 6: Re-enable USB sensor (per Patterson: reconnect after driver install)
    Write-Host "`n=== Post-Installation: Reconnecting Sensor ===" -ForegroundColor Cyan
    Enable-USBSensorAfterInstall

    return $true
}

function Invoke-IOSSInstallation {
    param([hashtable]$Installers)

    Write-Host "`n=== IOSS Installation Mode ===" -ForegroundColor Cyan

    # Step 0a: Stop AutoDetectServer.exe if running
    Stop-AutoDetectServer

    # Step 0b: Disable USB sensor if connected (per Patterson: "Unplug USB cable from Schick remote")
    Write-Host "`n=== Pre-Installation: Disconnecting Sensor ===" -ForegroundColor Cyan
    Disable-USBSensorForInstall

    # Step 0c: Uninstall legacy CDR components (required for IOSS per Patterson docs)
    Write-Host "`n=== Removing Legacy Components ===" -ForegroundColor Cyan
    Uninstall-LegacyComponents

    # Step 1: MSXML 4.0 (if needed)
    if ($Installers.ContainsKey('MSXML4')) {
        if (-not (Install-MSXML4 -InstallerPath $Installers.MSXML4)) {
            return $false
        }
    }

    # Step 2: CDR Elite (installs base DLLs: CDRData.dll, OMEGADLL.dll)
    if (-not (Install-CDRElite -InstallerPath $Installers.CDRElite)) {
        return $false
    }

    # Step 3: Clean Shared Files (preserve CDRData.dll and OMEGADLL.dll only)
    if (-not (Clear-SharedFilesForIOSS)) {
        return $false
    }

    # Step 4: CDR Patch (creates correct CDRImageProcess.dll v5.15.1877)
    if (-not (Install-CDRPatch -InstallerPath $Installers.CDRPatch)) {
        return $false
    }

    # Step 5: IOSS Autorun
    if (-not (Install-IOSS -InstallerPath $Installers.IOSS)) {
        return $false
    }

    # Step 6: Configure IOSS Service (delayed start, recovery options, Local System)
    if (-not (Set-IOSSServiceConfiguration)) {
        Write-Log "Service configuration had issues - manual review recommended" -Level Warning
    }

    # Step 7: Re-enable USB sensor (per Patterson: reconnect after IOSS install)
    Write-Host "`n=== Post-Installation: Reconnecting Sensor ===" -ForegroundColor Cyan
    Enable-USBSensorAfterInstall

    return $true
}

function Export-Results {
    try {
        $Script:Results | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputPath -Encoding UTF8
        Write-Log "Results exported to: $OutputPath" -Level Info
    }
    catch {
        Write-Log "Failed to export results: $_" -Level Warning
    }
}

# ============================================================================
# MAIN
# ============================================================================
$ErrorActionPreference = 'Stop'

# Initialize results object
$Script:Results = @{
    StartTime      = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    ComputerName   = $env:COMPUTERNAME
    Mode           = $null
    Success        = $false
    Prerequisites  = @()
    Validation     = @{}
    Log            = @()
}

Write-Host @"

╔═══════════════════════════════════════════════════════════════════╗
║           Schick Sensor Deployment Script v1.0.0                  ║
║                                                                   ║
║  CDR Elite 5.16 + IOSS/Legacy Auto-Detection                      ║
╚═══════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan

try {
    # Enable TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Step 1: Detect current state
    Write-Host "=== Detecting System State ===" -ForegroundColor Cyan
    $Script:CurrentState = Get-CurrentInstallState

    # Step 2: Detect Eaglesoft version
    $eaglesoftVersion = Get-EaglesoftVersion
    $Script:Results.EaglesoftVersion = if ($eaglesoftVersion) { $eaglesoftVersion.ToString() } else { "Not Detected" }

    # Step 3: Resolve install mode
    $resolvedMode = Resolve-InstallMode -EaglesoftVersion $eaglesoftVersion
    $Script:Results.Mode = $resolvedMode
    Write-Host "`n  Selected Install Mode: $resolvedMode" -ForegroundColor Yellow
    Write-Host ""

    # Step 4: Check prerequisites
    if (-not $SkipPrerequisites) {
        $prereqsPassed = Test-Prerequisites
        if (-not $prereqsPassed) {
            Write-Log "Prerequisite checks failed - aborting installation" -Level Error
            $Script:Results.Success = $false
            Export-Results
            exit 1
        }
    }

    # Step 5: Download installers
    $installers = Get-RequiredInstallers -Mode $resolvedMode
    if (-not $installers) {
        Write-Log "Failed to download required installers - aborting" -Level Error
        $Script:Results.Success = $false
        Export-Results
        exit 1
    }

    # Step 6: Download-only mode check
    if ($DownloadOnly) {
        Write-Log "Download-only mode - skipping installation" -Level Info
        Write-Host "`nInstallers downloaded to: $($Script:Config.Paths.TempDownload)" -ForegroundColor Green
        $Script:Results.Success = $true
        Export-Results
        exit 0
    }

    # Step 7: Run installation
    $installSuccess = switch ($resolvedMode) {
        'Legacy' { Invoke-LegacyInstallation -Installers $installers }
        'IOSS'   { Invoke-IOSSInstallation -Installers $installers }
    }

    if (-not $installSuccess) {
        Write-Log "Installation failed" -Level Error
        $Script:Results.Success = $false
        Export-Results
        exit 1
    }

    # Step 8: Validate installation
    $validationPassed = Test-Installation -Mode $resolvedMode
    $Script:Results.Success = $validationPassed

    # Step 9: Final summary
    Write-Host ""
    if ($validationPassed) {
        Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Green
        Write-Host "  INSTALLATION COMPLETED SUCCESSFULLY" -ForegroundColor Green
        Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Green
    }
    else {
        Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
        Write-Host "  INSTALLATION COMPLETED WITH WARNINGS - Review validation above" -ForegroundColor Yellow
        Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    }

    $Script:Results.EndTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Export-Results

    Write-Host "`n  Results exported to: $OutputPath" -ForegroundColor Gray
    Write-Host ""

    if ($validationPassed) { exit 0 } else { exit 2 }
}
catch {
    Write-Log "Unhandled exception: $_" -Level Error
    Write-Log $_.ScriptStackTrace -Level Error
    $Script:Results.Success = $false
    $Script:Results.Error = $_.ToString()
    Export-Results
    exit 1
}

#endregion
