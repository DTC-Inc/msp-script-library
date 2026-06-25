## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
# $bannerTitle   / $env:bannerTitle   - Title (LegalNoticeCaption) shown on the login banner
# $bannerText    / $env:bannerText    - Message (LegalNoticeText) shown on the login banner
# $Description    / $env:Description    - Ticket # or initials for audit trail
# $RMMScriptPath  / $env:RMMScriptPath  - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-bannerTitle ...) or from an RMM that supplies values as env variables.
    [string]$bannerTitle   = $env:bannerTitle,
    [string]$bannerText    = $env:bannerText,
    [string]$Description    = $env:Description,
    [string]$RMMScriptPath  = $env:RMMScriptPath
)

$ScriptLogName = "msft-windows-add-login-banner.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied.
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

# Registry paths for login banner settings
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"

# Set the "LegalNoticeCaption" (title) in the registry
Set-ItemProperty -Path $regPath -Name "LegalNoticeCaption" -Value $bannerTitle -Force

# Set the "LegalNoticeText" (message) in the registry
Set-ItemProperty -Path $regPath -Name "LegalNoticeText" -Value $bannerText -Force

# Confirm the changes
Write-Host "Login banner set successfully."

Stop-Transcript
