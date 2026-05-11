## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM           - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description   - Ticket # or initials for audit trail
## $env:RMMScriptPath - Optional log directory base provided by the RMM
##
## Add per-script variables below this line, e.g.:
## $env:CustomFieldFooDetected - Boolean (1/0) field name (default: "fooDetected")
##
## For cross-context scripts that share state with a user-context companion, also require:
## $env:OrgName       - REQUIRED. Organizational identifier used to namespace shared state under %PUBLIC% (e.g., "DTC")

# Standard DTC PowerShell Script Template
#
# Every script in this library follows the three-part structure below:
#   1. RMM Variable Declaration  - the comment block above this header
#   2. Input Handling             - RMM vs interactive detection, log path setup
#   3. Script Logic               - your actual automation, wrapped in Start-Transcript
#
# IMPORTANT: All RMM-supplied variables come via environment variables.
# Read them via $env:VarName at every use site. Bare $RMM / $Description /
# $RMMScriptPath references resolve to $null in true RMM mode and silently
# fall through to the interactive branch.
#
# Environment variables are always strings, so compare $env:RMM to "1" not 1.
#
# See CLAUDE.md for the full pattern documentation including application
# detection patterns, NinjaRMM custom field types, and the cross-context
# detection pattern (user + system split with shared JSON state).

# --- Shared lib includes (optional) --------------------------------------
# If this script needs helpers from oem-shared/lib/ or any other lib folder,
# author the script under src/<category-vendor>/ and add `# %INCLUDE` marker
# lines below ... the CI build inlines the referenced files into the fat
# script that ships to RMM endpoints. The marker path is relative to the
# repo root. Recursive includes are NOT supported (lib files cannot
# themselves contain `# %INCLUDE` markers). See src/README.md.
#
# Example:
# # %INCLUDE src/oem-shared/lib/oem-manufacturer-detect.ps1
# # %INCLUDE src/oem-dell/lib/dell-detection.ps1

$ScriptLogName = "EnterLogNameHere.log"

# --- Default optional RMM environment variables --------------------------
# Set defaults for any optional variables here by writing back to $env: so
# the rest of the script can keep referencing $env:VarName consistently.
# Example:
#
# if ([string]::IsNullOrEmpty($env:CustomFieldFooDetected)) {
#     $env:CustomFieldFooDetected = "fooDetected"
# }

# --- Input handling: RMM vs interactive ----------------------------------

if ($env:RMM -ne "1") {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
        $env:Description = Read-Host "Please enter the ticket # and/or your initials for audit trail"
        if ($env:Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"
} else {
    # RMM mode: store logs under $env:RMMScriptPath if the RMM provided one,
    # otherwise fall back to the standard Windows logs directory.
    if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
        $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$env:WINDIR\logs\$ScriptLogName"
    }

    if ([string]::IsNullOrEmpty($env:Description)) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $env:Description = "No Description"
    }
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
Write-Host "RMM: $env:RMM"

# --- Internet check (optional) -------------------------------------------
# Uncomment if this script needs internet for a vendor download (e.g. an
# OEM tooling installer like DCU, HPIA, LSU). Configure / BIOS / debloat
# leaves that operate on already-installed tooling should NOT include this
# check. Skip cleanly on offline so RMM doesn't flag a hard failure when
# the endpoint just doesn't have a route to the vendor.
#
# function Test-InternetAvailable {
#     try {
#         $resp = Invoke-WebRequest -Uri 'https://www.msftconnecttest.com/connecttest.txt' `
#             -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
#         return ($resp.StatusCode -eq 200)
#     } catch {
#         return $false
#     }
# }
#
# if (-not (Test-InternetAvailable)) {
#     Write-Host "No internet connectivity detected ... skipping vendor download. Exit 0."
#     Stop-Transcript
#     exit 0
# }

# Your script logic goes here.

Stop-Transcript
