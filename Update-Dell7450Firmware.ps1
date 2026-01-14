#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Dell NVMe 7450 Firmware Update Script
.DESCRIPTION
    Detects Dell EC NVMe 7450 drives via OMSA, checks firmware version,
    downloads update from Backblaze repo if needed, and installs silently.
.NOTES
    Requires: Dell OMSA installed, Administrator privileges
    Target Firmware: 1.4.0 A03
#>

# Configuration
$TargetFirmwareVersion = "1.4.0"
$BackblazeBaseUrl = "https://s3.us-west-002.backblazeb2.com/public-dtc/repo/vendors/dell/Server%20Drivers"
$FirmwareFiles = @{
    "RI" = "Express-Flash-PCIe-SSD_Firmware_JHKXR_WN64_1.4.0_A03_01.EXE"
    "MU" = "Express-Flash-PCIe-SSD_Firmware_JHKXR_WN64_1.4.0_A03_01.EXE"  # Same installer for RI/MU
}
$TempPath = "$env:TEMP\Dell7450Firmware"
$LogFile = "$TempPath\firmware_update.log"

# Initialize
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry
    Add-Content -Path $LogFile -Value $logEntry -ErrorAction SilentlyContinue
}

function Initialize-Environment {
    if (-not (Test-Path $TempPath)) {
        New-Item -ItemType Directory -Path $TempPath -Force | Out-Null
    }
    Write-Log "Script started"
    Write-Log "Target firmware version: $TargetFirmwareVersion"
}

# Check OMSA availability
function Test-OMSA {
    $omreport = Get-Command omreport -ErrorAction SilentlyContinue
    if (-not $omreport) {
        Write-Log "OMSA (omreport) not found. Please install Dell OpenManage Server Administrator." "ERROR"
        return $false
    }
    Write-Log "OMSA detected at: $($omreport.Source)"
    return $true
}

# Find BOSS-N1 controller
function Get-BossController {
    Write-Log "Searching for BOSS-N1 controller..."
    
    try {
        $controllerOutput = & omreport storage controller 2>&1
        
        # Parse controller output to find BOSS-N1
        $lines = $controllerOutput -split "`n"
        $controllerId = $null
        
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "BOSS-N1") {
                # Look backwards for the ID
                for ($j = $i; $j -ge 0 -and $j -ge ($i - 10); $j--) {
                    if ($lines[$j] -match "^ID\s*:\s*(\d+)") {
                        $controllerId = $matches[1]
                        break
                    }
                }
                break
            }
        }
        
        if ($null -ne $controllerId) {
            Write-Log "Found BOSS-N1 controller at ID: $controllerId"
            return $controllerId
        } else {
            Write-Log "BOSS-N1 controller not found" "ERROR"
            return $null
        }
    }
    catch {
        Write-Log "Error querying controllers: $_" "ERROR"
        return $null
    }
}

# Get 7450 drive info from BOSS controller
function Get-7450DriveInfo {
    param([string]$ControllerId)
    
    Write-Log "Querying physical disks on controller $ControllerId..."
    
    try {
        $diskOutput = & omreport storage pdisk controller=$ControllerId 2>&1
        $diskOutputString = $diskOutput -join "`n"
        
        # Split into individual disk blocks
        $diskBlocks = $diskOutputString -split "(?=^ID\s*:\s*\d+)" | Where-Object { $_ -match "7450" }
        
        $drives = @()
        
        foreach ($block in $diskBlocks) {
            if ($block -match "Model Number\s*:\s*(.+7450.+)") {
                $modelNumber = $matches[1].Trim()
                
                $firmwareVersion = $null
                if ($block -match "Firmware Revision\s*:\s*([\d\.]+)") {
                    $firmwareVersion = $matches[1].Trim()
                }
                
                $diskId = $null
                if ($block -match "^ID\s*:\s*(\d+)") {
                    $diskId = $matches[1].Trim()
                }
                
                # Determine variant (RI, MU, WI)
                $variant = "UNKNOWN"
                if ($modelNumber -match "\bRI\b") {
                    $variant = "RI"
                } elseif ($modelNumber -match "\bMU\b") {
                    $variant = "MU"
                } elseif ($modelNumber -match "\bWI\b") {
                    $variant = "WI"
                }
                
                $drives += [PSCustomObject]@{
                    DiskId = $diskId
                    Model = $modelNumber
                    Variant = $variant
                    FirmwareVersion = $firmwareVersion
                }
                
                Write-Log "Found drive: ID=$diskId, Model=$modelNumber, Variant=$variant, Firmware=$firmwareVersion"
            }
        }
        
        return $drives
    }
    catch {
        Write-Log "Error querying disks: $_" "ERROR"
        return @()
    }
}

