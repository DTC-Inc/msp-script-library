## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## This script is 100% NON-INTERACTIVE - it hard-fails if $env:RMM is not "1".
## $env:RMM                        - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode. REQUIRED.
## $env:Description                - Ticket # or initials for audit trail
## $env:RMMScriptPath              - Optional log directory base provided by the RMM
## $env:IossUrl                    - URL to IOSS_v3.2.zip. Empty = skip IOSS phase.
## $env:CdrEliteUrl                - URL to CDRElite5_16.zip (patch MSI ships inside it). Empty = skip legacy filter stack.
## $env:DigitalIntegrationUrl      - URL to Digital-Integrations-64bitOS.zip. Empty = skip.
## $env:DigitalIntegrationRegFiles - Comma-separated .reg filenames to import (default: "Schick_Sensor_Integration.reg")
## $env:MsxmlUrl                   - URL to MSXML_4.0.zip. Only used if msxml4.dll is not already present.
## $env:DisableCoreIsolation       - "1" (default) disables HVCI/Core Isolation per Patterson Answer 40785; "0" to leave as-is
## $env:CdrEliteArgs               - Silent switches for CDR Elite Setup.exe (e.g. /S /v/qn /v/norestart)
## $env:SkipVersionCheck           - "1" to bypass the Eaglesoft >= 24.20 version gate (default "0")
## $env:ForceReinstall             - "1" to bypass idempotency checks and rerun all phases

$ScriptLogName = "eaglesoft-schick-ioss-install.log"

# --- Relaunch in 64-bit PowerShell if running under WOW64 -----------------
if ($env:PROCESSOR_ARCHITEW6432 -eq "AMD64") {
    Write-Host "Relaunching in 64-bit PowerShell..."
    & "$env:WINDIR\sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path
    exit $LASTEXITCODE
}

# --- Default optional RMM environment variables --------------------------
if ([string]::IsNullOrEmpty($env:DisableCoreIsolation))       { $env:DisableCoreIsolation = "1" }
if ([string]::IsNullOrEmpty($env:ForceReinstall))              { $env:ForceReinstall = "0" }
if ([string]::IsNullOrEmpty($env:SkipVersionCheck))            { $env:SkipVersionCheck = "0" }
if ([string]::IsNullOrEmpty($env:DigitalIntegrationRegFiles)) { $env:DigitalIntegrationRegFiles = "Schick_Sensor_Integration.reg" }

# --- Input handling: non-interactive only --------------------------------
# This script is designed for RMM execution exclusively. For manual runs,
# set the required environment variables ($env:RMM="1", $env:IossUrl, etc.) first.
if ($env:RMM -ne "1") {
    Write-Host "ERROR: This script is non-interactive and requires RMM mode. Set `$env:RMM='1' and required variables before running manually."
    exit 1
}
if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
    $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"
}
if ([string]::IsNullOrEmpty($env:Description)) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $env:Description = "No Description"
}

# --- Log rotation (runaway protection: cap transcript growth at ~10MB) ---
$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 10MB)) {
    Move-Item -Path $LogPath -Destination "$LogPath.old" -Force
}

# --- Script logic --------------------------------------------------------
Start-Transcript -Path $LogPath -Append

Write-Host "Description: $env:Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $env:RMM"

$exitCode = 0
$rebootRequired = $false
$sharedFilesPath = "${env:ProgramFiles(x86)}\Schick Technologies\Shared Files"
$iossInstallPath = "$env:ProgramFiles\Sirona\Intraoral Sensors"
$patchedDllVersion = "5.15.1877.10093"
$tempRoot = "$env:TEMP\SchickIossInstall"
$minEaglesoftVersion = [version]"24.20"
$downloadTimeoutSec = 1800   # 30 min per component download
$installTimeoutSec = 1800    # 30 min for large installers (CDR Elite, IOSS)
$smallTimeoutSec = 900       # 15 min for MSIs/redists

