## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description   / $env:Description   - Ticket # or initials for audit trail
## $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description   = $env:Description,
    [string]$RMMScriptPath = $env:RMMScriptPath
)

$ScriptLogName = "restart-eaglesoft.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied. This was most likely run
# automatically from the RMM and no information was passed.
if (-not $Description) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

# Store the logs in the RMMScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"

# Define the registry path to check
$registryPath = "HKLM:\SOFTWARE\WOW6432Node\Eaglesoft\Paths"
$valueName = "Shared Files"

# Check if the registry path exists
if (Test-Path $registryPath) {
    # Retrieve the value stored at the specified registry path
    $value = Get-ItemProperty -Path $registryPath | Select-Object -ExpandProperty $valueName

    if ($value) {
        # If the value exists, launch the executable using the retrieved value
        $executablePath = $value
        # Check if the executable file exists
        if (Test-Path $executablePath) {
            # Launch the executable
            & $executablePath\PattersonServerStatus.exe -stop
            Start-Sleep 600
            & $executablePath\PattersonServerStatus.exe -start
        } else {
            Write-Host "Executable file not found at path: $executablePath"
        }
    } else {
        Write-Host "Value '$valueName' not found at registry path: $registryPath"
    }
} else {
    Write-Host "Registry path does not exist: $registryPath"
}

Stop-Transcript
