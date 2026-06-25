## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
# $installerUrl / $env:installerUrl - Teramind install URL for your instance
# $installerPath / $env:installerPath - Local path and filename of Teramind installer
# $tmRouter / $env:tmRouter - Teramind TMROUTER value for your instance
# $tmInstance / $env:tmInstance - Teramind TMINSTANCE value for your instance
# $Description / $env:Description - Ticket # or initials for audit trail
# $RMMScriptPath / $env:RMMScriptPath - Optional log directory base provided by the RMM

# No variables are required for this script besides $Description.

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-installerUrl ...) or from an RMM that supplies values as env variables.
    [string]$installerUrl  = $env:installerUrl,
    [string]$installerPath = $env:installerPath,
    [string]$tmRouter      = $env:tmRouter,
    [string]$tmInstance    = $env:tmInstance,
    [string]$Description    = $env:Description,
    [string]$RMMScriptPath  = $env:RMMScriptPath
)

$ScriptLogName = "app-tm-install.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

if ($null -eq $Description -or $Description -eq "") {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
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
Write-Host "InstallerURL: $installerUrl"
Write-Host "InstallerPath: $installerPath"

# Define service name
$serviceName = "tsvchst"

# Check if the service exists
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

if ($service) {
    Write-Host "Teramind already installed. '$serviceName' service exists."
    exit 0
} else {
    Write-Host "'$serviceName' service not found. Downloading Teramind installer."

    # Download the installer
    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath

    # Verify if the installer was downloaded
    if (Test-Path $installerPath) {
        Write-Host "Download successful. Proceeding with installation..."

        # Install the Teramind silently
        Start-Process 'msiexec.exe' -ArgumentList @('/I', $installerPath, "TMROUTER=$tmRouter", "TMINSTANCE=$tmInstance", '/qn') -NoNewWindow -Wait

        # Check if the service exists
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

        if ($service) {
            Write-Host "Teramind installed successfully."
        } else {
            Write-Host "Teramind install failed. '$serviceName' not detected."
        }

       # Remove the installer file
       Write-Host "Removing $installerPath"
       Remove-Item -Path $installerPath -Force

    } else {
        Write-Host "Download failed. Please check the URL and try again."
    }
}

Stop-Transcript
