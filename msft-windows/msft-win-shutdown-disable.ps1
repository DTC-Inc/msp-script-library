## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description       / $env:Description       - REQUIRED. Ticket # or initials, used as the job Description
## $DisableShutdownUi / $env:DisableShutdownUi - REQUIRED. Y to disable the shutdown UI, N to enable it
## $RMMScriptPath     / $env:RMMScriptPath     - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description       = $env:Description,
    [string]$DisableShutdownUi = $env:DisableShutdownUi,
    [string]$RMMScriptPath     = $env:RMMScriptPath
)

$ScriptLogName = "msft-win-shutdown-disable.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied.
if ($null -eq $Description -or $Description -eq "") {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

# Validate required input. This must come from -Parameter or $env: -- there is no prompt.
if ([string]::IsNullOrEmpty($DisableShutdownUi)) {
    Write-Error "ERROR: Required input not provided (set as -Parameter or `$env:): DisableShutdownUi (Y or N)"
    exit 1
}

# Convert the Y/N input into the boolean the script logic expects.
if ($DisableShutdownUi -eq "Y") {
    $DisableShutdownUi = $True
} elseif ($DisableShutdownUi -eq "N") {
    $DisableShutdownUi = $False
} else {
    Write-Error "ERROR: Invalid value for DisableShutdownUi: '$DisableShutdownUi'. Please only enter Y or N."
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
Write Host "Disable Shutdown: $DisableShutdownUi"

# Set this variable:
#   $true  => Disable the shutdown option from the Windows UI
#   $false => Enable (restore) the shutdown option in the Windows UI
# $DisableShutdownUI = $true  # Change to $false to re-enable the shutdown option

# Define the registry path for Explorer policies
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"

if ($DisableShutdownUI) {
    # Disable Shutdown UI:
    # Create the registry key if it doesn't exist
    if (-not (Test-Path $regPath)) {
        New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies" -Name "Explorer" -Force | Out-Null
    }
    # Set the NoClose value to disable the shutdown/restart options in the UI
    Set-ItemProperty -Path $regPath -Name "NoClose" -Value 1 -Type DWord
    Write-Host "Shutdown option from the Windows UI has been disabled."
}
else {
    # Enable Shutdown UI:
    if (Test-Path $regPath) {
        # If the "NoClose" property exists, remove it
        if (Get-ItemProperty -Path $regPath -Name "NoClose" -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -Path $regPath -Name "NoClose" -ErrorAction SilentlyContinue
            Write-Host "Shutdown option from the Windows UI has been enabled."
        }
        else {
            Write-Host "No shutdown disabling registry entry found. Shutdown option is already enabled."
        }
    }
    else {
        Write-Host "Registry key not found. Shutdown option should be enabled by default."
    }
}

Write-Host "Note: You may need to log off or restart Explorer for the changes to take effect."

Stop-Transcript