# Compare firmware versions
function Compare-FirmwareVersion {
    param(
        [string]$Current,
        [string]$Target
    )
    
    try {
        $currentParts = $Current -split "\." | ForEach-Object { [int]$_ }
        $targetParts = $Target -split "\." | ForEach-Object { [int]$_ }
        
        for ($i = 0; $i -lt [Math]::Max($currentParts.Count, $targetParts.Count); $i++) {
            $c = if ($i -lt $currentParts.Count) { $currentParts[$i] } else { 0 }
            $t = if ($i -lt $targetParts.Count) { $targetParts[$i] } else { 0 }
            
            if ($c -lt $t) { return -1 }  # Current is older
            if ($c -gt $t) { return 1 }   # Current is newer
        }
        return 0  # Equal
    }
    catch {
        Write-Log "Error comparing versions: $_" "ERROR"
        return $null
    }
}

# Download firmware from Backblaze
function Get-FirmwareFromRepo {
    param([string]$Variant)
    
    if (-not $FirmwareFiles.ContainsKey($Variant)) {
        Write-Log "No firmware mapping for variant: $Variant" "ERROR"
        return $null
    }
    
    $fileName = $FirmwareFiles[$Variant]
    $downloadUrl = "$BackblazeBaseUrl/$fileName"
    $localPath = "$TempPath\$fileName"
    
    Write-Log "Downloading firmware from: $downloadUrl"
    
    try {
        $ProgressPreference = 'SilentlyContinue'  # Speed up download
        Invoke-WebRequest -Uri $downloadUrl -OutFile $localPath -UseBasicParsing -ErrorAction Stop
        
        if (Test-Path $localPath) {
            $fileSize = (Get-Item $localPath).Length / 1MB
            Write-Log "Download complete: $fileName ($([math]::Round($fileSize, 2)) MB)"
            return $localPath
        } else {
            Write-Log "Download failed: File not found after download" "ERROR"
            return $null
        }
    }
    catch {
        Write-Log "Download failed: $_" "ERROR"
        return $null
    }
}

# Install firmware silently
function Install-Firmware {
    param([string]$InstallerPath)
    
    if (-not (Test-Path $InstallerPath)) {
        Write-Log "Installer not found: $InstallerPath" "ERROR"
        return $false
    }
    
    Write-Log "Starting silent firmware installation..."
    Write-Log "Installer: $InstallerPath"
    
    try {
        $process = Start-Process -FilePath $InstallerPath -ArgumentList "/s", "/f" -Wait -PassThru -NoNewWindow
        
        Write-Log "Installer exit code: $($process.ExitCode)"
        
        switch ($process.ExitCode) {
            0 { 
                Write-Log "Firmware installation completed successfully"
                return $true
            }
            2 { 
                Write-Log "Firmware installation completed - reboot required"
                return $true
            }
            default {
                Write-Log "Firmware installation returned exit code: $($process.ExitCode)" "WARN"
                return $true  # May still be successful
            }
        }
    }
    catch {
        Write-Log "Installation error: $_" "ERROR"
        return $false
    }
}

