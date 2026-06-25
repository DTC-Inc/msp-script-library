## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $description   / $env:description   - Ticket # or initials for audit trail (defaults to "No description")
## $serviceName   / $env:serviceName   - REQUIRED. The TeamViewer service name to disable
## $rmmScriptPath / $env:rmmScriptPath - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-serviceName ...) or from an RMM that supplies values as env variables.
    [string]$description   = $env:description,
    [string]$serviceName   = $env:serviceName,
    [string]$rmmScriptPath = $env:rmmScriptPath
)

$scriptLogName = "teamviewer-uninstall.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied.
if (-not $description) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $description = "No description"
}

# serviceName is required (the interactive prompt accepted no default). Fail fast if missing.
if (-not $serviceName) {
    Write-Error "ERROR: Required input 'serviceName' not provided (set as -serviceName or `$env:serviceName)."
    exit 1
}

# Store the logs in the rmmScriptPath when provided, else the Windows logs directory.
if (-not [string]::IsNullOrEmpty($rmmScriptPath)) {
    $logPath = "$rmmScriptPath\logs\$scriptLogName"
} else {
    $logPath = "$env:WINDIR\logs\$scriptLogName"
}

Write-Output $description
Write-Output $rmmScriptPath

Start-Transcript -Path $logPath

# Check if the service exists
 $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

if ($service) {
    Write-Output "TeamViewer service found. Disabling..."

    # Stop the service if it is running
    if ($service.Status -eq "Running") {
        Stop-Service -Name $serviceName -Force
    }

    # Disable the service
    Set-Service -Name $serviceName -StartupType Disabled

    Write-Output "TeamViewer service has been disabled."
} else {
    Write-Output "TeamViewer service not found."
}

Write-Host "Testing paths to get version of TeamViewer installed."

$test64Bit = Test-Path $ENV:PROGRAMFILES\TeamViewer\uninstall.exe -PathType Leaf
$test32Bit = Test-Path "$ENV:PROGRAMFILES (X86)\TeamViewer\uninstall.exe" -PathType Leaf

if ($test64Bit) {
    Write-Host "Uninstalling TeamViewer 64-Bit"
    & $ENV:PROGRAMFILES\TeamViewer\uninstall.exe /S
}

if ($test32Bit) {
    Write-Host "Uninstalling TeamViewer 32-Bit"
    & "$ENV:PROGRAMFILES (X86)\TeamViewer\uninstall.exe" /S

}

Write-Host "TeamViewer was most likely uninstalled. We are not checking for that here in this script currently."

$osArchitecture = (Get-CimInstance Win32_operatingsystem).OSArchitecture

# Define the TeamViewer uninstall key
#$uninstallKey64bit = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
#$uninstallKey32bit = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"

#if ($uninstallKey64bit) {
    #$teamViewerKey = Get-ChildItem -Path $uninstallKey64bit | Where-Object { $_.GetValue("DisplayName") -like "*TeamViewer*" }
#} else {
    #$teamViewerKey = Get-ChildItem -Path $uninstallKey32bit | Where-Object { $_.GetValue("DisplayName") -like "*TeamViewer*" }
#}

# Check if TeamViewer is installed
#if ($teamViewerKey) {
    #Write-Output "TeamViewer is installed. Uninstalling..."

    # Get the uninstall string
    #$uninstallString = $teamViewerKey.GetValue("UninstallString")

    # Remove quotes from the uninstall string if they exist
    #$uninstallString = $uninstallString -replace '"', ''

    # Execute the uninstall string
    #Start-Process -FilePath $uninstallString -ArgumentList "/S" -Wait

    #Write-Output "TeamViewer has been uninstalled."
#} else {
    #Write-Output "TeamViewer is not installed."
#}



#Stop-Transcript
