## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description     / $env:Description     - Ticket # or initials for the job Description
## $NewComputerName / $env:NewComputerName - REQUIRED. New computer name (<= 15 chars, letters/numbers/hyphens)
## $RenameNeeded    / $env:RenameNeeded    - Set to True in RMM if rename needed (default: false)
## $RMMScriptPath   / $env:RMMScriptPath   - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-NewComputerName ...) or from an RMM that supplies values as env variables.
    [string]$Description     = $env:Description,
    [string]$NewComputerName = $env:NewComputerName,
    [bool]$RenameNeeded      = $(if ([string]::IsNullOrEmpty($env:RenameNeeded)) { $false } else { [bool]::Parse($env:RenameNeeded) }),
    [string]$RMMScriptPath   = $env:RMMScriptPath
)

$ScriptLogName = "msft-windows-rename-compuer.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

$CurrentComputerName = $env:COMPUTERNAME

# Default the Description if it was not supplied.
if (-not $Description) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

# Validate required inputs. These must come from -Parameter or $env: -- there is no prompt.
if (-not $NewComputerName) {
    Write-Error "ERROR: Required input 'NewComputerName' not provided (set as -Parameter or `$env:NewComputerName)."
    exit 1
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

# Rename computer if needed

If ($RenameNeeded) {
   # Rename the computer
   try {
       Rename-Computer -NewName $NewComputerName -Force
       Write-Host "Computer name has been changed to $NewComputerName and will take effect on next reboot"
   } catch {
       Write-Host "Failed to rename the computer. Error: $_"
       Exit 1
   }
} else {
  # Rename not needed
  Write-Host "Computer rename not needed. No action taken."
}

Stop-Transcript
