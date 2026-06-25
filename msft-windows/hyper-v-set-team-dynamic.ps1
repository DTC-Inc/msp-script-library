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

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied.
if ([string]::IsNullOrEmpty($description)) {
    Write-Host "Description was not provided. This was most likely run automatically from the RMM and no information was passed."
    $description = "No description"
}

# Store the logs in the rmmScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($rmmScriptPath)) {
    $logPath = "$rmmScriptPath\logs\hyper-v-set-team-dynamic.log"
} else {
    $logPath = "$env:WINDIR\logs\hyper-v-set-team-dynamic.log"
}

Start-Transcript -Path $logPath

Write-Host "This script is being run for $description"

Get-VMSwitchTeam | Where -Property TeamingMode -eq "SwitchIndependent" | Select -Expand Name | ForEach-Object { Set-VMSwitchTeam -LoadBalancingAlgorithm Dynamic -Name $_; Write-Host "Setting VM Switch $_ to Dynamic" }


Stop-Transcript
