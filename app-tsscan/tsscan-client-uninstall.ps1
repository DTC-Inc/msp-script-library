## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description   / $env:Description   - Ticket # and/or initials, used as the Description for the job
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description   = $env:Description,
    [string]$RMMScriptPath = $env:RMMScriptPath
)

$ScriptLogName = "tsscan-client-uninstall.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the description if it was not supplied (e.g. an automated RMM run with no value passed).
if ($null -eq $Description) {
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

# Uninstall-TSScanClient.ps1
$paths = @(
  "${env:ProgramFiles(x86)}\TerminalWorks\TSScan Client\unins000.exe",
  "${env:ProgramFiles}\TerminalWorks\TSScan Client\unins000.exe",
  "${env:ProgramFiles(x86)}\TerminalWorks\TSScan\unins000.exe",
  "${env:ProgramFiles}\TerminalWorks\TSScan\unins000.exe"
)

$unins = $paths | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $unins) {
  $unins = Get-ItemProperty HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* ,
                             HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\* |
          Where-Object { $_.DisplayName -like 'TSScan Client*' } |
          Select-Object -ExpandProperty UninstallString -First 1
}

if ($unins) { Start-Process $unins '/SILENT' -Wait }
else        { Write-Warning 'TSScan Client not found.' }


Stop-Transcript
