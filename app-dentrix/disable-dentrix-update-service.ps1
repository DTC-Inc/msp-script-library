## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $description   / $env:description   - Ticket # or initials for audit trail (default: "No description")
## $rmmScriptPath / $env:rmmScriptPath - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-description ...) or from an RMM that supplies values as env variables.
    [string]$description   = $env:description,
    [string]$rmmScriptPath = $env:rmmScriptPath
)

$scriptLogName = "disable-dentrix-update-service.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied.
if (-not $description) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $description = "No description"
}

# Store the logs in the rmmScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($rmmScriptPath)) {
    $logPath = "$rmmScriptPath\logs\$scriptLogName"
} else {
    $logPath = "$env:WINDIR\logs\$scriptLogName"
}

Start-Transcript -Path $logPath
    Write-Host "Description: $description"
    Write-Host "Log path: $logPath"

    # Specify the name of the service you want to disable
    $serviceName = "DtxUpdaterSrv"

    # Check if the service exists
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        # Stop the service if it's running
        if (Get-Service -Name $serviceName | Where-Object { $_.Status -eq 'Running' }) {
            Stop-Service -Name $serviceName
            Write-Host "Service '$serviceName' stopped successfully."
        }

        # Disable the service
        Set-Service -Name $serviceName -StartupType Disabled
        Write-Host "Service '$serviceName' disabled successfully."
    } else {
        # Exit if the service doesn't exist
        Write-Host "Service '$serviceName' not found. Exiting script."
        exit
    }

Stop-Transcript
