<#
.SYNOPSIS
 Detects and silently uninstalls GoTo / LogMeIn Resolve Unattended.

.DESCRIPTION
 - Identifies Resolve Unattended via running processes, services, and uninstall registry keys
 - Executes the vendor uninstall string with silent switches where possible (MSI or EXE)
 - Falls back to removing known install folders and disabling related services
 - Logs actions to a timestamped log file

.NOTES
 Run as Administrator. Tested on Windows 10/11. No reboots are forced.
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'
$LogDir = Join-Path $env:SystemRoot 'Temp'
$Log    = Join-Path $LogDir ("Remove-GoToResolve-Unattended_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')

function Write-Log {
    param([string]$Message,[string]$Level='INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 's'), $Level.ToUpper(), $Message
    $line | Tee-Object -FilePath $Log -Append
}

Write-Log "Starting GoTo/LogMeIn Resolve Unattended detection & removal"

# --- Indicators seen in the incident & common install paths ---
$KnownProcessNames = @(
    'GoToResolveTerminal.exe',
    'GoTo.Resolve.Antivirus.App.exe',
    'GoTo.Resolve.PatchManagement.Client.exe'
)

# Base folders plus known instance folder
$KnownFolders = @(
    "$env:ProgramFiles\GoTo Resolve Unattended",
    "$env:ProgramFiles(x86)\GoTo Resolve Unattended",
    "C:\Program Files (x86)\GoTo Resolve Unattended\5674438124342114066"
)

# Explicitly known service names (can extend this array as needed)
$KnownServiceNames = @(
    'GoToResolve_5674438124342114066'
)

# Explicit uninstall key path seen in your environment
$ExplicitUninstallKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\GoTo Resolve Unattended 5674438124342114066'

# --- Helper: Stop a process safely ---
function Stop-ProcessSafe {
    param([string]$Name)
    try {
        $procs = Get-Process -Name ($Name -replace '\.exe$','') -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            Write-Log "Stopping process $($p.ProcessName) (PID $($p.Id))"
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    } catch { Write-Log "Process stop error for ${Name}: $($_.Exception.Message)" 'WARN' }
}

# --- Helper: Stop & disable services whose ImagePath points into known folders or match known service names ---
function Disable-RelatedServices {

    # Services installed under known folders (ImagePath)
    $svcCandidates = Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $pn = [string]$_.PathName
        $pn -and ($KnownFolders | Where-Object { $pn -like ("*" + $_ + "*") }).Count -gt 0
    }

    foreach ($svc in $svcCandidates) {
        Write-Log "Disabling folder-matched service $($svc.Name) ($($svc.DisplayName))"
        try {
            if ($svc.State -eq 'Running') {
                Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
            }
            Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction SilentlyContinue
        } catch {
            Write-Log "Service change error for $($svc.Name): $($_.Exception.Message)" 'WARN'
        }
    }

    # Explicitly known service names (e.g., GoToResolve_5674438124342114066)
    foreach ($svcName in $KnownServiceNames) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($null -ne $svc) {
                Write-Log "Stopping & disabling explicit service $($svc.Name) ($($svc.DisplayName))"
                if ($svc.Status -eq 'Running') {
                    Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
                }
                Set-Service -Name $svc.Name -StartupType Disabled -ErrorAction SilentlyContinue

                # Optionally remove from SCM as well
                sc.exe delete $svcName | Out-Null
                Write-Log "Service $svcName deleted from Service Control Manager"
            }
        } catch {
            Write-Log "Service change error for ${svcName}: $($_.Exception.Message)" 'WARN'
        }
    }
}

