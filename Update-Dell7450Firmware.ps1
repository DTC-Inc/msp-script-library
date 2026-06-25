#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Dell NVMe 7450 Firmware Update Script
.DESCRIPTION
    Detects Dell EC NVMe 7450 drives via OMSA, checks firmware version,
    downloads update from Backblaze repo if needed, and installs silently.
.NOTES
    Requires: Dell OMSA installed, Administrator privileges, Dell hardware
    Target Firmware: 1.4.0 A03
#>
param(
    [switch]$AutoRestart,
    [switch]$NoRestart,
    [int]$InstallerTimeoutSeconds = 600
)

#region RMM Variable Declaration
## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $RMM - Set to 1 to indicate RMM execution context
## $Description - Ticket number and/or technician initials for logging
## $RMMScriptPath - (Optional) Custom path for RMM script logs

$ScriptLogName = "dell7450-firmware-update.log"

# Configuration
$TargetFirmwareVersion = "1.4.0"
$BackblazeBaseUrl = "https://s3.us-west-002.backblazeb2.com/public-dtc/repo/vendors/dell/Server%20Drivers"
$FirmwareFiles = @{
    "RI" = @{
        FileName = "Express-Flash-PCIe-SSD_Firmware_JHKXR_WN64_1.4.0_A03_01.EXE"
        SHA256   = "67B7F289CB942A094F6EE9F4501A8E225F3D745C9E102EEC3C4B8698129DD4FA"
    }
    "MU" = @{
        FileName = "Express-Flash-PCIe-SSD_Firmware_JHKXR_WN64_1.4.0_A03_01.EXE"
        SHA256   = "67B7F289CB942A094F6EE9F4501A8E225F3D745C9E102EEC3C4B8698129DD4FA"
    }
}
$TempPath = "$env:TEMP\Dell7450Firmware"
#endregion

#region Input Handling
if ($RMM -ne 1) {
    # Interactive mode - prompt for ticket/initials
    do {
        $Description = Read-Host "Please enter the ticket # and, or your initials"
    } while ([string]::IsNullOrWhiteSpace($Description))

    $LogPath = "$ENV:WINDIR\logs"
} else {
    # RMM mode - use provided variables or defaults
    if ([string]::IsNullOrWhiteSpace($Description)) {
        $Description = "RMM-Automated"
    }

    if (-not [string]::IsNullOrWhiteSpace($RMMScriptPath)) {
        $LogPath = "$RMMScriptPath\logs"
    } else {
        $LogPath = "$ENV:WINDIR\logs"
    }

    # In RMM context, default to no interactive restart
    if (-not $PSBoundParameters.ContainsKey('NoRestart') -and -not $PSBoundParameters.ContainsKey('AutoRestart')) {
        $NoRestart = $true
    }
}

# Ensure log directory exists
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

$LogFile = "$LogPath\$ScriptLogName"
#endregion

#region Script Logic
# Start transcript for comprehensive logging
if (-not (Test-Path $TempPath)) {
    New-Item -ItemType Directory -Path $TempPath -Force | Out-Null
}
$TranscriptPath = "$TempPath\firmware_update_transcript.log"
Start-Transcript -Path $TranscriptPath -Append -ErrorAction SilentlyContinue

# Output diagnostic information
Write-Host "========================================"
Write-Host "Dell NVMe 7450 Firmware Update Script"
Write-Host "========================================"
Write-Host "Description: $Description"
Write-Host "Log Path: $LogFile"
Write-Host "RMM Mode: $(if ($RMM -eq 1) { 'Yes' } else { 'No' })"
Write-Host "========================================"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] [$Description] $Message"
    Write-Host $logEntry

    try {
        Add-Content -Path $LogFile -Value $logEntry -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write to log file: $_"
    }
}

