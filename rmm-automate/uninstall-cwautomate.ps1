## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description         / $env:Description         - Ticket # or initials, used as the Description for the job
## $AutomateUninstaller / $env:AutomateUninstaller - URL of the universal Automate uninstaller to download
## $RMMScriptPath       / $env:RMMScriptPath       - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description         = $env:Description,
    [string]$AutomateUninstaller = $env:AutomateUninstaller,
    [string]$RMMScriptPath       = $env:RMMScriptPath
)

$ScriptLogName = "uninstall-cwautomate.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Mirror the resolved parameter values into $env: so the rest of the script can reference
# either $Name or $env:Name, whichever form the input arrived in.
if (-not [string]::IsNullOrEmpty($Description))         { $env:Description         = $Description }
if (-not [string]::IsNullOrEmpty($AutomateUninstaller)) { $env:AutomateUninstaller = $AutomateUninstaller }
if (-not [string]::IsNullOrEmpty($RMMScriptPath))       { $env:RMMScriptPath       = $RMMScriptPath }

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

Start-Transcript -Path $LogPath

Write-Output "Description: $Description"
Write-Output "Log path: $LogPath"

Write-Output "Downloading universal automate installer."

try {
    wget $AutomateUninstaller -OutFile $ENV:WINDIR\TEMP\Agent_Uninstall.exe
    Write-Output "Download successful."
} catch {
    Write-Output "Error downloading: $_"
    Stop-Transcript
    Exit 3
}

Write-Output "Uninstalling automate."

try {
    & $ENV:WINDIR\TEMP\Agent_Uninstall.exe /q
    Write-Output "Uninstall successful."
} catch {
    Write-Output "Error uninstalling: $_"
    Stop-Transcript
    Exit 3
}

Stop-Transcript
Exit 0
