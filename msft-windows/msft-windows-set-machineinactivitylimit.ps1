## Script variables that need set in RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description             / $env:Description             - Ticket # or initials for audit trail
## $machineInactivityLimit  / $env:machineInactivityLimit  - Machine inactivity limit (miliseconds)
## $RMMScriptPath           / $env:RMMScriptPath           - Optional log directory base provided by the RMM

# Getting input from parameters or environment variables. Non-interactive: no Read-Host.

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description            = $env:Description,
    [string]$machineInactivityLimit = $env:machineInactivityLimit,
    [string]$RMMScriptPath          = $env:RMMScriptPath
)

$ScriptLogName = "msft-windows-set-machineinacvitylimit.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Preserve the original RMM default for the audit-trail description.
if ($null -eq $Description) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

# Store the logs in the RMMScriptPath
if ($null -eq $RMMScriptPath) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"

} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "Machine Inactivity Limit (miliseconds): $machineInactivityLimit"

# Define the path and the name of the registry key
$registryPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
$keyName = "MachineInactivityLimit"

# Define the value to set (15 minutes in milliseconds)
# $value = 900000

# Check if the registry path exists, create if it doesn't
if (-Not (Test-Path $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
}

# Set the registry key value
Set-ItemProperty -Path $registryPath -Name $keyName -Value $value -Type DWord

# Output to confirm the operation
Write-Host "The MachineInactivityLimit has been set to 15 minutes."

Stop-Transcript
