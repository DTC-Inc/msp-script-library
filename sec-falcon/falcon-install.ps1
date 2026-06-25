## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description   / $env:Description   - Ticket # or initials for audit trail (default: "No Description")
## $CID           / $env:CID           - CrowdStrike Customer ID (CID) used to provision the sensor
## $DownloadURL   / $env:DownloadURL   - URL to download the Falcon sensor installer
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description   = $env:Description,
    [string]$CID           = $env:CID,
    [string]$DownloadURL   = $env:DownloadURL,
    [string]$RMMScriptPath = $env:RMMScriptPath
)

$ScriptLogName = "falcon-install.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied.
if ($null -eq $Description) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

# Store the logs in the RMMScriptPath when provided, else the Windows logs directory.
if ($null -eq $RMMScriptPath) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"

} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "CID: $CID"
Write-Host "DownloadUrl: $DownloadURL"

Write-Host "Downloading falcon installer"
wget "$DownloadURL" -OutFile "$ENV:WINDIR\temp\WindowsSensor.MaverickGyr.exe"

Write-Host "Installing Falcon"
& "$ENV:WINDIR\temp\WindowsSensor.MaverickGyr.exe" /install /quiet /norestart CID=$CID ProvNoWait=1


Stop-Transcript