# --- Helper: Execute an uninstall command silently when possible ---
function Invoke-UninstallString {
    param([string]$UninstallString)

    if (-not $UninstallString) { return $false }

    $cmd = $UninstallString

    # Normalize quotes and split into file + args
    if ($cmd.StartsWith('"')) {
        $exe = $cmd -replace '^"([^"]+)".*$', '$1'
        $args = $cmd.Substring($exe.Length + 2)  # skip opening quote and following quote
        $args = $args.TrimStart('"').Trim()
    } else {
        $parts = $cmd.Split(' ',2)
        $exe = $parts[0]
        $args = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    }

    # If MSI, force quiet remove
    if ($exe -match '(?i)msiexec\.exe') {
        # Try to extract product code if present; otherwise convert /I to /X
        if ($args -match '(?i)\{[0-9A-F-]{36}\}') {
            $product = $Matches[0]
            $finalArgs = "/x $product /qn /norestart"
        } else {
            $finalArgs = $args -replace '(?i)\s?/i\b',' /x' -replace '(?i)\s?/quiet\b','' -replace '(?i)\s?/qn\b',''
            $finalArgs = ($finalArgs + ' /qn /norestart').Trim()
        }
        Write-Log "Running MSI uninstall: msiexec.exe $finalArgs"
        $p = Start-Process msiexec.exe -ArgumentList $finalArgs -PassThru -Wait -WindowStyle Hidden
        return ($p.ExitCode -eq 0)
    }

    # For EXE uninstallers (e.g. GoToResolveUnattendedRemover.exe), append common silent flags if not present
    $silentFlags = @('/S','/s','/quiet','/qn','/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
    if (-not ($silentFlags | Where-Object { $args -match [regex]::Escape($_) })) {
        $args = ($args + ' /S /VERYSILENT /SUPPRESSMSGBOXES /NORESTART').Trim()
    }

    Write-Log "Running EXE uninstall: `"$exe`" $args"
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $args -PassThru -Wait -WindowStyle Hidden
        return ($p.ExitCode -eq 0)
    } catch {
        Write-Log "Failed to start uninstall command: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

# --- 1) Stop known processes ---
foreach ($name in $KnownProcessNames) {
    Stop-ProcessSafe -Name $name
}

# --- 2) Disable any related services (path under known folders + explicit names) ---
Disable-RelatedServices

# --- 3) Locate uninstall entries ---
$UninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

$Targets = @()
foreach ($root in $UninstallRoots) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root | ForEach-Object {
        $keyPath = $_.PsPath
        $p = Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue
        if (-not $p) { return }
        $displayName = [string]$p.DisplayName
        $installLoc  = [string]$p.InstallLocation
        $uninst      = [string]$p.UninstallString

        # Match GoTo *or* LogMeIn Resolve Unattended, plus fallback "Resolve Unattended" contains
        $matchesName = (
            $displayName -match '(?i)(GoTo|LogMeIn)\s+Resolve\s+Unattended' -or
            $displayName -match '(?i)Resolve\s+Unattended'
        )

        $matchesPath = $false
        if ($installLoc) {
            $matchesPath = $KnownFolders |
                Where-Object { $installLoc -like ("*" + $_ + "*") } |
                ForEach-Object { $true } |
                Select-Object -First 1
        }

        if ($matchesName -or $matchesPath) {
            $Targets += [PSCustomObject]@{
                DisplayName     = $displayName
                InstallLocation = $installLoc
                UninstallString = $uninst
                KeyPath         = $keyPath
            }
        }
    }
}

# Explicitly add the known key if it exists and wasn't already captured
if (Test-Path $ExplicitUninstallKey) {
    $p = Get-ItemProperty -Path $ExplicitUninstallKey -ErrorAction SilentlyContinue
    if ($p) {
        $already = $Targets | Where-Object { $_.KeyPath -eq $ExplicitUninstallKey }
        if (-not $already) {
            $Targets += [PSCustomObject]@{
                DisplayName     = [string]$p.DisplayName
                InstallLocation = [string]$p.InstallLocation
                UninstallString = [string]$p.UninstallString
                KeyPath         = $ExplicitUninstallKey
            }
        }
    }
}

if ($Targets.Count -eq 0) {
    Write-Log "No uninstall registry entries found for Resolve Unattended. Will attempt folder cleanup only."
} else {
    $Targets | ForEach-Object {
        Write-Log "Attempting uninstall for: $($_.DisplayName)"
        if (-not (Invoke-UninstallString -UninstallString $_.UninstallString)) {
            Write-Log "Primary uninstall failed or returned non-zero. Will continue with cleanup." 'WARN'
        }
    }
}

# --- 4) Extra safety: remove known install folders ---
foreach ($folder in $KnownFolders) {
    if (Test-Path $folder) {
        try {
            Write-Log "Removing folder: $folder"
            # Unlock handles by retrying removal
            for ($i=0; $i -lt 3; $i++) {
                try {
                    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop
                    break
                } catch {
                    Start-Sleep -Seconds (2 + $i)
                }
            }
        } catch {
            Write-Log "Failed to remove ${folder}: $($_.Exception.Message)" 'WARN'
        }
    }
}

# --- 5) Remove scheduled tasks that point to GoTo Resolve binaries ---
try {
    $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue
    foreach ($t in $tasks) {
        $hit = $false
        foreach ($a in $t.Actions) {
            if ($a.Execute -and ($KnownFolders | Where-Object { ($a.Execute + ' ' + $a.Arguments) -like ("*" + $_ + "*") }).Count -gt 0) {
                $hit = $true
                break
            }
        }
        if ($hit) {
            Write-Log "Deleting scheduled task: $($t.TaskName)"
            try {
                Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction SilentlyContinue
            } catch {}
        }
    }
} catch {
    Write-Log "Scheduled task enumeration failed: $($_.Exception.Message)" 'WARN'
}

Write-Log "Resolve Unattended removal routine completed"
Write-Log "Log saved to: $Log"
