# PowerShell Script to Restart DentrixAceServer and Verify Status with Logging
# Requires elevation for service management

param(
    [int]$TimeoutSeconds = 30,
    [switch]$Verbose
)

$serviceName = "DentrixAceServer"
$logDirectory = "C:\Logs"
$logFile = Join-Path -Path $logDirectory -ChildPath "DentrixAceServer_Restart.log"

# Ensure the log directory exists
if (-not (Test-Path -Path $logDirectory)) {
    try {
        New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
    }
    catch {
        Write-Error "Failed to create log directory: $_"
        exit 1
    }
}

# Function to log messages
function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$timestamp [$Level] $Message"
    
    try {
        Add-Content -Path $logFile -Value $entry -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write to log file: $_"
    }
    
    # Color-coded console output
    switch ($Level) {
        "SUCCESS" { Write-Host $entry -ForegroundColor Green }
        "WARNING" { Write-Host $entry -ForegroundColor Yellow }
        "ERROR"   { Write-Host $entry -ForegroundColor Red }
        default   { Write-Host $entry }
    }
}

# Check if running as administrator
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Main execution
try {
    Write-Log "=== DentrixAceServer Restart Script Started ==="
    
    # Verify administrator privileges
    if (-not (Test-Administrator)) {
        Write-Log "This script requires administrator privileges to manage services." "ERROR"
        Write-Log "Please run PowerShell as Administrator and try again." "ERROR"
        exit 1
    }

    Write-Log "Checking if service '$serviceName' exists..."
    
    # Check if the service exists
    $service = Get-Service -Name $serviceName -ErrorAction Stop
    Write-Log "Service '$serviceName' found. Current status: $($service.Status)"
    
    # Log initial service state
    if ($service.Status -eq 'Running') {
        Write-Log "Service is currently running. Proceeding with restart..."
    } elseif ($service.Status -eq 'Stopped') {
        Write-Log "Service is currently stopped. Will start the service..." "WARNING"
    } else {
        Write-Log "Service is in '$($service.Status)' state. Attempting restart..." "WARNING"
    }
    
    # Restart the service
    Write-Log "Issuing restart command for service '$serviceName'..."
    Restart-Service -Name $serviceName -Force -ErrorAction Stop
    Write-Log "Restart command completed successfully."
    
    # Wait for service to stabilize with timeout
    Write-Log "Waiting for service to stabilize (timeout: $TimeoutSeconds seconds)..."
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    do {
        Start-Sleep -Seconds 2
        $service = Get-Service -Name $serviceName -ErrorAction Stop
        
        if ($Verbose) {
            Write-Log "Current status: $($service.Status)" "INFO"
        }
        
        if ($service.Status -eq 'Running') {
            break
        }
        
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    
    $stopwatch.Stop()
    
    # Final status check
    $service = Get-Service -Name $serviceName -ErrorAction Stop
    
    if ($service.Status -eq 'Running') {
        Write-Log "SUCCESS: Service '$serviceName' is running. Startup time: $([math]::Round($stopwatch.Elapsed.TotalSeconds, 2)) seconds" "SUCCESS"
        
        # Additional verification - check if service is responding
        Write-Log "Performing additional service health check..."
        Start-Sleep -Seconds 3
        $serviceCheck = Get-Service -Name $serviceName
        
        if ($serviceCheck.Status -eq 'Running') {
            Write-Log "Service health check passed - '$serviceName' is stable and running." "SUCCESS"
            $exitCode = 0
        } else {
            Write-Log "Service health check failed - service status changed to: $($serviceCheck.Status)" "ERROR"
            $exitCode = 1
        }
    } else {
        Write-Log "FAILED: Service '$serviceName' is not running after restart attempt. Current status: $($service.Status)" "ERROR"
        Write-Log "Check Windows Event Logs for service-specific error details." "ERROR"
        $exitCode = 1
    }
}
catch [Microsoft.PowerShell.Commands.ServiceCommandException] {
    Write-Log "Service error: $($_.Exception.Message)" "ERROR"
    if ($_.Exception.Message -like "*Cannot find any service with service name*") {
        Write-Log "The service '$serviceName' does not exist on this system." "ERROR"
        Write-Log "Please verify the service name and ensure Dentrix is properly installed." "ERROR"
    }
    $exitCode = 1
}
catch {
    Write-Log "Unexpected error occurred: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR"
    $exitCode = 1
}
finally {
    Write-Log "=== Script execution completed ==="
    Write-Log "Log file location: $logFile"
}

exit $exitCode
