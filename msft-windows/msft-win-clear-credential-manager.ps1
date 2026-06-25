# This script must be run in the user context of the user with saved credentials you want to delete. It does not work being run by SYSTEM.

## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $description    / $env:description    - Ticket # or initials for audit trail
## $targetToDelete / $env:targetToDelete - Hostname or fqdn of the credential to delete (required)
## $rmmScriptPath  / $env:rmmScriptPath  - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-description ...) or from an RMM that supplies values as env variables.
    [string]$description    = $env:description,
    [string]$targetToDelete = $env:targetToDelete,
    [string]$rmmScriptPath  = $env:rmmScriptPath
)

$scriptLogName = "msft-win-clear-credential-manager.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied.
if (-not $description) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $description = "No description"
}

# Validate required input. This must come from -Parameter or $env: -- there is no prompt.
if (-not $targetToDelete) {
    Write-Error "ERROR: Required input not provided (set as -Parameter or `$env:): targetToDelete"
    exit 1
}

# Store the logs in the rmmScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($rmmScriptPath)) {
    $logPath = "$rmmScriptPath\logs\$scriptLogName"
} else {
    $logPath = "$env:WINDIR\logs\$scriptLogName"
}

Write-Host "This script is being run for $description."
Write-Host "Deleting $targetToDelete."

# Clear Windows Credential Manager for the specified target
cmdkey /list | ForEach-Object {
    if ($_ -like "*$targetToDelete*") {
        Write-Host "Removing credentials for $targetToDelete"
        cmdkey /delete:$targetToDelete
    }
}

Write-Host "Credentials for $targetToDelete removed from Credential Manager."

pause