# Main execution
function Main {
    Initialize-Environment
    
    # Check OMSA
    if (-not (Test-OMSA)) {
        Write-Log "Exiting: OMSA required" "ERROR"
        exit 1
    }
    
    # Find BOSS controller
    $bossControllerId = Get-BossController
    if ($null -eq $bossControllerId) {
        Write-Log "Exiting: BOSS-N1 controller not found" "ERROR"
        exit 1
    }
    
    # Get 7450 drives
    $drives = Get-7450DriveInfo -ControllerId $bossControllerId
    
    if ($drives.Count -eq 0) {
        Write-Log "No Dell NVMe 7450 drives detected" "WARN"
        Write-Host "`n*** No compatible drive detected ***" -ForegroundColor Yellow
        exit 0
    }
    
    Write-Log "Found $($drives.Count) Dell NVMe 7450 drive(s)"
    
    # Process each drive
    $needsUpdate = $false
    $hasWI = $false
    $updateVariant = $null
    
    foreach ($drive in $drives) {
        Write-Host "`n--- Drive ID: $($drive.DiskId) ---" -ForegroundColor Cyan
        Write-Host "Model: $($drive.Model)"
        Write-Host "Variant: $($drive.Variant)"
        Write-Host "Current Firmware: $($drive.FirmwareVersion)"
        Write-Host "Target Firmware: $TargetFirmwareVersion"
        
        # Check for WI variant
        if ($drive.Variant -eq "WI") {
            Write-Log "WI variant detected - manual install required" "WARN"
            Write-Host "`n*** MANUAL INSTALL REQUIRED: WI variant not supported by this script ***" -ForegroundColor Red
            $hasWI = $true
            continue
        }
        
        # Check for unknown variant
        if ($drive.Variant -eq "UNKNOWN") {
            Write-Log "Unknown variant detected: $($drive.Model)" "WARN"
            Write-Host "`n*** Unable to determine drive variant - manual verification required ***" -ForegroundColor Yellow
            continue
        }
        
        # Compare versions
        $comparison = Compare-FirmwareVersion -Current $drive.FirmwareVersion -Target $TargetFirmwareVersion
        
        if ($comparison -lt 0) {
            Write-Host "Status: UPDATE REQUIRED" -ForegroundColor Yellow
            $needsUpdate = $true
            $updateVariant = $drive.Variant
        } elseif ($comparison -eq 0) {
            Write-Host "Status: FIRMWARE CURRENT" -ForegroundColor Green
        } else {
            Write-Host "Status: FIRMWARE NEWER THAN TARGET" -ForegroundColor Green
        }
    }
    
    # Exit if WI found (manual intervention needed)
    if ($hasWI) {
        Write-Host "`n*** Script cannot continue - WI drives require manual firmware installation ***" -ForegroundColor Red
        Write-Log "Exiting: WI variant requires manual installation" "WARN"
        exit 0
    }
    
    # Perform update if needed
    if ($needsUpdate -and $null -ne $updateVariant) {
        Write-Host "`n=== Starting Firmware Update ===" -ForegroundColor Yellow
        
        # Download firmware
        $installerPath = Get-FirmwareFromRepo -Variant $updateVariant
        
        if ($null -eq $installerPath) {
            Write-Host "`n*** Download failed - check log for details ***" -ForegroundColor Red
            Write-Log "Exiting: Firmware download failed" "ERROR"
            exit 1
        }
        
        # Install firmware
        $installResult = Install-Firmware -InstallerPath $installerPath
        
        if ($installResult) {
            Write-Host "`n========================================" -ForegroundColor Green
            Write-Host "  FIRMWARE UPDATE COMPLETED" -ForegroundColor Green
            Write-Host "  Computer needs to restart" -ForegroundColor Yellow
            Write-Host "========================================" -ForegroundColor Green
            Write-Log "Firmware update completed - reboot required"
            
            # Prompt for restart
            Write-Host "`nThe system will restart in 30 seconds..." -ForegroundColor Yellow
            Write-Host "Press Ctrl+C to cancel restart" -ForegroundColor Yellow
            
            Start-Sleep -Seconds 30
            
            Write-Log "Initiating system restart"
            Restart-Computer -Force
        } else {
            Write-Host "`n*** Installation failed - check log for details ***" -ForegroundColor Red
            Write-Log "Exiting: Firmware installation failed" "ERROR"
            exit 1
        }
    } else {
        Write-Host "`n========================================" -ForegroundColor Green
        Write-Host "  ALL DRIVES AT TARGET FIRMWARE" -ForegroundColor Green
        Write-Host "  No update required" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Log "All drives at target firmware - no action required"
    }
    
    Write-Log "Script completed"
    Write-Host "`nLog file: $LogFile"
}

# Run
Main