function Invoke-ProcessWithTimeout {
    # Runaway protection: launches a process, waits up to TimeoutSec, kills it on timeout.
    # Returns the exit code, or 9999 if the process was killed for exceeding the timeout.
    param([string]$PhaseName, [string]$FilePath, [string]$Arguments, [int]$TimeoutSec)
    Write-Host "[$PhaseName] Running: $FilePath $Arguments (timeout ${TimeoutSec}s)"
    if ([string]::IsNullOrWhiteSpace($Arguments)) {
        $p = Start-Process -FilePath $FilePath -PassThru
    } else {
        $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru
    }
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        Write-Host "[$PhaseName] TIMEOUT after ${TimeoutSec}s - killing process $($p.Id) ($FilePath)."
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { Write-Host "[$PhaseName] Kill failed: $($_.Exception.Message)" }
        return 9999
    }
    Write-Host "[$PhaseName] Exit code: $($p.ExitCode)"
    return $p.ExitCode
}

function Install-Msi {
    param([string]$PhaseName, [string]$MsiPath, [int]$TimeoutSec = 900)
    return Invoke-ProcessWithTimeout -PhaseName $PhaseName -FilePath "msiexec.exe" -Arguments "/i `"$MsiPath`" /qn /norestart" -TimeoutSec $TimeoutSec
}

function Get-Component {
    # Downloads a component zip (with timeout) and extracts it. Returns the extraction path or $null if no URL set.
    param([string]$Name, [string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    $zipFile = Join-Path $tempRoot "$Name.zip"
    $extractPath = Join-Path $tempRoot $Name
    Write-Host "[$Name] Downloading: $Url (timeout ${downloadTimeoutSec}s)"
    $prevProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $zipFile -TimeoutSec $downloadTimeoutSec -UseBasicParsing
    } finally {
        $ProgressPreference = $prevProgress
    }
    if (-not (Test-Path $zipFile)) { throw "[$Name] Download failed." }
    Write-Host "[$Name] Downloaded $([math]::Round((Get-Item $zipFile).Length / 1MB, 1)) MB."
    Unblock-File -Path $zipFile
    Expand-Archive -Path $zipFile -DestinationPath $extractPath -Force
    Get-ChildItem -Path $extractPath -Recurse -File | Unblock-File
    return $extractPath
}

try {
    # --- Eaglesoft version gate ---
    # IOSS + the Shared Files strip are only correct for Eaglesoft 24.20+. Running this on an
    # older ES install would remove the legacy CDR driver stack that version still depends on.
    # Note: DisplayName is "Patterson Eaglesoft"; multiple uninstall entries can exist - use the highest parseable version.
    $esEntries = Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
                                  "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'Eaglesoft' }
    $esVersion = $null
    foreach ($e in $esEntries) {
        Write-Host "Detected: $($e.DisplayName) $($e.DisplayVersion)"
        $v = $null
        if ([version]::TryParse($e.DisplayVersion, [ref]$v)) {
            if (-not $esVersion -or $v -gt $esVersion) { $esVersion = $v }
        } else {
            Write-Host "WARNING: Unparseable Eaglesoft version string '$($e.DisplayVersion)'."
        }
    }
    if ($env:SkipVersionCheck -ne "1") {
        if (-not $esVersion) {
            throw "Eaglesoft not detected (or version unparseable) on this machine. This script targets Eaglesoft 24.20+ workstations. Set SkipVersionCheck=1 to override."
        }
        if ($esVersion -lt $minEaglesoftVersion) {
            throw "Eaglesoft $esVersion detected - below $minEaglesoftVersion. IOSS does not apply and the Shared Files cleanup would break the legacy driver stack this version requires. Upgrade Eaglesoft first, or set SkipVersionCheck=1 to override."
        }
        Write-Host "Eaglesoft version gate passed: $esVersion >= $minEaglesoftVersion"
    } else {
        Write-Host "SkipVersionCheck=1 - version gate bypassed."
    }

    # --- Idempotency check ---
    $iossService = Get-Service | Where-Object { $_.DisplayName -like "*Intraoral Sensor*" } | Select-Object -First 1
    $dll = Get-Item "$sharedFilesPath\CDRImageProcess.dll" -ErrorAction SilentlyContinue
    $dllOk = $dll -and ($dll.VersionInfo.FileVersion -eq $patchedDllVersion)
    $legacyRequested = -not [string]::IsNullOrWhiteSpace($env:CdrEliteUrl)
    $iossRequested = -not [string]::IsNullOrWhiteSpace($env:IossUrl)
    if ($env:ForceReinstall -ne "1" -and
        ((-not $iossRequested) -or $iossService) -and
        ((-not $legacyRequested) -or $dllOk)) {
        Write-Host "All requested components already present. Nothing to do."
        if ($iossService) { Write-Host "IOSS service: '$($iossService.DisplayName)' ($($iossService.Status))" }
        if ($dllOk) { Write-Host "CDRImageProcess.dll at $patchedDllVersion." }
        Stop-Transcript
        exit 0
    }

    # Fail fast: legacy stack requires the CDR Elite Setup.exe silent switch
    if ($legacyRequested -and (-not $dllOk) -and [string]::IsNullOrWhiteSpace($env:CdrEliteArgs)) {
        throw "CdrEliteArgs not set. CDR Elite Setup.exe cannot run silently without switches - aborting before any changes are made."
    }

    # --- Kill blocking processes (Patterson Answer 44313) ---
    Get-Process AutoDetectServer -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "Stopping AutoDetectServer.exe (PID $($_.Id))"
        Stop-Process -Id $_.Id -Force
    }
    Get-Process Eaglesoft -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "WARNING: Eaglesoft.exe running (PID $($_.Id)) - stopping it for install."
        Stop-Process -Id $_.Id -Force
    }

    # --- Core Isolation / HVCI (Patterson Answer 40785) ---
    if ($env:DisableCoreIsolation -eq "1") {
        $hvciKey = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
        $current = (Get-ItemProperty -Path $hvciKey -Name Enabled -ErrorAction SilentlyContinue).Enabled
        if ($current -eq 1) {
            Write-Host "Core Isolation (HVCI) enabled. Disabling per vendor requirement."
            Set-ItemProperty -Path $hvciKey -Name Enabled -Value 0 -Type DWord
            $rebootRequired = $true
        } else {
            Write-Host "Core Isolation (HVCI) already disabled or not configured (value: $current)."
        }
    }

    # --- Prep temp + TLS ---
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    # === Phase 1: Digital Integration (Patterson Answer 18352) ===
    # Package contains .reg files for 14 vendors - import ONLY those named in DigitalIntegrationRegFiles.
    $diPath = Get-Component -Name "DigitalIntegration" -Url $env:DigitalIntegrationUrl
    if ($diPath) {
        $wantedRegs = $env:DigitalIntegrationRegFiles -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        foreach ($wanted in $wantedRegs) {
            $reg = Get-ChildItem -Path $diPath -Filter $wanted -Recurse | Select-Object -First 1
            if ($reg) {
                $rc = Invoke-ProcessWithTimeout -PhaseName "DigitalIntegration" -FilePath "reg.exe" -Arguments "import `"$($reg.FullName)`"" -TimeoutSec 120
                if ($rc -ne 0) {
                    Write-Host "[DigitalIntegration] WARNING: reg import exit $rc for $($reg.Name)"
                    $exitCode = 1
                }
            } else {
                Write-Host "[DigitalIntegration] ERROR: '$wanted' not found in package."
                $exitCode = 1
            }
        }
        $rebootRequired = $true  # Patterson: run registry integration files, then reboot
    } elseif ($iossRequested) {
        Write-Host "DigitalIntegrationUrl not set - skipping. Sensor options will not appear in ES preferences unless already integrated."
    }

    # === Phase 2: MSXML 4.0 (must precede CDRElite patch) ===
    if (Test-Path "$env:WINDIR\SysWOW64\msxml4.dll") {
        Write-Host "[MSXML] msxml4.dll already present - skipping."
    } else {
        $msxmlPath = Get-Component -Name "MSXML" -Url $env:MsxmlUrl
        if ($msxmlPath) {
            $installer = Get-ChildItem -Path $msxmlPath -Include *.msi -Recurse | Select-Object -First 1
            if ($installer) {
                $rc = Install-Msi -PhaseName "MSXML" -MsiPath $installer.FullName -TimeoutSec $smallTimeoutSec
            } else {
                $installer = Get-ChildItem -Path $msxmlPath -Include *.exe -Recurse | Select-Object -First 1
                if (-not $installer) { throw "[MSXML] No installer found in package." }
                $rc = Invoke-ProcessWithTimeout -PhaseName "MSXML" -FilePath $installer.FullName -Arguments "/quiet /norestart" -TimeoutSec $smallTimeoutSec
            }
            if ($rc -ne 0 -and $rc -ne 3010) { throw "MSXML phase failed (exit $rc)." }
            if (Test-Path "$env:WINDIR\SysWOW64\msxml4.dll") {
                Write-Host "[MSXML] msxml4.dll confirmed present."
            } else {
                Write-Host "[MSXML] WARNING: installer exited $rc but msxml4.dll still not found."
                $exitCode = 1
            }
        } elseif ($legacyRequested) {
            Write-Host "[MSXML] WARNING: msxml4.dll not present and MsxmlUrl not set - CDRElite patch must be re-run after MSXML is installed."
        }
    }

    # === Phase 3-5: CDR Elite 5.16 install, Shared Files strip, patch ===
    if ($legacyRequested -and (-not $dllOk -or $env:ForceReinstall -eq "1")) {
        $cdrPath = Get-Component -Name "CDRElite516" -Url $env:CdrEliteUrl
        $cdrSetup = Get-ChildItem -Path $cdrPath -Filter "CDR Elite Setup.exe" -Recurse | Select-Object -First 1
        if (-not $cdrSetup) { throw "CDR Elite Setup.exe not found in CDRElite package." }
        $rc = Invoke-ProcessWithTimeout -PhaseName "CDRElite516" -FilePath $cdrSetup.FullName -Arguments $env:CdrEliteArgs -TimeoutSec $installTimeoutSec
        if ($rc -ne 0 -and $rc -ne 3010) { throw "CDRElite516 phase failed (exit $rc)." }

        if (-not (Test-Path $sharedFilesPath)) {
            throw "Shared Files folder not found at $sharedFilesPath after CDRElite install."
        }
        Write-Host "Cleaning $sharedFilesPath - preserving CDRData.dll and OMEGADLL.dll only."
        Get-ChildItem -Path $sharedFilesPath -Force |
            Where-Object { $_.Name -notin @("CDRData.dll", "OMEGADLL.dll") } |
            Remove-Item -Recurse -Force

        $patchMsi = Get-ChildItem -Path $cdrPath -Filter "CDRPatch*.msi" -Recurse | Select-Object -First 1
        if (-not $patchMsi) { throw "CDRElite patch MSI (CDRPatch*.msi) not found in package." }
        $rc = Install-Msi -PhaseName "CDRElitePatch" -MsiPath $patchMsi.FullName -TimeoutSec $smallTimeoutSec
        if ($rc -ne 0 -and $rc -ne 3010) { throw "CDRElitePatch failed (msiexec exit $rc)." }

        $dll = Get-Item "$sharedFilesPath\CDRImageProcess.dll" -ErrorAction SilentlyContinue
        if ($dll -and $dll.VersionInfo.FileVersion -eq $patchedDllVersion) {
            Write-Host "CDRImageProcess.dll confirmed at $patchedDllVersion."
        } else {
            Write-Host "WARNING: CDRImageProcess.dll missing or wrong version ($(if ($dll) { $dll.VersionInfo.FileVersion } else { 'not present' })). Legacy image filters may not render."
            $exitCode = 1
        }
        # Sanity check the preserved DLLs (Patterson: CDRData.dll and OMEGADLL.dll required for pre-24.20 image filters)
        foreach ($required in "CDRData.dll", "OMEGADLL.dll") {
            if (-not (Test-Path "$sharedFilesPath\$required")) {
                Write-Host "WARNING: $required not present in Shared Files. Restore from CDRData-OMEGA.zip if legacy filters fail."
                $exitCode = 1
            }
        }
    } elseif ($legacyRequested) {
        Write-Host "CDRImageProcess.dll already at $patchedDllVersion - skipping legacy filter stack."
    }

    # === Phase 6: IOSS (Intraoral Sensor Software v3.2) ===
    if ($iossRequested -and (-not $iossService -or $env:ForceReinstall -eq "1")) {
        $iossPath = Get-Component -Name "IOSS" -Url $env:IossUrl

        # Prerequisite: VC++ 2019 x64 redistributable (ships in the package)
        $vcRedist = Get-ChildItem -Path $iossPath -Filter "VC_redist.x64.exe" -Recurse | Select-Object -First 1
        if ($vcRedist) {
            $rc = Invoke-ProcessWithTimeout -PhaseName "IOSS-VCRedist" -FilePath $vcRedist.FullName -Arguments "/install /quiet /norestart" -TimeoutSec $smallTimeoutSec
            # 0 = ok, 3010 = ok+reboot, 1638 = newer version already installed
            if ($rc -notin 0, 3010, 1638) { throw "VC++ redistributable install failed (exit $rc)." }
            if ($rc -eq 3010) { $rebootRequired = $true }
        }

        # Prerequisite check: .NET Framework 4.8 (Release >= 528040). Built into Win10 1903+.
        $ndpRelease = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -Name Release -ErrorAction SilentlyContinue).Release
        if (-not $ndpRelease -or $ndpRelease -lt 528040) {
            Write-Host "[IOSS] WARNING: .NET Framework 4.8 not detected (Release: $ndpRelease). IOSS may fail - install .NET 4.8 and rerun."
            $exitCode = 1
        }

        # Main install: en-us MSI specifically (package contains per-language MSIs; WiFi Config Utility MSI deliberately excluded)
        $iossMsi = Get-ChildItem -Path $iossPath -Filter "Intraoral Sensor Software.msi" -Recurse |
            Where-Object { $_.FullName -match '\\en-us\\' } | Select-Object -First 1
        if (-not $iossMsi) { throw "[IOSS] en-us 'Intraoral Sensor Software.msi' not found in package." }
        $rc = Install-Msi -PhaseName "IOSS" -MsiPath $iossMsi.FullName -TimeoutSec $installTimeoutSec
        if ($rc -ne 0 -and $rc -ne 3010) { throw "IOSS phase failed (exit $rc)." }
        if ($rc -eq 3010) { $rebootRequired = $true }
    } elseif ($iossRequested) {
        Write-Host "IOSS service already present - skipping IOSS install."
    }

    # --- Verification ---
    if ($iossRequested) {
        if (-not (Test-Path $iossInstallPath)) {
            Write-Host "WARNING: IOSS install path not found at $iossInstallPath"
            $exitCode = 1
        }
        $iossService = Get-Service | Where-Object { $_.DisplayName -like "*Intraoral Sensor*" } | Select-Object -First 1
        if ($iossService) {
            Write-Host "IOSS service: '$($iossService.DisplayName)' - status: $($iossService.Status)"
            # Patterson Answer 44313: Automatic (Delayed Start) so prerequisites load before the service on boot
            Write-Host "Setting IOSS service startup type to Automatic (Delayed Start)."
            sc.exe config $iossService.Name start= delayed-auto | Out-Null
            if ($iossService.Status -ne "Running" -and -not $rebootRequired) {
                Start-Service -Name $iossService.Name -ErrorAction SilentlyContinue
                Write-Host "Post-start status: $((Get-Service -Name $iossService.Name).Status)"
            }
        } else {
            Write-Host "ERROR: No Intraoral Sensor service found after install."
            $exitCode = 1
        }
    }

    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    if ($rebootRequired) {
        Write-Host "REBOOT REQUIRED: HVCI change, registry integration, and/or installer requested restart. Sensor will not function until reboot."
    }
    Write-Host "Completed with exit code $exitCode. RebootRequired: $rebootRequired"
}
catch {
    Write-Host "CRITICAL: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    $exitCode = 1
}

Stop-Transcript
exit $exitCode