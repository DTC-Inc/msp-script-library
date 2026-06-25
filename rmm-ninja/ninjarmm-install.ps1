## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $description      / $env:description      - Ticket # and/or initials, used as the job description
## $ninjaDownloadUrl / $env:ninjaDownloadUrl - REQUIRED. URL to download the NinjaRMM agent
## $rmmScriptPath    / $env:rmmScriptPath    - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-description ...) or from an RMM that supplies values as env variables.
    [string]$description      = $env:description,
    [string]$ninjaDownloadUrl = $env:ninjaDownloadUrl,
    [string]$rmmScriptPath    = $env:rmmScriptPath
)

$scriptLogName = "Put the log file name here."

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the job description if it was not supplied (likely an automated RMM run with no value passed).
if ($description -eq $null -or $description -eq "") {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $description = "No description"
}

# The NinjaRMM download url is required. There is no prompt fallback -- fail fast if missing.
if ($ninjaDownloadUrl) {
    Write-Host "NinjaRMM download url is $ninjaDownloadUrl"
} else {
    Write-Host "NinjaRMM download url is blank. Exiting."
    Exit
}

# Store the logs in the rmmScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($rmmScriptPath)) {
    $logPath = "$rmmScriptPath\logs\$scriptLogName"
} else {
    $logPath = "$env:WINDIR\logs\$scriptLogName"
}

Start-Transcript -Path $logPath

# Download NinjaRMM
wget $ninjaDownloadUrl -OutFile $env:WINDIR\temp\ninjarmm.msi

# Install NinjaRMM
msiexec /i "$env:WINDIR\temp\ninjarmm.msi" /quiet /norestart

Stop-Transcript
