## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.

# $installerUrl  / $env:installerUrl  - URL to download the CynetEPS installer from
# $installerPath / $env:installerPath - Local path to save/run the installer
# $Description    / $env:Description    - Ticket # or initials for audit trail (default: "No Description")
# $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM

# No variables are required for this script besides $Description.

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description   = $env:Description,
    [string]$installerUrl  = $env:installerUrl,
    [string]$installerPath = $env:installerPath,
    [string]$RMMScriptPath = $env:RMMScriptPath
)

$ScriptLogName = "sec-cynet-install.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Mirror the resolved parameter values into $env: so the rest of the script can reference
# either $Description or $env:Description, whichever form the input arrived in.
if (-not [string]::IsNullOrEmpty($Description))   { $env:Description   = $Description }
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) { $env:RMMScriptPath = $RMMScriptPath }

if ([string]::IsNullOrEmpty($env:Description)) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $env:Description = "No Description"
}

# Store the logs in the RMMScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $env:Description"
Write-Host "Log path: $LogPath"
Write-Host "InstallerURL: $installerUrl"
Write-Host "InstallerPath: $installerPath"

$serviceName = "CynetLauncher"

# Check if the service exists
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

if ($service) {
    Write-Host "CynetEPS already installed. '$serviceName' service exists."
    exit 0
} else {
    Write-Host "'$serviceName' service not found. Downloading CynetEPS installer."

    # Download the installer
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath

    # Verify if the installer was downloaded
    if (Test-Path $installerPath) {
        Write-Host "Download successful. Proceeding with installation..."

        # Install the CynetEPS agent silently
        Start-Process 'msiexec.exe' -ArgumentList @('/I', $installerPath, '/qn', '/norestart') -NoNewWindow -Wait

        # Check if the service exists
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

        if ($service) {
            Write-Host "CynetEPS installed successfully."
        } else {
            Write-Host "CynetEPS install failed. '$serviceName' not detected."
        }

       # Remove the installer file
       Write-Host "Removing $installerPath"
       Remove-Item -Path $installerPath -Force

    } else {
        Write-Host "Download failed. Please check the URL and try again."
    }
}

Stop-Transcript
