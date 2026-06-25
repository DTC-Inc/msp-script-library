## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description   / $env:Description   - Ticket # or initials for audit trail
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM

# Getting input from user if not running from RMM else set variables from RMM.

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description   = $env:Description,
    [string]$RMMScriptPath = $env:RMMScriptPath
)

$ScriptLogName = "msft-windows-s2d-health-check.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Preserve the original default for the audit-trail description.
if ([string]::IsNullOrEmpty($Description)) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

# Store the logs in the RMMScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"

# Get the health status of all storage spaces virtual disks
$virtualDisks = Get-VirtualDisk

# Initialize flag to track health status
$allHealthy = $true

foreach ($disk in $virtualDisks) {
    # Check the health status of each virtual disk
    if ($disk.HealthStatus -ne 'Healthy') {
        # Display details of the unhealthy virtual disk
        Write-Host "Unhealthy Virtual Disk Detected:"
        Write-Host "Name: $($disk.FriendlyName)"
        Write-Host "Health Status: $($disk.HealthStatus)"
        Write-Host "Operational Status: $($disk.OperationalStatus)"
        Write-Host "Size: $($disk.Size) bytes"
        Write-Host "Resiliency Setting: $($disk.ResiliencySettingName)"
        Write-Host "-----------------------------"

        $allHealthy = $false
    }
}

# Exit with 0 if all disks are healthy, otherwise exit with 1
if ($allHealthy) {
    exit 0
} else {
    exit 1
}


Stop-Transcript
