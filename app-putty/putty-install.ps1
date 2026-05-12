## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $env:RMM            - "1" to skip the interactive Read-Host prompt
## $env:Description    - Ticket # / initials for the transcript audit trail
## $env:RMMScriptPath  - Optional transcript root (e.g. Datto). Falls back to $env:WINDIR\logs
## $env:InstallerUrl   - Optional override for the MSI URL (emergency rollouts).
##                       Default is pinned to a known-good version below.
## $env:ForceReinstall - "1" to reinstall even if PuTTY is already present.

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "putty-install.log"

# Pinned PuTTY MSI. Bump intentionally when re-validated; do not chase /latest/ on a
# fleet installer running as SYSTEM. $env:InstallerUrl overrides for emergency rollouts.
$DefaultInstallerUrl = 'https://the.earth.li/~sgtatham/putty/0.83/w64/putty-64bit-0.83-installer.msi'
$ExpectedExe         = 'C:\Program Files\PuTTY\putty.exe'
$MinInstallerBytes   = 1MB   # reject obvious failed downloads (captive-portal HTML, 0-byte, etc.)

# Auto-detect non-interactive PowerShell (e.g. NinjaOne, Datto, scheduled tasks).
# When -NonInteractive is on the command line, Read-Host throws and would kill the
# script, so treat that as RMM mode even if $env:RMM was not explicitly passed.
try {
    $cmdLineArgs = [Environment]::GetCommandLineArgs()
    if ($cmdLineArgs | Where-Object { $_ -match '^-NonInteractive$' }) {
        if ($env:RMM -ne "1") {
            Write-Host "Non-interactive PowerShell detected; treating as RMM mode."
            $env:RMM = "1"
        }
    }
} catch {
    # If detection itself fails, leave $env:RMM as-is and proceed.
}

if ($env:RMM -ne "1") {
    $ValidInput = 0
    while ($ValidInput -ne 1) {
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"

} else {
    # Prefer RMMScriptPath when the RMM provides one (e.g. Datto), otherwise fall back to WINDIR.
    if ($env:RMMScriptPath) {
        $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$env:WINDIR\logs\$ScriptLogName"
    }

    if ([string]::IsNullOrWhiteSpace($env:Description)) {
        Write-Host "Description is empty/null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    } else {
        $Description = $env:Description
    }
}

# Resolve effective values (env-var overrides with sane defaults).
$InstallerUrl   = if ([string]::IsNullOrWhiteSpace($env:InstallerUrl)) { $DefaultInstallerUrl } else { $env:InstallerUrl }
$ForceReinstall = ($env:ForceReinstall -eq "1")

# Emit progress to stdout BEFORE the transcript starts, so even if Start-Transcript
# fails (no log dir, locked file, etc.) the RMM still captures something useful.
Write-Host "putty-install.ps1 starting"
Write-Host "Description    : $Description"
Write-Host "RMM            : $env:RMM"
Write-Host "Computer       : $env:COMPUTERNAME"
Write-Host "User context   : $env:USERNAME"
Write-Host "PowerShell     : $($PSVersionTable.PSVersion) ($([IntPtr]::Size * 8)-bit)"
Write-Host "InstallerUrl   : $InstallerUrl"
Write-Host "ForceReinstall : $ForceReinstall"

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

# Main body wrapped in try/finally so any unhandled throw still stops the transcript
# cleanly and returns a real exit code to the RMM.
$exitCode = 0
$installer = Join-Path $env:TEMP 'putty-64bit-installer.msi'

try {
    # --- Skip if already installed ---
    if ((Test-Path -Path $ExpectedExe) -and -not $ForceReinstall) {
        Write-Host "PuTTY is already installed at $ExpectedExe. Skipping installation."
        Write-Host "Set `$env:ForceReinstall = '1' to override."
        return
    }

    # --- Download MSI (BITS preferred, IWR fallback) ---
    Write-Host "Downloading PuTTY MSI from: $InstallerUrl"
    Write-Host "Saving to: $installer"

    try {
        Start-BitsTransfer -Source $InstallerUrl -Destination $installer -ErrorAction Stop
    } catch {
        Write-Host "BITS transfer failed ($($_.Exception.Message)). Falling back to Invoke-WebRequest."
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $InstallerUrl -OutFile $installer -UseBasicParsing -ErrorAction Stop
        } catch {
            throw "Both BITS and Invoke-WebRequest failed to download the installer: $($_.Exception.Message)"
        }
    }

    # --- Sanity-check the downloaded file before handing it to msiexec as SYSTEM ---
    if (-not (Test-Path $installer)) {
        throw "Installer not found at $installer after download."
    }
    $installerSize = (Get-Item $installer).Length
    Write-Host "Installer size: $installerSize bytes"
    if ($installerSize -lt $MinInstallerBytes) {
        throw "Installer is suspiciously small ($installerSize bytes, expected >= $MinInstallerBytes). Possible captive-portal HTML or failed download."
    }

    # --- Authenticode signature check ---
    # PuTTY MSI is signed by Simon Tatham. Reject anything else, even with a valid chain.
    $sig = Get-AuthenticodeSignature -FilePath $installer
    Write-Host "Authenticode status : $($sig.Status)"
    Write-Host "Authenticode signer : $($sig.SignerCertificate.Subject)"
    if ($sig.Status -ne 'Valid') {
        throw "MSI Authenticode signature is not Valid (status: $($sig.Status), message: $($sig.StatusMessage))."
    }
    if ($sig.SignerCertificate.Subject -notmatch 'Simon Tatham') {
        throw "MSI is signed but not by Simon Tatham. Subject: $($sig.SignerCertificate.Subject)"
    }
    Write-Host "MSI signature OK."

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

    # 0 = success, 3010 = success but reboot required. Anything else is a real failure.
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        throw "msiexec returned $($proc.ExitCode). See MSI log: $msiLog"
    }

    # --- Verify ---
    if (-not (Test-Path -Path $ExpectedExe)) {
        throw "PuTTY not found at $ExpectedExe after install. See MSI log: $msiLog"
    }
    $ver = (Get-Item $ExpectedExe).VersionInfo.ProductVersion
    Write-Host "[SUCCESS] PuTTY installed. Version: $ver"
    if ($proc.ExitCode -eq 3010) {
        Write-Host "Note: msiexec returned 3010 (reboot required to complete install)."
    }
} catch {
    Write-Host "[FAILURE] $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    $exitCode = 1
} finally {
    # Cleanup the downloaded MSI on any path that touched it.
    if (Test-Path $installer) {
        Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
    }
    Write-Host "putty-install.ps1 completed (exit $exitCode)"
    if ($transcriptStarted) { Stop-Transcript }
}

exit $exitCode