# Check Dell manufacturer
function Test-DellSystem {
    Write-Log "Verifying Dell system..."

    try {
        $manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer

        if ($manufacturer -notmatch "Dell") {
            Write-Log "System manufacturer '$manufacturer' is not Dell" "ERROR"
            return $false
        }

        Write-Log "Dell system confirmed: $manufacturer"
        return $true
    }
    catch {
        Write-Log "Error checking system manufacturer: $_" "ERROR"
        return $false
    }
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

        # Split into individual disk blocks - use multiline flag for proper anchor matching
        $diskBlocks = $diskOutputString -split "(?m)(?=^ID\s*:\s*\d+)" | Where-Object { $_ -match "7450" }

        $drives = @()

        foreach ($block in $diskBlocks) {
            if ($block -match "Model Number\s*:\s*(.+7450.+)") {
                $modelNumber = $matches[1].Trim()

                $firmwareVersion = $null
                if ($block -match "Firmware Revision\s*:\s*([\d\.]+)") {
                    $firmwareVersion = $matches[1].Trim()
                }

                # Use multiline flag (?m) so ^ matches start of each line in the block
                $diskId = $null
                if ($block -match "(?m)^ID\s*:\s*(\d+)") {
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
        # Sanitize version segments - strip non-numeric characters before casting
        $currentParts = $Current -split "\." | ForEach-Object {
            $sanitized = $_ -replace '[^\d]', ''
            if ($sanitized) { [int]$sanitized } else { 0 }
        }
        $targetParts = $Target -split "\." | ForEach-Object {
            $sanitized = $_ -replace '[^\d]', ''
            if ($sanitized) { [int]$sanitized } else { 0 }
        }

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

# Verify SHA256 hash of downloaded file
function Test-FileHash {
    param(
        [string]$FilePath,
        [string]$ExpectedHash
    )

    try {
        $actualHash = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash

        if ($actualHash -eq $ExpectedHash) {
            Write-Log "File hash verification passed"
            return $true
        } else {
            Write-Log "File hash mismatch! Expected: $ExpectedHash, Got: $actualHash" "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "Error calculating file hash: $_" "ERROR"
        return $false
    }
}

# Download firmware from Backblaze
function Get-FirmwareFromRepo {
    param([string]$Variant)

    if (-not $FirmwareFiles.ContainsKey($Variant)) {
        Write-Log "No firmware mapping for variant: $Variant" "ERROR"
        return $null
    }

    $firmwareInfo = $FirmwareFiles[$Variant]
    $fileName = $firmwareInfo.FileName
    $expectedHash = $firmwareInfo.SHA256
    $downloadUrl = "$BackblazeBaseUrl/$fileName"
    $localPath = "$TempPath\$fileName"

    Write-Log "Downloading firmware from: $downloadUrl"

    try {
        $ProgressPreference = 'SilentlyContinue'  # Speed up download
        Invoke-WebRequest -Uri $downloadUrl -OutFile $localPath -UseBasicParsing -ErrorAction Stop

        if (Test-Path $localPath) {
            $fileSize = (Get-Item $localPath).Length / 1MB
            Write-Log "Download complete: $fileName ($([math]::Round($fileSize, 2)) MB)"

            # Verify SHA256 hash
            Write-Log "Verifying file integrity..."
            if (-not (Test-FileHash -FilePath $localPath -ExpectedHash $expectedHash)) {
                Write-Log "Firmware file failed integrity check - removing file" "ERROR"
                Remove-Item -Path $localPath -Force -ErrorAction SilentlyContinue
                return $null
            }

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
    param(
        [string]$InstallerPath,
        [int]$TimeoutSeconds = 600
    )

    if (-not (Test-Path $InstallerPath)) {
        Write-Log "Installer not found: $InstallerPath" "ERROR"
        return $false
    }

    Write-Log "Starting silent firmware installation..."
    Write-Log "Installer: $InstallerPath"
    Write-Log "Timeout: $TimeoutSeconds seconds"

    try {
        $process = Start-Process -FilePath $InstallerPath -ArgumentList "/s", "/f" -PassThru -NoNewWindow

        # Wait with timeout to prevent indefinite hangs
        $completed = $process.WaitForExit($TimeoutSeconds * 1000)

        if (-not $completed) {
            Write-Log "Installer timed out after $TimeoutSeconds seconds" "ERROR"
            try { $process.Kill() } catch { Write-Log "Failed to kill timed-out process: $_" "WARN" }
            return $false
        }

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
                Write-Log "Firmware installation failed with exit code: $($process.ExitCode)" "ERROR"
                return $false
            }
        }
    }
    catch {
        Write-Log "Installation error: $_" "ERROR"
        return $false
    }
}

# Main execution
try {
    Write-Log "Script started"
    Write-Log "Target firmware version: $TargetFirmwareVersion"

    # Check Dell system
    if (-not (Test-DellSystem)) {
        Write-Log "Exiting: Not a Dell system" "ERROR"
        exit 1
    }

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

    # Process each drive - use array to track all variants needing update
    $needsUpdate = $false
    $hasWI = $false
    $updateVariants = @()

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

        if ($null -eq $comparison) {
            Write-Host "Status: VERSION COMPARISON ERROR" -ForegroundColor Red
            Write-Log "Could not compare firmware version for drive $($drive.DiskId)" "ERROR"
            continue
        } elseif ($comparison -lt 0) {
            Write-Host "Status: UPDATE REQUIRED" -ForegroundColor Yellow
            $needsUpdate = $true
            if ($drive.Variant -notin $updateVariants) {
                $updateVariants += $drive.Variant
            }
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
        exit 1
    }

    # Perform update if needed
    if ($needsUpdate -and $updateVariants.Count -gt 0) {
        Write-Host "`n=== Starting Firmware Update ===" -ForegroundColor Yellow

        $allUpdatesSuccessful = $true

        foreach ($variant in $updateVariants) {
            Write-Log "Processing firmware update for variant: $variant"

            # Download firmware
            $installerPath = Get-FirmwareFromRepo -Variant $variant

            if ($null -eq $installerPath) {
                Write-Host "`n*** Download failed for $variant - check log for details ***" -ForegroundColor Red
                Write-Log "Firmware download failed for variant: $variant" "ERROR"
                $allUpdatesSuccessful = $false
                continue
            }

            # Install firmware with timeout
            $installResult = Install-Firmware -InstallerPath $installerPath -TimeoutSeconds $InstallerTimeoutSeconds

            if (-not $installResult) {
                Write-Host "`n*** Installation failed for $variant - check log for details ***" -ForegroundColor Red
                Write-Log "Firmware installation failed for variant: $variant" "ERROR"
                $allUpdatesSuccessful = $false
            }
        }

        if ($allUpdatesSuccessful) {
            Write-Host "`n========================================" -ForegroundColor Green
            Write-Host "  FIRMWARE UPDATE COMPLETED" -ForegroundColor Green
            Write-Host "  Computer needs to restart" -ForegroundColor Yellow
            Write-Host "========================================" -ForegroundColor Green
            Write-Log "Firmware update completed - reboot required"

            # Handle restart based on parameters
            if ($NoRestart) {
                Write-Host "`nRestart skipped (NoRestart flag set)" -ForegroundColor Yellow
                Write-Log "Restart skipped by NoRestart parameter"
            } elseif ($AutoRestart) {
                Write-Host "`nThe system will restart in 30 seconds..." -ForegroundColor Yellow
                Write-Log "AutoRestart enabled - restarting in 30 seconds"
                Start-Sleep -Seconds 30
                Write-Log "Initiating automatic system restart"
                Restart-Computer -Force
            } else {
                Write-Host "`nThe system will restart in 30 seconds..." -ForegroundColor Yellow
                Write-Host "Press Ctrl+C to cancel restart" -ForegroundColor Yellow
                Start-Sleep -Seconds 30
                Write-Log "Initiating system restart"
                Restart-Computer -Force
            }
        } else {
            Write-Host "`n*** Some updates failed - check log for details ***" -ForegroundColor Red
            Write-Log "Exiting: One or more firmware installations failed" "ERROR"
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
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
#endregion
