# This script logs the event, initiates a full scan, and reports results

# Function to write to log file
function Write-LogEntry {
    param (
        [string]$Message
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] $Message"
    
    # Define log path - adjust as needed
    $logPath = "C:\ProgramData\NinjaRMM\logs\DefenderScans"
    
    # Create log directory if it doesn't exist
    if (-not (Test-Path $logPath)) {
        New-Item -Path $logPath -ItemType Directory -Force | Out-Null
    }
    
    # Append to log file
    $logFile = Join-Path -Path $logPath -ChildPath "DefenderFullScan_$(Get-Date -Format 'yyyyMMdd').log"
    Add-Content -Path $logFile -Value $logMessage
    
    # Output to console as well (will be captured in NinjaRMM activity)
    Write-Output $logMessage
}

# Function to check if scan is already running
function Is-DefenderScanRunning {
    $scanStatus = Get-MpComputerStatus
    return ($scanStatus.ScanOptions -ne "NoScan" -and $scanStatus.ScanProgress -gt 0)
}

# Log script start
Write-LogEntry "Starting Windows Defender full scan script following alert trigger"

# Check Windows Defender service status
$defenderService = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
if ($defenderService -eq $null -or $defenderService.Status -ne "Running") {
    Write-LogEntry "ERROR: Windows Defender service is not running. Attempting to start."
    try {
        Start-Service -Name WinDefend -ErrorAction Stop
        Write-LogEntry "Successfully started Windows Defender service."
    } catch {
        Write-LogEntry "CRITICAL: Failed to start Windows Defender service. Exiting script."
        exit 1
    }
}

# Check if a scan is already running
if (Is-DefenderScanRunning) {
    Write-LogEntry "A Windows Defender scan is already in progress. Skipping new scan initiation."
    exit 0
}

# Get pre-scan status
try {
    $preScanStatus = Get-MpComputerStatus
    Write-LogEntry "Pre-scan status: AV Enabled: $($preScanStatus.AntivirusEnabled), Definitions: $($preScanStatus.AntivirusSignatureLastUpdated)"
    
    # Check if definitions are older than 3 days and update if needed
    if ($preScanStatus.AntivirusSignatureLastUpdated -lt (Get-Date).AddDays(-3)) {
        Write-LogEntry "Virus definitions are older than 3 days. Updating definitions before scan."
        Update-MpSignature -ErrorAction SilentlyContinue
        Write-LogEntry "Definition update completed."
    }
} catch {
    Write-LogEntry "WARNING: Unable to get pre-scan status. Continuing with scan. Error: $_"
}

# Start full scan
Write-LogEntry "Initiating full Windows Defender scan..."
try {
    Start-MpScan -ScanType FullScan -ErrorAction Stop
    Write-LogEntry "Full scan successfully initiated"
    
    # Report on recent threats (if any)
    $threats = Get-MpThreatDetection | Where-Object {$_.ThreatStatusDateTime -gt (Get-Date).AddDays(-7)}
    if ($threats -and $threats.Count -gt 0) {
        Write-LogEntry "Recent threats detected in the past week: $($threats.Count)"
        foreach ($threat in $threats) {
            Write-LogEntry "  Threat: $($threat.ThreatName), Status: $($threat.ThreatStatus), Path: $($threat.Resources)"
        }
    } else {
        Write-LogEntry "No recent threats detected in the past week."
    }
    
    # Return success for NinjaRMM to recognize
    Write-LogEntry "Script execution completed successfully."
    
    # Optional: Add a NinjaRMM compatible output for alerting
    Write-Host "NINJA-CUSTOM-EXIT-CODE:0"
    exit 0
    
} catch {
    Write-LogEntry "ERROR: Failed to start scan. Error: $_"
    # Return error for NinjaRMM to recognize
    Write-Host "NINJA-CUSTOM-EXIT-CODE:1"
    exit 1
}