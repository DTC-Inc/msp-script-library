## ** VARIALBES THAT ARE REQUIRED. SET IN INTERACTIVE FOR FROM RMM **
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
### $Description       / $env:Description       - Ticket # or initials for audit trail (default: "No Description")
### $autoAdminUserName / $env:autoAdminUserName - REQUIRED. Administrator username to auto login
### $Domain            / $env:Domain            - REQUIRED. Administrator user domain
### $Password          / $env:Password          - REQUIRED. Password for the auto login account
### $downloadURL       / $env:downloadURL        - REQUIRED. Download URL for the AutoLogon tool
### $RMMScriptPath     / $env:RMMScriptPath      - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description       = $env:Description,
    [string]$autoAdminUserName = $env:autoAdminUserName,
    [string]$Domain            = $env:Domain,
    [string]$Password          = $env:Password,
    [string]$downloadURL       = $env:downloadURL,
    [string]$RMMScriptPath     = $env:RMMScriptPath
)

$ScriptLogName = "msft-windows-autoadmin-logon.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default the audit-trail description if it was not supplied.
if (-not $Description) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $Description = "No Description"
}

# Validate required inputs. These must come from -Parameter or $env: -- there is no prompt.
$missing = @()
if (-not $autoAdminUserName) { $missing += 'autoAdminUserName' }
if (-not $Domain)           { $missing += 'Domain' }
if (-not $Password)         { $missing += 'Password' }
if (-not $downloadURL)      { $missing += 'downloadURL' }
if ($missing.Count -gt 0) {
    Write-Error "ERROR: Required input(s) not provided (set as -Parameter or `$env:): $($missing -join ', ')"
    exit 1
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
Write-Host "Username: $autoAdminUsername"
Write-Host "Domain: $Domain"
Write-Host "Password: ***REDACTED***"
Write-Host "Download URL: $downloadURL"

$targetDir = "$ENV:PROGRAMDATA\Sysinternals\Autologon"

# Create the target directory if it doesn't already exist
if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir
}

# Specify the path of the downloaded ZIP file
$zipFile = Join-Path -Path $targetDir -ChildPath "AutoLogon.zip"

# Download the ZIP file
Invoke-WebRequest -Uri $downloadURL -OutFile $zipFile

# Extract the ZIP file
Expand-Archive -Path $zipFile -DestinationPath $targetDir -Force

# Optionally, remove the ZIP file after extraction
Remove-Item -Path $zipFile

Write-Host "AutoLogon has been downloaded and extracted to: $targetDir"
$parms = $autoAdminUsername + " " + $domain + " " + $password + " /accepteula"
$parms = $parms.Split(" ")
& "$($targetDir)\Autologon.exe" $parms | Write-Host

# Define the path to the AutoAdminLogon registry key
$regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

# Query the AutoAdminLogon value
$autoAdminLogon = Get-ItemProperty -Path $regPath -Name "AutoAdminLogon" -ErrorAction SilentlyContinue

if ($null -ne $autoAdminLogon) {
    if ($autoAdminLogon.AutoAdminLogon -eq "1") {
        Write-Host "AutoAdminLogon is enabled."
        Exit 0
    } else {
        Write-Host "AutoAdminLogon is disabled."
        Exit 1
    }
} else {
    Write-Host "The AutoAdminLogon key does not exist."
    Exit 1
}

Stop-Transcript
