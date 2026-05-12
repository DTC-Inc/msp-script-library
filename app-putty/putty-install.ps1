## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $InstallerUrl - (optional) Override URL for the PuTTY 64-bit MSI installer.
##                 Defaults to the official "latest" symlink from the.earth.li.
## $ForceReinstall - (optional) 1 = reinstall even if PuTTY is already present.

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "putty-install.log"

# Auto-detect non-interactive PowerShell (e.g. NinjaOne, Datto, scheduled tasks).
# When -NonInteractive is on the command line, Read-Host throws and would kill the
# script, so treat that as RMM mode even if $RMM was not explicitly passed.
try {
    $cmdLineArgs = [Environment]::GetCommandLineArgs()
    if ($cmdLineArgs | Where-Object { $_ -match '^-NonInteractive$' }) {
        if ($RMM -ne 1) {
            Write-Host "Non-interactive PowerShell detected; treating as RMM mode."
            $RMM = 1
        }
    }
} catch {
    # If detection itself fails, leave $RMM as-is and proceed.
}

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

} else {
    # Prefer RMMScriptPath when the RMM provides one (e.g. Datto), otherwise fall back to WINDIR.
    if ($RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
    }

    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    }
}

# Emit progress to stdout BEFORE the transcript starts, so even if Start-Transcript
# fails (no log dir, locked file, etc.) the RMM still captures something useful.
Write-Host "putty-install.ps1 starting"
Write-Host "Description: $Description"
Write-Host "RMM: $RMM"
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host "User context: $env:USERNAME"
Write-Host "PowerShell: $($PSVersionTable.PSVersion) ($([IntPtr]::Size * 8)-bit)"

# Pre-create the transcript directory so Start-Transcript can't fail on a missing folder.
$logDir = Split-Path -Path $LogPath -Parent
if ($logDir -and -not (Test-Path -Path $logDir)) {
    try {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        Write-Host "Created log directory: $logDir"
    } catch {
        Write-Host "Warning: could not create log directory ${logDir}: $($_.Exception.Message)"
    }
}

# Wrap Start-Transcript so a transcript failure (e.g. ErrorActionPreference=Stop in
# the RMM runner) cannot kill the script.
$transcriptStarted = $false
try {
    Start-Transcript -Path $LogPath -ErrorAction Stop | Out-Null
    $transcriptStarted = $true
    Write-Host "Transcript started: $LogPath"
} catch {
    Write-Host "Warning: Start-Transcript failed for ${LogPath}: $($_.Exception.Message)"
    Write-Host "Continuing without transcript."
}

Write-Host "Log path: $LogPath"

# --- Defaults ---
if ([string]::IsNullOrWhiteSpace($InstallerUrl)) {
    $InstallerUrl = 'https://the.earth.li/~sgtatham/putty/latest/w64/putty-64bit-installer.msi'
}

$expectedExe = 'C:\Program Files\PuTTY\putty.exe'

# --- Skip if already installed ---
if ((Test-Path -Path $expectedExe) -and ($ForceReinstall -ne 1)) {
    Write-Host "PuTTY is already installed at $expectedExe. Skipping installation."
    Write-Host "Set `$ForceReinstall = 1 to override."
    if ($transcriptStarted) { Stop-Transcript }
    exit 0
}

# --- Download MSI ---
$installer = Join-Path $env:TEMP 'putty-64bit-installer.msi'

Write-Host "Downloading PuTTY MSI from: $InstallerUrl"
Write-Host "Saving to: $installer"

try {
    # BITS first (preferred for RMM); fall back to Invoke-WebRequest if BITS is unavailable.
    Start-BitsTransfer -Source $InstallerUrl -Destination $installer -ErrorAction Stop
} catch {
    Write-Host "BITS transfer failed ($_). Falling back to Invoke-WebRequest."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $installer -UseBasicParsing
}

if (-not (Test-Path $installer)) {
    Write-Host "ERROR: Installer not found after download."
    if ($transcriptStarted) { Stop-Transcript }
    exit 1
}

# --- Install silently (per-machine, no UI, no reboot) ---
$msiLog = "$env:WINDIR\logs\putty-install-msi.log"
$msiArgs = @(
    '/i', "`"$installer`"",
    'ALLUSERS=1',
    '/qn',
    '/norestart',
    '/L*v', "`"$msiLog`""
)

Write-Host "Running: msiexec.exe $($msiArgs -join ' ')"
$proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
Write-Host "msiexec exit code: $($proc.ExitCode)"

# --- Cleanup ---
Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue

# --- Verify ---
if (Test-Path -Path $expectedExe) {
    $ver = (Get-Item $expectedExe).VersionInfo.ProductVersion
    Write-Host "[SUCCESS] PuTTY installed. Version: $ver"
    Write-Host "putty-install.ps1 completed"
    if ($transcriptStarted) { Stop-Transcript }
    exit 0
} else {
    Write-Host "[FAILURE] PuTTY not found at $expectedExe after install. See MSI log: $msiLog"
    if ($transcriptStarted) { Stop-Transcript }
    exit 1
}
