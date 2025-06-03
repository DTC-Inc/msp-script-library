# PowerShell Script to Restart DentrixAceServer - Optimized for NinjaOne
# NinjaOne automatically runs with SYSTEM privileges

param(
    [int]$TimeoutSeconds = 30
)

$serviceName = "DentrixAceServer"
$logDirectory = "C:\ProgramData\NinjaRMM\Logs"
$logFile = Join-Path -Path $logDirectory -ChildPath "DentrixAceServer_Restart_$(Get-Date -Format 'yyyy-MM-dd').log"

# Ensure the log directory exists
if (-not (Test-Path -Path $logDirectory)) {
    try {
        New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
    }
    catch {
        # Fallback to temp directory if NinjaRMM directory fails
        $logDirectory = $env:TEMP
        $logFile = Join-Path -Path $logDirectory -ChildPath "DentrixAceServer_Restart_$(Get-Date -Format 'yyyy-MM-dd').log"
    }
}

# Function to log messages and output to NinjaOne
function Write-Log {
    param (
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "$timestamp [$Level] $Message"
    
    # Write to log file
    try {
        Add-Content -Path $logFile -Value $entry -ErrorAction SilentlyContinue
    }
    catch {
        # Silent fail for logging - don't break script execution
    }
    
    # Output for NinjaOne console - use Write-Output for proper capture
    Write-Output $entry
    
    # Also use Write-Host for immediate visibility during execution
    switch ($Level) {
        "SUCCESS" { Write-Host $entry -ForegroundColor Green }
        "WARNING" { Write-Host $entry -ForegroundColor Yellow }
        "ERROR"   { Write-Host $entry -ForegroundColor Red }
        default   { Write-Host $entry }
    }
}

# Function to set NinjaOne custom fields (if needed for monitoring)
function Set-NinjaCustomField {
    param(
        [string]$FieldName,
        [string]$Value
    )
    try {
        # NinjaOne custom field setting (adjust field names as needed)
        if (Get-Command "Ninja-Property-Set" -ErrorAction SilentlyContinue) {
            & Ninja-Property-Set $FieldName $Value
        }
    }
    catch {
        # Silent fail if custom fields aren't configured
    }
}

# Main execution
$scriptStartTime = Get-Date

try {
    Write-Log "=== DentrixAceServer Restart Script Started (NinjaOne) ==="
    Write-Log "Script executed from: $($env:COMPUTERNAME)"
    Write-Log "Execution context: $($env:USERNAME)"
    
    Write-Log "Checking if service '$serviceName' exists..."
    
    # Check if the service exists
    $service = Get-Service -Name $serviceName -ErrorAction Stop
    $initialStatus = $service.Status
    Write-Log "Service '$serviceName' found. Current status: $initialStatus"
    
    # Set initial status in NinjaOne custom field (optional)
    Set-NinjaCustomField "DentrixServiceStatus" $initialStatus
    
    # Log initial service state
    switch ($initialStatus) {
        'Running' { 
            Write-Log "Service is currently running. Proceeding with restart..."
        }
        'Stopped' { 
            Write-Log "Service is currently stopped. Will start the service..." "WARNING"
        }
        default { 
            Write-Log "Service is in '$initialStatus' state. Attempting restart..." "WARNING"
        }
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
        
        if ($service.Status -eq 'Running') {
            break
        }
        
        # Progress indicator for NinjaOne
        $elapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 0)
        Write-Log "Status check: $($service.Status) (${elapsedSeconds}s elapsed)"
        
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    
    $stopwatch.Stop()
    $restartDuration = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
    
    # Final status check
    $service = Get-Service -Name $serviceName -ErrorAction Stop
    $finalStatus = $service.Status
    
    if ($finalStatus -eq 'Running') {
        $successMessage = "SUCCESS: Service '$serviceName' is running. Restart duration: ${restartDuration} seconds"
        Write-Log $successMessage "SUCCESS"
        
        # Additional stability check
        Write-Log "Performing service stability check..."
        Start-Sleep -Seconds 3
        $serviceCheck = Get-Service -Name $serviceName
        
        if ($serviceCheck.Status -eq 'Running') {
            Write-Log "Service stability check passed - '$serviceName' is stable and running." "SUCCESS"
            Set-NinjaCustomField "DentrixServiceStatus" "Running"
            Set-NinjaCustomField "DentrixLastRestart" (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            $exitCode = 0
        } else {
            $errorMessage = "Service stability check failed - status changed to: $($serviceCheck.Status)"
            Write-Log $errorMessage "ERROR"
            Set-NinjaCustomField "DentrixServiceStatus" $serviceCheck.Status
            $exitCode = 1
        }
    } else {
        $errorMessage = "FAILED: Service '$serviceName' is not running after restart. Status: $finalStatus"
        Write-Log $errorMessage "ERROR"
        Write-Log "Recommendation: Check Windows Event Logs (System/Application) for service errors." "ERROR"
        Set-NinjaCustomField "DentrixServiceStatus" $finalStatus
        $exitCode = 1
    }
}
catch [Microsoft.PowerShell.Commands.ServiceCommandException] {
    $errorMessage = "Service error: $($_.Exception.Message)"
    Write-Log $errorMessage "ERROR"
    
    if ($_.Exception.Message -like "*Cannot find any service with service name*") {
        Write-Log "The service '$serviceName' does not exist on this system." "ERROR"
        Write-Log "Verify Dentrix installation and service name." "ERROR"
        Set-NinjaCustomField "DentrixServiceStatus" "NotFound"
    } else {
        Set-NinjaCustomField "DentrixServiceStatus" "Error"
    }
    $exitCode = 2
}
catch {
    $errorMessage = "Unexpected error: $($_.Exception.Message)"
    Write-Log $errorMessage "ERROR"
    Set-NinjaCustomField "DentrixServiceStatus" "Error"
    $exitCode = 3
}
finally {
    $totalDuration = [math]::Round(((Get-Date) - $scriptStartTime).TotalSeconds, 2)
    Write-Log "=== Script execution completed in ${totalDuration} seconds ==="
    Write-Log "Log file: $logFile"
    
    # Final output for NinjaOne activity log
    Write-Output "SCRIPT_RESULT: Exit Code $exitCode"
    if ($exitCode -eq 0) {
        Write-Output "SCRIPT_RESULT: DentrixAceServer restart completed successfully"
    } else {
        Write-Output "SCRIPT_RESULT: DentrixAceServer restart failed - see logs for details"
    }
}

# Return exit code for NinjaOne monitoring
exit $exitCode
