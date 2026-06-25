## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description   / $env:Description   - Ticket # or initials for audit trail (defaults to "No Description")
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description   = $env:Description,
    [string]$RMMScriptPath = $env:RMMScriptPath
)

$ScriptLogName = "tsprint-install.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Mirror the resolved parameter values into $env: so the rest of the script can reference
# either $Description or $env:Description, whichever form the input arrived in.
if (-not [string]::IsNullOrEmpty($Description))   { $env:Description   = $Description }
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) { $env:RMMScriptPath = $RMMScriptPath }

if ([string]::IsNullOrEmpty($Description)) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

# Store logs under $RMMScriptPath if provided, otherwise the standard Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"

# --- Quick TSPrint Client install via BITS ---
$Url        = 'https://www.terminalworks.com/downloads/tsprint/TSPrint_client.exe'
$Installer  = "$env:TEMP\TSPrint_client.exe"
$SilentArgs = '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'

Start-BitsTransfer -Source $Url -Destination $Installer          # download with BITS
Start-Process      -FilePath $Installer -ArgumentList $SilentArgs -Wait
Remove-Item        -Path $Installer -Force                       # tidy up

Stop-Transcript
