## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Every input can be supplied EITHER as a -Parameter on the command line OR as an
## environment variable of the same name. NinjaRMM passes script preset variables as
## environment variables, so each parameter below defaults to its matching $env: value.
## $Description   / $env:Description   - Ticket # or initials for audit trail
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM
##
## Add per-script variables below this line, e.g.:
## $CustomFieldFooDetected / $env:CustomFieldFooDetected - Boolean (1/0) field name (default: "fooDetected")
##
## For cross-context scripts that share state with a user-context companion, also require:
## $OrgName / $env:OrgName - REQUIRED. Organizational identifier used to namespace shared state under %PUBLIC% (e.g., "DTC")

param(
    # Each parameter defaults to its $env: counterpart, so the script is driven equally well
    # by -Parameter (manual/command-line) or by $env: (RMM/unattended). There is no Read-Host
    # and no $env:RMM flag: the script is non-interactive by design and never blocks on input.
    [string]$Description   = $env:Description,
    [string]$RMMScriptPath = $env:RMMScriptPath
)

# Standard DTC PowerShell Script Template
#
# Every script in this library follows the three-part structure below:
#   1. Variable Declaration  - the param() block and comment header above
#   2. Input Handling        - apply defaults / validate required inputs, set the log path
#   3. Script Logic          - your actual automation, wrapped in Start-Transcript
#
# IMPORTANT: Inputs arrive as parameters OR environment variables. Each param defaults to
# $env:<Name>, and below we mirror the resolved value back into $env:<Name>, so the rest of
# the script can reference EITHER $Name or $env:Name interchangeably -- whichever the input
# came in as. There is no interactive prompting: NinjaRMM (and any unattended/scheduled run)
# is non-interactive, and Read-Host would block or error there ("PowerShell is in
# NonInteractive mode"). Supply required inputs via the RMM preset variables or -Parameter.
#
# See CLAUDE.md for the full pattern documentation including application
# detection patterns, NinjaRMM custom field types, and the cross-context
# detection pattern (user + system split with shared JSON state).

$ScriptLogName = "EnterLogNameHere.log"

# --- Input handling ------------------------------------------------------

# Keep $env: in sync with the resolved parameter values so either $Name or $env:Name works
# from here down, regardless of whether the value arrived as a -Parameter or an env var.
if (-not [string]::IsNullOrEmpty($Description))   { $env:Description   = $Description }
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) { $env:RMMScriptPath = $RMMScriptPath }

# Set defaults for any optional variables here. Example:
#
# if ([string]::IsNullOrEmpty($env:CustomFieldFooDetected)) {
#     $env:CustomFieldFooDetected = "fooDetected"
# }

# Default the audit-trail description if it was not supplied.
if ([string]::IsNullOrEmpty($env:Description)) {
    Write-Host "Description was not provided. Defaulting (likely an automated RMM run with no value passed)."
    $env:Description = "No Description"
}

# Set the log path. SYSTEM-context scripts log under $env:RMMScriptPath when the RMM provides
# one, otherwise the standard Windows logs directory. (User-context scripts should instead use
# "$env:LOCALAPPDATA\dtc-logs\" -- $env:WINDIR\logs requires admin.)
if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
    $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"
}

# Ensure log directory exists before starting the transcript
$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    Write-Host "Creating log directory: $logDir"
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# --- Script logic --------------------------------------------------------
# Wrap everything below in Start-Transcript / Stop-Transcript for full
# logging. Replace the placeholder Write-Host lines with your automation.

Start-Transcript -Path $LogPath

Write-Host "Description: $env:Description"
Write-Host "Log path: $LogPath"

# Your script logic goes here.

Stop-Transcript
