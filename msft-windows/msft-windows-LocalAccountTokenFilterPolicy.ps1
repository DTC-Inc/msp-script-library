## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $onOff         / $env:onOff         - Set this 1 to turn this on and 0 to turn this off.
## $Description   / $env:Description   - Ticket # or initials for audit trail (defaults to "No Description")
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-onOff ...) or from an RMM that supplies values as env variables.
    [string]$onOff         = $env:onOff,
    [string]$Description   = $env:Description,
    [string]$RMMScriptPath = $env:RMMScriptPath
)

$ScriptLogName = "LocalAccountTokenFilterPolicy.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Mirror the resolved RMMScriptPath into $env: so the log-path logic below can reference
# either form, whichever the input arrived in.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) { $env:RMMScriptPath = $RMMScriptPath }

if ([string]::IsNullOrEmpty($Description)) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

# Store the logs in the RMMScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
    $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"

# Define the registry path, entry name, and value
$registryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
$entryName = "LocalAccountTokenFilterPolicy"
$entryValue = $onOff

# Create a new registry key if it does not exist
if (-not (Test-Path $registryPath)) {
  New-Item -Path $registryPath -Force | Out-Null
}

# Set the registry entry value
Set-ItemProperty -Path $registryPath -Name $entryName -Value $entryValue -Type DWORD

# Output the result
Write-Output "Registry entry '$entryName' created with value '$entryValue' at '$registryPath'."

Stop-Transcript
