## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM           - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description   - Ticket # or initials for audit trail
## $env:RMMScriptPath - Optional log directory base provided by the RMM

# Duplicate SID Issue - Temporary Fix (FeatureManagement Override)
#
# Disables the Windows feature rollout (FeatureManagement override ID 1517186191) that
# triggers the duplicate-SID behavior by writing the override to 0 (off) under
# HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides.
#
# This is a TEMPORARY mitigation only. A duplicate local machine SID is still a real
# problem caused by cloning/imaging without sysprep /generalize. Use this to stop the
# immediate symptom; the permanent fix is to reimage affected machines with sysprep.
# Detect affected machines with msft-windows-sid-detect-duplicates.ps1 / msft-windows-sid-report.ps1.
#
# Equivalent one-liner:
#   reg add "HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides" /v 1517186191 /t REG_DWORD /d 0 /f
#
# Context: SYSTEM (requires administrative rights to write HKLM).
# Note: HKLM\SYSTEM\CurrentControlSet is NOT under WOW6432 registry redirection, so a
#       32-bit RMM PowerShell host writes the correct key without a sysnative relaunch.
#
# Exit Codes:
# 0 = Success, override applied and verified
# 1 = Error writing or verifying the registry value

$ScriptLogName = "msft-windows-sid-duplicate-temp-fix.log"

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

# --- Input handling: RMM vs interactive ----------------------------------

if ($env:RMM -ne "1") {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        $env:Description = Read-Host "Please enter the ticket # and/or your initials for audit trail"
        if ($env:Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"
} else {
    # Prefer RMMScriptPath when the RMM provides one, otherwise fall back to WINDIR.
    if (-not [string]::IsNullOrWhiteSpace($env:RMMScriptPath)) {
        $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$env:WINDIR\logs\$ScriptLogName"
    }

    if ([string]::IsNullOrWhiteSpace($env:Description)) {
        Write-Host "Description is empty/null. This was most likely run automatically from the RMM and no information was passed."
        $env:Description = "No Description"
    }
}

# Emit progress to stdout BEFORE the transcript starts, so even if Start-Transcript
# fails (no log dir, locked file, etc.) the RMM still captures something useful.
Write-Host "msft-windows-sid-duplicate-temp-fix.ps1 starting"
Write-Host "Description  : $env:Description"
Write-Host "RMM          : $env:RMM"
Write-Host "Computer     : $env:COMPUTERNAME"
Write-Host "User context : $env:USERNAME"
Write-Host "PowerShell   : $($PSVersionTable.PSVersion) ($([IntPtr]::Size * 8)-bit)"

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
Write-Host ""

# --- Script logic --------------------------------------------------------
# Main body wrapped in try/catch/finally so any unhandled throw still stops the
# transcript cleanly and returns a real exit code to the RMM.

$exitCode = 0

# Define the registry path, value name, and data
$registryPath = "HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides"
$valueName    = "1517186191"
$valueData    = 0

try {
    # Create the key (and any missing parents) if it does not exist
    if (-not (Test-Path $registryPath)) {
        Write-Host "[INFO] Registry key not found. Creating: $registryPath"
        New-Item -Path $registryPath -Force | Out-Null
    }

    # Set the override value to 0 (feature off)
    Set-ItemProperty -Path $registryPath -Name $valueName -Value $valueData -Type DWord -Force
    Write-Host "[INFO] Set '$valueName' = $valueData (DWORD) at $registryPath"

    # Verify the write
    $readBack = (Get-ItemProperty -Path $registryPath -Name $valueName -ErrorAction Stop).$valueName
    if ($readBack -eq $valueData) {
        Write-Host "[SUCCESS] Verified '$valueName' = $readBack. FeatureManagement override applied."
        Write-Host "[NOTE] This is a TEMPORARY mitigation. Permanent fix is to reimage affected machines with sysprep /generalize."
    } else {
        Write-Host "[FAILURE] Verification mismatch. Expected $valueData but read $readBack."
        $exitCode = 1
    }
} catch {
    Write-Host "[FAILURE] Failed to apply registry override: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    $exitCode = 1
} finally {
    if ($transcriptStarted) { Stop-Transcript }
}

exit $exitCode
