## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description   / $env:Description   - Ticket # or initials, used as the Description for the job
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description   = $env:Description,
    [string]$RMMScriptPath = $env:RMMScriptPath
)

$ScriptLogName = "tsprint-install.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the Description if it was not supplied (most likely an automated RMM run).
if (-not $Description) {
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

# Install-TSScanClient.ps1  – run from an elevated prompt
$Url        = 'https://www.terminalworks.com/downloads/tsscan/TSScan_client.exe'
$Installer  = "$env:TEMP\TSScan_client.exe"
$SilentArgs = '/SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'   # Inno Setup

Start-BitsTransfer -Source $Url -Destination $Installer
Start-Process -FilePath $Installer -ArgumentList $SilentArgs -Wait
Remove-Item $Installer -Force

Stop-Transcript
