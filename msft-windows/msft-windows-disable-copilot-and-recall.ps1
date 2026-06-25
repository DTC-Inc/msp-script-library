## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description   / $env:Description   - Ticket # or initials for audit trail
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description   = $env:Description,
    [string]$RMMScriptPath = $env:RMMScriptPath
)

$ScriptLogName = "ms-win-disable-copilot-and-recall.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

if ($null -eq $Description -or $Description -eq "") {
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

# This script turns off Microsoft Copilot, hides the Copilot taskbar icon and disables Recall

# Variables need set in RMM

# Get SID for currently logged on user
$profileList = "HKLM:SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
$loggedOnUser = Get-Ciminstance -ClassName Win32_ComputerSystem | Select-Object UserName
$loggedOnUserName = $loggedOnUser.username
$UserWithoutDomain = $loggedOnUserName -replace "^.*?\\"
$GetSID = Get-ChildItem -Path $profileList -rec -ea SilentlyContinue | % { if((get-itemproperty -Path $_.PsPath) -match "$userWithoutDomain") { $_.PsPath} }
$SID = $GetSID -replace "^.*?list\\"
Write-Host "Current Logged On User: $loggedOnUserName `n"

# Add HKEY_USERS drive so HKU can be referenced reg path variables
Write-Host "Creating drive mapped to HKEY_USERS"
New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS
Write-Host "Drive mapped to HKEY_USERS `n"

# Variables
$copilotButtonRegPath = "HKU:\$SID\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
$copilotRegPath = "HKU:\$SID\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"
$recallRegPath = "HKU:\$SID\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"

# Turn off Copilot
if (!(Test-Path $copilotRegPath)) {
     Write-Host "Creating registry key" 
     New-Item -Path $copilotRegPath
     Write-Host "Registry key created"
}
Set-ItemProperty -Path $copilotRegPath -Name "TurnOffWindowsCopilot" -Value 1
Write-Host "$copilotRegPath\TurnOffWindowsCopilot reg value set to 1"

# Hide Copilot taskbar icon
Set-ItemProperty -Path $copilotButtonRegPath -Name "ShowCopilotButton" -Value 0
Write-Host "$copilotButtonRegPath\ShowCopilotButton reg value set to 0"

# Disable Recall
if (!(Test-Path $recallRegPath)) {
     Write-Host "Creating registry key"
     New-Item -Path $recallRegPath
     Write-Host "Registry key created"
}
Set-ItemProperty -Path $recallRegPath -Name "DisableAIDataAnalysis" -Value 1
Write-Host "$recallRegPath\DisableAIDataAnalysis reg value set to 1"

Stop-Transcript
