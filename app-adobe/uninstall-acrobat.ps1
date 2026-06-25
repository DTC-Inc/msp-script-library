## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $description   / $env:description   - Ticket # or initials for audit trail
## $rmmScriptPath / $env:rmmScriptPath - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-description ...) or from an RMM that supplies values as env variables.
    [string]$description   = $env:description,
    [string]$rmmScriptPath = $env:rmmScriptPath
)

$scriptLogName = "uninstall-acrobat.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied (e.g. an automated RMM run).
if (-not $description) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $description = "No description"
}

# Store the logs in the rmmScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($rmmScriptPath)) {
    $logPath = "$rmmScriptPath\logs\$scriptLogName"
} else {
    $logPath = "$env:WINDIR\logs\$scriptLogName"
}

Start-Transcript -Path $logPath

Write-Host "Uninstalling all versions of Adobe Acrobat."

$Apps = Get-WmiObject -Class Win32_Product | Where Name -like "Adobe Acrobat*" 
$Apps | ForEach-Object {
    $_.Uninstall()
}

$Apps = Get-WmiObject -Class Win32_Product | Where Name -like "Adobe Reader*" 
$Apps | ForEach-Object {
    $_.Uninstall()
}


Stop-Transcript
