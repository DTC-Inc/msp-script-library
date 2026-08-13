# Enable TLS1.2 and TLS1.3
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType] 'Tls12'

$RMM = 1
$ScriptURL = $env:scripturl
$RMMScriptPath = $env:PROGRAMDATA + "\NinjaRMMAgent\scripting"
$Description = $env:description
$DownloadURL=$env:downloadurl
$SaveFile=$env:savefile

<#
.SYNOPSIS
    Convergent Veeam B&R upgrade to 13.0.2.29 with dual-runtime Veeam
    PowerShell, disk reclamation, agent-blocker remediation,
    install-window watchdog, component upgrade, and post-reboot
    validation.

.DESCRIPTION
    NEW IN v4.2 - all four from the 2026-08-11 fleet wave:

      3010 IS NOT A FAILURE. DTCBSURE-4947 returned exit 3010 with the
      build unchanged, and the installer's own result document said why:
        event id="012" "Reboot is required to finalize prerequisites
        installation." / Microsoft Visual C++ 2017-2026 Redistributable
      3010 is ERROR_SUCCESS_REBOOT_REQUIRED. Setup installed a
      prerequisite and stopped deliberately BEFORE the product install.
      v4.1 threw FATAL. The correct action is reboot and re-run - the hop
      completes on the next pass. (The result XML went to stderr, not to
      the setup temp folder, which is why "No UnattendedInstallation
      Result_*.xml found" appeared alongside it.)

      SYSTEM-DRIVE SPACE. Veeam setup needs ~29.3 GB on C: for MSI
      extraction and component installs NO MATTER where the ISO is
      staged (event id=105 on DTCBSURE-4244 and -4257). v4.1 moved the
      FreeSpace gate to the staging volume and lost the C: check
      entirely. Both gates now exist.

      ENDPOINT REBOOT BLOCKS AGENT UPGRADES. An online agent with
      RebootRequired=True on the endpoint cannot finish upgrading until
      that workstation reboots - the in-script upgrade simply timed out
      after 600 s (DTCBSURE-4951, -4554, -4207). It now halts
      immediately, naming the machine, instead of burning the wait.

      VALIDATION THRESHOLDS. A box that misses one hourly backup cycle
      during its upgrade reboot tripped the restore-point checks
      (DTCBSURE-4178: newest point 5 h back; -4937: 8 points fewer) and
      was permanently held. Tolerance is now 26 h backwards and a 10%
      count drop, which still catches the real cases: DTCBSURE-4478
      (newest point 4.5 MONTHS backwards) and -4480 (-85 of 265 points).

    FROM v4.1:
      Veeam log-tree pruning (C:\ProgramData\Veeam\Backup was 58.47 GB /
      12,522 files on 4911, oldest 2024-04-11 - the real cause of the
      FreeSpace halts, hidden because ProgramData is hidden); component
      upgrade via Update-VBRServerComponent; 9392 listener checked with
      netstat because Get-NetTCPConnection -State Listen returns nothing
      intermittently on a busy box (4911: netstat showed LISTENING while
      the cmdlet came back empty amid ~40 TIME_WAIT entries).

      VSPC IS NOT AUTOMATABLE - the v13 module exposes no
      ManagementAgent/ServiceProvider/VSPC/CloudConnect cmdlets, and
      Veeam ServiceAgent is 9.3.0.35057 identically on 12.x and 13.x, so
      it is not an agent version either. Console action, logged as such.

    FROM v4.0:
      Staging on the largest fixed volume (eight fleet boxes have
      109-117 GB C: beside a multi-TB D:); installer task launch
      verified before trusting a result (5043: stale LAPS, task never
      ran, LastTaskResult 0 read as success - Security 4625 substatus
      0xC000006A); credential pre-validated before the download;
      StopPending detected at preflight and cleared by forced reboot;
      agent-removal splat fixed (PowerShell splats from a VARIABLE only);
      log output capped by characters as well as lines; all reboots
      forced.

    Port 443: v13 installs its own web service which legitimately binds
    443 - only a NON-Veeam listener is a conflict. 17 halts became 0.

    CONFIGURATION BACKUP IS NOT A GATE (Z. Boogher). Much of the fleet
    has a broken configuration-backup job and halting those upgrades
    protected a rollback point the devices did not have. Not repairable
    by cmdlet - all four *ConfigurationBackup* cmdlets enumerated on
    both 12.2 and 13.0, neither exposes a settings-level setter, and the
    dangling GUID is stored binary. Separate workstream.

    DUAL RUNTIME - Veeam PowerShell v13 requires PowerShell 7 (.NET
    Core); NinjaOne runs 5.1. The v12 module is .NET Framework and fails
    under pwsh with "The type initializer for
    'Veeam.Backup.Common.SSslOptions' threw an exception". Runtime is
    chosen PER CALL from the installed build.

    THE INSTALL-WINDOW WATCHDOG - the installer restarts VeeamBackupSvc
    to analyse the config DB, and each service start spawns maintenance
    jobs that prevent the service stopping. The installer allows 5
    minutes then fails event id=113 and rolls back. Pre-stopping cannot
    fix it - the blocking jobs appear AFTER the restart.

    FORCE-KILLING THE SERVICE IS NOT USED - taskkill wedged this
    platform. Graceful stop only; forced reboot and retry on failure.

    NOTE FOR TECHS: the v13 console must be launched AS ADMINISTRATOR or
    it fails with "Access to the registry key ...\Plugins is denied" -
    that key grants Administrators, and a non-elevated process carries
    that as a deny-only SID under UAC.

.NOTES
    Author  : Z. Boogher
    Ticket  : HALO 1146283
    Version : 4.2
              - 3010 with unadvanced build = prerequisite reboot, not FATAL
              - SystemDriveFreeSpace gate restored (~35 GB on C:)
              - endpoint RebootRequired halts agent upgrade immediately
              - restore-point validation tolerates one missed cycle
              - (4.1) log pruning; component upgrade; netstat listener
              - (4.0) staging volume; task-launch check; credential
                pre-validation; StopPending reboot; agent splat
              - (3.9) Port443 Veeam-aware; ARP DisplayVersion logged
              - (3.8) configuration backup removed as a gate
              - (3.6) dual-runtime Veeam PowerShell
              - (3.5) partial-success handling
              - (3.3) install-window watchdog
              - (3.2) agent remediation + event-106 retry
              - (3.1) local writable install source per ISO
              - (3.0) Write-Log uses Write-Host
    Exit    : 0 = at target, validated, offsite copy verified
              2 = expected mid-state OR validation/agent/copy FAILURE
              1 = script failure

    DEPLOYMENT: Run As = SYSTEM.

    RMM variables (all $env:, no [switch]):
      downloadUrlV13, saveFileV13, sha256V13
      downloadUrlV12, saveFileV12, sha256V12
      vbrAutoUpgrade          0/1  (default 0)
      preflightOnly           0/1  (default 0 - report-only)
      staleAgentDays          int  (default 180)
      staleRestorePointDays   int  (default 60)
      veeamLogRetentionDays   int  (default 30; 0 disables log pruning)
      upgradeComponents       0/1  (default 1)
#>

#Requires -Version 5.1

# --- 64-bit relaunch. NinjaOne runs 32-bit; HKLM\SOFTWARE\Veeam is hidden
# --- under WOW64 redirection. Must precede transcript.
if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64' -and -not [Environment]::Is64BitProcess) {
    $sysNative = Join-Path $env:WINDIR 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $sysNative) {
        & $sysNative -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
        exit $LASTEXITCODE
    }
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# --- Constants ---------------------------------------------------------------
$TargetBuild        = [version]'13.0.2.29'
$GateBuild          = [version]'12.3.1.1139'    # Veeam KB4763 - the v13 floor
$Ps7RequiredBuild   = [version]'13.0.0.0'
$StagingFolderName  = 'VeeamInstall'
$script:IsoFolder   = $null
$InstallerRelPath   = 'Setup\Silent\Veeam.Silent.Install.exe'
$LogFolder          = 'C:\ProgramData\DTC\Logs\VeeamUpgrade'
$StateFile          = Join-Path $LogFolder 'upgrade-state.json'
$BaselineFile       = Join-Path $LogFolder 'baseline.json'
$CopyWatchFile      = Join-Path $LogFolder 'copy-watch.json'
$FailureActionsFile = Join-Path $LogFolder 'svc-failure-actions.json'
$DbReportFile       = Join-Path $LogFolder 'VbrDatabaseIssuesSetupReport.xml'
$SetupTempFolder    = 'C:\ProgramData\Veeam\Setup\Temp'
$DefaultVeeamLogDir = 'C:\ProgramData\Veeam\Backup'
$MinFreeGBUnstaged  = 45      # staging volume, ISO not yet present
$MinFreeGBStaged    = 25      # staging volume, ISO already there
$MinFreeGBSystem    = 35      # C: - setup needs ~29.3 GB regardless of staging
$LogRetention       = 10
$MutexName          = 'Global\DTC-VeeamUpgrade-1146283'
$RestSvcTimeoutMs   = 180000
$RebootDelaySeconds = 60
$SvcWaitAttempts    = 10
$SvcWaitSeconds     = 30
$CopyWatchHours     = 24
$SvcStartSettleSecs = 25
$SvcStopTimeoutSecs = 600
$StopPendingGraceSecs = 45
$AgentUpgradeWaitSecs = 600
$MaxInstallAttempts   = 2
$SessionTrimCount     = 500
$MaxStdoutLines       = 40
$MaxResultXmlLines    = 30
$MaxLineChars         = 300
$TaskLaunchWaitSecs   = 60
$ComponentWaitSecs    = 900
$RpBackwardsToleranceHours = 26   # one missed hourly cycle during a reboot
$RpCountTolerancePct       = 0.90 # a drop below this is more than retention

$InstallAdminUser   = 'dtcadmin'
$LapsFieldName      = 'lapsPassword'
$InstallTaskName    = 'DTC-VeeamUpgrade-1146283-Installer'

$MaintenanceVerbs = 'STARTRESYNC|STARTCHECKPOINTREMOVAL|STARTDBMAINTENANCE|STARTCATCLEANUP|STARTINFRARESCAN|STARTDISCOVER|STARTAUDITZIP|STARTHVCTPRESCAN|STARTRETENTION'

# --- RMM inputs ----------------------------------------------------------------
$DownloadUrlV13 = $env:downloadUrlV13
$SaveFileV13    = $env:saveFileV13
$Sha256V13      = $env:sha256V13
$DownloadUrlV12 = $env:downloadUrlV12
$SaveFileV12    = $env:saveFileV12
$Sha256V12      = $env:sha256V12
$AutoUpgrade    = if ($env:vbrAutoUpgrade -eq '1') { '1' } else { '0' }
$PreflightOnly  = ($env:preflightOnly -eq '1')
$UpgradeComponents = -not ($env:upgradeComponents -eq '0')
$StaleAgentDays = 180
if ($env:staleAgentDays -and [int]::TryParse($env:staleAgentDays, [ref]$null)) {
    $StaleAgentDays = [int]$env:staleAgentDays
}
$StaleRestorePointDays = 60
if ($env:staleRestorePointDays -and [int]::TryParse($env:staleRestorePointDays, [ref]$null)) {
    $StaleRestorePointDays = [int]$env:staleRestorePointDays
}
$VeeamLogRetentionDays = 30
if ($env:veeamLogRetentionDays -and [int]::TryParse($env:veeamLogRetentionDays, [ref]$null)) {
    $VeeamLogRetentionDays = [int]$env:veeamLogRetentionDays
}

# --- State ---------------------------------------------------------------------
$exitCode   = 0
$mutex      = $null
$haveMutex  = $false
$mountedIso = $null
$gates      = New-Object System.Collections.Generic.List[psobject]
$AdminPassword = $null
$script:PwshPath = $null

function Write-Log {
    # MUST be Write-Host. Write-Output puts log text on the pipeline, so lines
    # emitted inside a function whose return value is assigned get captured into
    # that value (this once made the installer exit code an array).
    param([string]$Message, [string]$Level = 'INFO')
    Write-Host ("[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
}

function Invoke-ForcedReboot {
    param([string]$Reason)
    Write-Log "REBOOTING (forced) in $RebootDelaySeconds s: $Reason" 'WARN'
    & shutdown.exe /r /f /t $RebootDelaySeconds /c "DTC Veeam upgrade HALO 1146283 - $Reason" /d p:4:1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "shutdown.exe exited $LASTEXITCODE - falling back to Restart-Computer -Force." 'WARN'
        try { Stop-Transcript | Out-Null } catch { }
        if ($script:haveMutexRef) { try { $script:haveMutexRef.ReleaseMutex() } catch { } }
        Restart-Computer -Force
    }
}

function Write-CappedLines {
    # Bounded excerpt to the activity log; full text stays on disk. NinjaOne
    # truncates long stdout, and installer stderr is UTF-16 (every character
    # space-separated) so a LINE cap alone was not enough - cap characters too.
    param([string[]]$Lines, [int]$Max, [string]$Prefix, [string]$FullPath)
    $l = @($Lines | Where-Object { $_ -and $_.Trim() } | ForEach-Object {
        $t = $_.Trim()
        if ($t.Length -gt $MaxLineChars) { $t.Substring(0, $MaxLineChars) + ' ...[truncated]' } else { $t }
    })
    if ($l.Count -le $Max) { foreach ($x in $l) { Write-Log "$Prefix$x" }; return }
    $head = [math]::Floor($Max / 2); $tail = $Max - $head
    for ($i = 0; $i -lt $head; $i++) { Write-Log "$Prefix$($l[$i])" }
    Write-Log "$Prefix... [$($l.Count - $Max) lines omitted - full text in $FullPath] ..."
    for ($i = $l.Count - $tail; $i -lt $l.Count; $i++) { Write-Log "$Prefix$($l[$i])" }
}

function Add-Gate {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    $gates.Add([pscustomobject]@{ Gate = $Name; Pass = $Pass; Detail = $Detail })
}

function Test-PortListening {
    # Get-NetTCPConnection -State Listen returns nothing intermittently on a box
    # with a large connection table - confirmed DTCBSURE-4911, where netstat
    # showed 0.0.0.0:9392 LISTENING (PID 1348) while the filtered cmdlet came
    # back empty amid ~40 TIME_WAIT entries. netstat is authoritative here.
    param([int]$Port)
    try {
        if (@(& netstat.exe -ano | Select-String ":$Port\s.*LISTENING").Count -gt 0) { return $true }
    } catch { }
    try {
        return (@(Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
                  Where-Object { $_.State -eq 'Listen' }).Count -gt 0)
    } catch { return $false }
}

function Get-PortOwner {
    param([int]$Port)
    try {
        $c = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
             Where-Object { $_.State -eq 'Listen' } | Select-Object -First 1
        if ($c) { return (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).ProcessName }
        $line = @(& netstat.exe -ano | Select-String ":$Port\s.*LISTENING") | Select-Object -First 1
        if ($line) {
            $procId = ($line.ToString().Trim() -split '\s+')[-1]
            if ($procId -match '^\d+$') { return (Get-Process -Id ([int]$procId) -ErrorAction SilentlyContinue).ProcessName }
        }
    } catch { }
    return $null
}

function Get-InstalledVbrBuild {
    $keyPath = 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication'
    if (-not (Test-Path -LiteralPath $keyPath)) { throw 'Veeam Backup & Replication is not installed (no registry key).' }
    $k = Get-ItemProperty -LiteralPath $keyPath
    if ($k.PSObject.Properties.Name -notcontains 'CorePath') { throw 'Veeam registry key has no CorePath.' }
    $core = [string]$k.CorePath
    $exe  = Join-Path $core 'Veeam.Backup.Service.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "Veeam.Backup.Service.exe not found at $core" }
    $raw = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion.Trim()
    $v = $null
    if (-not [version]::TryParse(($raw -split '\s')[0], [ref]$v)) { throw "Could not parse build string '$raw'." }
    return @{ Build = $v; CorePath = $core }
}

function Get-VbrArpVersion {
    # ARP freezes at the BASE build while patches advance the file version
    # (fleet: file 12.3.2.4165 vs ARP 12.3.2.3617 on 16 devices). Normal, but
    # logged - it was a candidate explanation for boundary-build failures,
    # since disproved on DTCBSURE-5043 where both agreed.
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    try {
        $e = Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -match '^Veeam Backup & Replication Server' } |
             Select-Object -First 1
        if ($e) { return [string]$e.DisplayVersion }
    } catch { }
    return $null
}

function Get-PwshPath {
    if ($script:PwshPath) { return $script:PwshPath }
    $c = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($c) { $script:PwshPath = $c.Source; return $script:PwshPath }
    foreach ($p in @("$env:ProgramFiles\PowerShell\7\pwsh.exe",
                     "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe")) {
        if (Test-Path -LiteralPath $p) { $script:PwshPath = $p; return $script:PwshPath }
    }
    return $null
}

function Resolve-StagingFolder {
    # Small C: (109-117 GB on eight fleet boxes) beside a multi-TB repository
    # volume. 36 GB of staging does not fit on C: at any cleanup level, so it
    # goes to the fixed volume with the most free space, at the VOLUME ROOT -
    # beside a repository, never inside one.
    $vols = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
              Sort-Object FreeSpace -Descending)
    if ($vols.Count -eq 0) { return "C:\$StagingFolderName" }
    $pick = $vols[0]
    $summary = ($vols | ForEach-Object { "$($_.DeviceID) $([math]::Round($_.FreeSpace/1GB,1))GB" }) -join ', '
    Write-Log ("Volumes: {0}. Staging on {1} (most free)." -f $summary, $pick.DeviceID)
    return (Join-Path "$($pick.DeviceID)\" $StagingFolderName)
}

function Get-AllStagingFolders {
    $out = @()
    foreach ($v in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
        $p = Join-Path "$($v.DeviceID)\" $StagingFolderName
        if (Test-Path -LiteralPath $p) { $out += $p }
    }
    return ,$out
}

function Remove-StaleInstallMedia {
    param([string]$KeepIsoName, [string]$KeepSrcFolder)
    foreach ($folder in (Get-AllStagingFolders)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $folder -Filter '*.iso' -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -eq $KeepIsoName -and $folder -eq $script:IsoFolder) { continue }
            $mb = [math]::Round($f.Length / 1MB, 0)
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $f.FullName)) {
                Write-Log ("Reclaimed stale ISO {0} ({1} MB) from {2}." -f $f.Name, $mb, $folder) 'WARN'
            }
        }
        foreach ($d in @(Get-ChildItem -LiteralPath $folder -Directory -Filter 'src*' -ErrorAction SilentlyContinue)) {
            if ($d.FullName -eq $KeepSrcFolder) { continue }
            Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $d.FullName)) { Write-Log "Reclaimed stale install source $($d.FullName)." 'WARN' }
        }
        foreach ($f in @(Get-ChildItem -LiteralPath $folder -Filter '*.partial' -File -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            Write-Log "Removed orphaned partial download $($f.FullName)." 'WARN'
        }
    }
}

function Remove-AllStagedMedia {
    foreach ($folder in (Get-AllStagingFolders)) {
        foreach ($f in @($SaveFileV13, $SaveFileV12)) {
            if (-not $f) { continue }
            $p = Join-Path $folder $f
            if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; Write-Log "Removed $p" }
        }
        Get-ChildItem -LiteralPath $folder -Directory -Filter 'src*' -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Removed local install source $($_.FullName)"
        }
    }
}

function Remove-OldVeeamLogs {
    # C:\ProgramData\Veeam\Backup was 58.47 GB / 12,522 files on DTCBSURE-4911,
    # oldest 2024-04-11 - the real cause of the FreeSpace halts, and invisible
    # to a plain directory scan because ProgramData is hidden. Active logs are
    # recent by definition, so an age filter never touches them.
    # SAFETY: folder read from Veeam's own LogDirectory value; abandoned
    # entirely if that path sits inside a backup repository.
    param([int]$RetentionDays, [string[]]$RepoPaths = @())
    if ($RetentionDays -le 0) { Write-Log 'Veeam log pruning disabled (veeamLogRetentionDays=0).'; return }

    $dir = $null
    try {
        $k = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication' -ErrorAction SilentlyContinue
        foreach ($n in @('LogDirectory','LogsDirectory')) {
            if ($k -and $k.PSObject.Properties.Name -contains $n -and $k.$n) { $dir = [string]$k.$n; break }
        }
    } catch { }
    if (-not $dir) { $dir = $DefaultVeeamLogDir }
    if (-not (Test-Path -LiteralPath $dir)) { return }

    foreach ($rp in @($RepoPaths)) {
        if ($rp -and $dir.TrimEnd('\').ToLower().StartsWith($rp.TrimEnd('\').ToLower())) {
            Write-Log "Veeam log folder '$dir' sits inside repository path '$rp' - pruning SKIPPED (backup data protection)." 'WARN'
            return
        }
    }

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $old = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Include '*.log','*.zip','*.etl' -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTime -lt $cutoff })
    if ($old.Count -eq 0) { Write-Log "Veeam logs at $dir : nothing older than $RetentionDays days."; return }

    $gb = [math]::Round((($old | Measure-Object Length -Sum).Sum) / 1GB, 2)
    $oldest = ($old | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime
    Write-Log ("Veeam log prune: {0} file(s), {1} GB, older than {2} days (oldest {3}) in {4} ..." -f $old.Count, $gb, $RetentionDays, $oldest, $dir) 'WARN'
    $removed = 0
    foreach ($f in $old) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $f.FullName)) { $removed++ }
    }
    Write-Log ("Veeam log prune complete: {0} of {1} file(s) removed (~{2} GB reclaimed)." -f $removed, $old.Count, $gb) 'WARN'
}

# =============================================================================
# VEEAM POWERSHELL - DUAL RUNTIME
# =============================================================================

function Invoke-VeeamQuery {
    param([Parameter(Mandatory)][string]$Script, [string]$Prefix = '')

    $build = $null
    try { $build = (Get-InstalledVbrBuild).Build } catch { }
    $needPwsh = ($build -and $build -ge $Ps7RequiredBuild)

    $body = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
Import-Module Veeam.Backup.PowerShell -DisableNameChecking -WarningAction SilentlyContinue -ErrorAction Stop
$Prefix
$Script
"@

    $txt = $null
    if (-not $needPwsh) {
        $out = & ([scriptblock]::Create($body))
        $txt = (@($out) | Where-Object { $_ -ne $null } | ForEach-Object { [string]$_ }) -join "`n"
    } else {
        $pw = Get-PwshPath
        if (-not $pw) {
            throw "PowerShell 7 (pwsh.exe) not found. VBR $build requires it for the Veeam PowerShell module (v13 is .NET Core)."
        }
        $tmp = Join-Path $LogFolder ("veeamq_{0}.ps1" -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $tmp -Value $body -Encoding UTF8 -Force
        try {
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $raw = & $pw -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $tmp 2>&1
            $rc  = $LASTEXITCODE
            $ErrorActionPreference = $prevEap
            $good = @($raw) | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }
            $bad  = @($raw) | Where-Object { $_ -is  [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }
            $txt  = ($good -join "`n")
            if ([string]::IsNullOrWhiteSpace($txt)) { throw "pwsh Veeam query returned no output (exit $rc). $($bad -join '; ')" }
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }

    if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
    $i = $txt.IndexOfAny([char[]]@('{', '['))
    if ($i -lt 0) { throw "Veeam query returned no JSON. Output: $txt" }
    return ($txt.Substring($i) | ConvertFrom-Json)
}

function Get-VeeamLiveState {
    $code = @'
try {
  if (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue) {
    try { Connect-VBRServer -Server localhost -ErrorAction Stop } catch { }
  }
  $jobs = @()
  foreach ($j in @(Get-VBRJob -ErrorAction Stop -WarningAction SilentlyContinue)) {
    $jobs += [ordered]@{ name=[string]$j.Name; type=[string]$j.JobType; enabled=[bool]$j.IsScheduleEnabled }
  }
  if (Get-Command Get-VBRComputerBackupJob -ErrorAction SilentlyContinue) {
    foreach ($j in @(Get-VBRComputerBackupJob -ErrorAction SilentlyContinue)) {
      $jobs += [ordered]@{ name=[string]$j.Name; type='AgentPolicy'; enabled=[bool]$j.JobEnabled }
    }
  }
  $repos = @()
  foreach ($r in @(Get-VBRBackupRepository -ErrorAction Stop)) {
    $repos += [ordered]@{ name=[string]$r.Name; type=[string]$r.Type; path=[string]$r.Path }
  }
  $objRepos = @()
  if (Get-Command Get-VBRObjectStorageRepository -ErrorAction SilentlyContinue) {
    foreach ($o in @(Get-VBRObjectStorageRepository -ErrorAction SilentlyContinue)) {
      $t = 'Unknown'
      foreach ($p in @('Type','ObjectStorageType')) { if ($o.PSObject.Properties.Name -contains $p) { $t = [string]$o.$p; break } }
      $objRepos += [ordered]@{ name=[string]$o.Name; type=$t }
    }
  }
  $s3 = 0
  if (Get-Command Get-VBRAmazonAccount -ErrorAction SilentlyContinue) {
    $s3 = @(Get-VBRAmazonAccount -ErrorAction SilentlyContinue).Count
  }
  $sessions = @()
  try {
    $sessions = @(Get-VBRBackupSession -ErrorAction SilentlyContinue |
      Sort-Object CreationTime -Descending | Select-Object -First $TrimCount |
      ForEach-Object { [ordered]@{ jobName=[string]$_.JobName; result=[string]$_.Result; createdUtc=$_.CreationTime.ToUniversalTime().ToString('o') } })
  } catch { }
  $copy = @()
  $seen = @{}
  if (Get-Command Get-VBRBackupCopyJob -ErrorAction SilentlyContinue) {
    foreach ($j in @(Get-VBRBackupCopyJob -ErrorAction SilentlyContinue)) {
      $n = [string]$j.Name
      $en = $true
      foreach ($p in @('JobEnabled','Enabled','IsEnabled')) { if ($j.PSObject.Properties.Name -contains $p) { $en = [bool]$j.$p; break } }
      $l = $sessions | Where-Object { $_.jobName -eq $n } | Select-Object -First 1
      $copy += [ordered]@{ name=$n; enabled=$en; lastResult=$(if($l){$l.result}else{'None'}); lastUtc=$(if($l){$l.createdUtc}else{$null}) }
      $seen[$n] = $true
    }
  }
  foreach ($j in @(Get-VBRJob -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where-Object { [string]$_.JobType -match 'Copy|Sync' })) {
    $n = [string]$j.Name
    if ($seen.ContainsKey($n)) { continue }
    $l = $sessions | Where-Object { $_.jobName -eq $n } | Select-Object -First 1
    $copy += [ordered]@{ name=$n; enabled=[bool]$j.IsScheduleEnabled; lastResult=$(if($l){$l.result}else{'None'}); lastUtc=$(if($l){$l.createdUtc}else{$null}) }
  }
  $backups = @()
  foreach ($b in @(Get-VBRBackup -ErrorAction Stop)) {
    $pts = @(Get-VBRRestorePoint -Backup $b -ErrorAction SilentlyContinue)
    $nw = ($pts | Sort-Object CreationTime -Descending | Select-Object -First 1).CreationTime
    $backups += [ordered]@{ name=[string]$b.Name; pointCount=$pts.Count; newestUtc=$(if($nw){$nw.ToUniversalTime().ToString('o')}else{$null}) }
  }
  @{ ok=$true; jobs=$jobs; repos=$repos; objectRepos=$objRepos; s3CredCount=$s3;
     copyJobs=$copy; backups=$backups; sessions=$sessions } | ConvertTo-Json -Depth 6 -Compress
}
catch {
  @{ ok=$false; error=[string]$_.Exception.Message } | ConvertTo-Json -Compress
}
'@
    return Invoke-VeeamQuery -Script $code -Prefix "`$TrimCount = $SessionTrimCount"
}

function Get-VeeamPreflightState {
    $code = @'
$r = @{ ok=$true }
try {
  if (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue) {
    try { Connect-VBRServer -Server localhost -ErrorAction Stop } catch { }
  }
  $working = @()
  try {
    $working += @(Get-VBRBackupSession -ErrorAction Stop | Where-Object { $_.State -eq 'Working' })
    if (Get-Command Get-VBRRestoreSession -ErrorAction SilentlyContinue) {
      $working += @(Get-VBRRestoreSession -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Working' })
    }
    $r.workingSessions = $working.Count
    $r.workingJobNames = @($working | ForEach-Object { [string]$_.JobName } | Select-Object -Unique) -join ', '
  } catch { $r.workingSessionsError = [string]$_.Exception.Message }
  try {
    $b = @(Get-VBRBackup -ErrorAction Stop)
    $r.backupCount = $b.Count
    $r.legacyChain = @($b | Where-Object { $_.PSObject.Properties.Name -contains 'IsMetaExist' -and $_.IsMetaExist -eq $true }).Count
  } catch { $r.legacyChainError = [string]$_.Exception.Message }
  try {
    $r.legacyCopyJobs = @(Get-VBRJob -ErrorAction Stop -WarningAction SilentlyContinue | Where-Object { [string]$_.JobType -eq 'BackupSync' }).Count
  } catch { $r.legacyCopyJobsError = [string]$_.Exception.Message }
  try {
    $r.hardenedRepos = @(Get-VBRBackupRepository -ErrorAction Stop | Where-Object { [string]$_.Type -match 'Hardened' }).Count
  } catch { $r.hardenedReposError = [string]$_.Exception.Message }
  try {
    $r.repoPaths = @(Get-VBRBackupRepository -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Path } | Where-Object { $_ })
  } catch { $r.repoPaths = @() }
  $r.objectRepoCount = 0
  try {
    if (Get-Command Get-VBRObjectStorageRepository -ErrorAction SilentlyContinue) {
      $r.objectRepoCount = @(Get-VBRObjectStorageRepository -ErrorAction SilentlyContinue).Count
    }
  } catch { }
  $r.copyJobCount = 0
  try {
    $seen = @{}
    if (Get-Command Get-VBRBackupCopyJob -ErrorAction SilentlyContinue) {
      foreach ($j in @(Get-VBRBackupCopyJob -ErrorAction SilentlyContinue)) { $seen[[string]$j.Name] = $true }
    }
    foreach ($j in @(Get-VBRJob -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where-Object { [string]$_.JobType -match 'Copy|Sync' })) { $seen[[string]$j.Name] = $true }
    $r.copyJobCount = $seen.Keys.Count
  } catch { }
}
catch { $r = @{ ok=$false; error=[string]$_.Exception.Message } }
$r | ConvertTo-Json -Depth 4 -Compress
'@
    return Invoke-VeeamQuery -Script $code
}

function Invoke-ComponentUpgrade {
    # Get-VBRPhysicalHost exposes IsUpToDate; Update-VBRServerComponent takes
    # -Component <VBRPhysicalHost[]>. On DTCBSURE-4557 and -4199 every host was
    # already IsUpToDate=True after the v13 install with VBR_AUTO_UPGRADE=0, so
    # this is usually a check, not work.
    # NOTE: there is NO cmdlet surface for the VSPC / Service Provider Console
    # dependency prompt. That remains a console action.
    $code = @'
$log = New-Object System.Collections.Generic.List[string]
try {
  if (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue) {
    try { Connect-VBRServer -Server localhost -ErrorAction Stop } catch { }
  }
  if (-not (Get-Command Get-VBRPhysicalHost -ErrorAction SilentlyContinue)) {
    @{ ok=$true; skipped='Get-VBRPhysicalHost not available on this build'; log=@() } | ConvertTo-Json -Depth 4 -Compress
    return
  }
  $vhosts = @(Get-VBRPhysicalHost -ErrorAction Stop)
  $stale = @($vhosts | Where-Object { $_.PSObject.Properties.Name -contains 'IsUpToDate' -and -not $_.IsUpToDate })
  $log.Add("Managed hosts: $($vhosts.Count); out of date: $($stale.Count).")
  if ($stale.Count -eq 0) {
    @{ ok=$true; upgraded=@(); log=@($log) } | ConvertTo-Json -Depth 4 -Compress
    return
  }
  foreach ($h in $stale) { $log.Add("  out of date: $([string]$h.Name)") }
  Update-VBRServerComponent -Component $stale -ErrorAction Stop | Out-Null
  $sw = [System.Diagnostics.Stopwatch]::StartNew(); $done = $false
  while ($sw.Elapsed.TotalSeconds -lt $CompWait) {
    Start-Sleep -Seconds 30
    $now = @(Get-VBRPhysicalHost -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties.Name -contains 'IsUpToDate' -and -not $_.IsUpToDate })
    if ($now.Count -eq 0) { $done = $true; break }
  }
  if ($done) { $log.Add("All managed host components are now up to date.") }
  else {
    $still = @(Get-VBRPhysicalHost -ErrorAction SilentlyContinue | Where-Object { $_.PSObject.Properties.Name -contains 'IsUpToDate' -and -not $_.IsUpToDate } | ForEach-Object { [string]$_.Name })
    $log.Add("Component upgrade did not finish within $CompWait s. Still out of date: $($still -join ', ')")
  }
  @{ ok=$true; upgraded=@($stale | ForEach-Object { [string]$_.Name }); completed=$done; log=@($log) } | ConvertTo-Json -Depth 4 -Compress
}
catch {
  @{ ok=$false; error=[string]$_.Exception.Message; log=@($log) } | ConvertTo-Json -Depth 4 -Compress
}
'@
    return Invoke-VeeamQuery -Script $code -Prefix "`$CompWait = $ComponentWaitSecs"
}

# =============================================================================
# AGENT BLOCKER REMEDIATION
# =============================================================================

function Invoke-AgentRemediationQuery {
    param([string[]]$TargetNames = @(), [int]$StaleDays = 180, [int]$RestorePointDays = 60, [bool]$ReportOnly = $false)

    $namesLiteral = if ($TargetNames.Count -gt 0) {
        "@(" + (($TargetNames | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',') + ")"
    } else { '@()' }

    $prefix = @"
`$Targets = $namesLiteral
`$StaleDays = $StaleDays
`$RpDays = $RestorePointDays
`$ReportOnly = `$$($ReportOnly.ToString().ToLower())
`$UpgradeWait = $AgentUpgradeWaitSecs
"@

    $code = @'
$log = New-Object System.Collections.Generic.List[string]
$removed = @(); $upgraded = @(); $blocked = @()
try {
  if (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue) {
    try { Connect-VBRServer -Server localhost -ErrorAction Stop } catch { }
  }
  if (-not (Get-Command Get-VBRDiscoveredComputer -ErrorAction SilentlyContinue)) {
    @{ ok=$true; skipped='Get-VBRDiscoveredComputer not available'; log=@(); removed=@(); upgraded=@(); blocked=@() } | ConvertTo-Json -Depth 4 -Compress
    return
  }
  $all = @(Get-VBRDiscoveredComputer -ErrorAction Stop)
  if ($all.Count -eq 0) {
    @{ ok=$true; log=@('No agent-managed computers registered.'); removed=@(); upgraded=@(); blocked=@() } | ConvertTo-Json -Depth 4 -Compress
    return
  }

  if ($Targets.Count -gt 0) {
    $scope = @($all | Where-Object { $Targets -contains [string]$_.Name })
    $log.Add("Agent remediation scoped to $($scope.Count) machine(s) named by the installer: $($Targets -join ', ')")
  } else {
    $cut = (Get-Date).AddDays(-$StaleDays)
    $scope = @($all | Where-Object { [string]$_.State -eq 'Offline' -and $_.LastConnected -ne $null -and $_.LastConnected -lt $cut })
    if ($scope.Count -eq 0) {
      @{ ok=$true; log=@("Agent inventory: $($all.Count) machine(s), none offline beyond $StaleDays days."); removed=@(); upgraded=@(); blocked=@() } | ConvertTo-Json -Depth 4 -Compress
      return
    }
    $log.Add("Agent inventory: $($all.Count) machine(s); $($scope.Count) offline beyond $StaleDays days.")
  }

  foreach ($dc in $scope) {
    $name = [string]$dc.Name; $ver = [string]$dc.AgentVersion
    $st = [string]$dc.State; $last = $dc.LastConnected

    if ($st -eq 'Online') {
      if ($ReportOnly) { $log.Add("  $name ($ver, Online): would upgrade agent."); continue }
      # An endpoint with a pending reboot cannot finish an agent upgrade - the
      # attempt simply times out (DTCBSURE-4951, -4554, -4207 all burned 600 s
      # this way). Halt immediately and name the machine instead.
      if ($dc.PSObject.Properties.Name -contains 'RebootRequired' -and $dc.RebootRequired) {
        $log.Add("  $name ($ver, Online): RebootRequired=True on the endpoint - the agent upgrade cannot complete until that workstation reboots. NOT attempted.")
        $blocked += "$name (online, endpoint has a pending reboot - reboot that workstation, then re-run)"
        continue
      }
      try {
        $log.Add("  $name ($ver, Online): upgrading agent ...")
        Install-VBRDiscoveredComputerAgent -DiscoveredComputer $dc -ErrorAction Stop | Out-Null
        $sw = [System.Diagnostics.Stopwatch]::StartNew(); $done = $false
        while ($sw.Elapsed.TotalSeconds -lt $UpgradeWait) {
          Start-Sleep -Seconds 30
          $now = Get-VBRDiscoveredComputer -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -eq $name } | Select-Object -First 1
          if ($now -and [string]$now.AgentVersion -ne $ver) {
            $log.Add("  $name agent $ver -> $([string]$now.AgentVersion)."); $upgraded += $name; $done = $true; break
          }
          if ($now -and $now.PSObject.Properties.Name -contains 'RebootRequired' -and $now.RebootRequired) {
            $log.Add("  $name now reports RebootRequired=True - the upgrade staged but needs that workstation rebooted to finish.")
            $blocked += "$name (online, agent upgrade staged; endpoint needs a reboot to complete)"
            $done = $true; break
          }
        }
        if (-not $done) {
          $post = Get-VBRDiscoveredComputer -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -eq $name } | Select-Object -First 1
          $ps = if ($post) { "State=$([string]$post.State) AgentVersion=$([string]$post.AgentVersion) AgentStatus=$([string]$post.AgentStatus) RebootRequired=$([string]$post.RebootRequired) OS=$([string]$post.OperatingSystem) $([string]$post.OperatingSystemVersion)" } else { 'device no longer enumerable' }
          $log.Add("  $name agent upgrade did not report a new version within $UpgradeWait s. Post-attempt: $ps")
          $blocked += "$name (online, agent upgrade did not complete; $ps)"
        }
      } catch { $log.Add("  $name agent upgrade failed: $($_.Exception.Message)"); $blocked += "$name (online, agent upgrade failed: $($_.Exception.Message))" }
      continue
    }

    $age = $null
    if ($last) { $age = [int]((Get-Date) - $last).TotalDays }
    if ($null -eq $age) { $blocked += "$name (offline, never connected - manual review)"; $log.Add("  $name ($ver, Offline, never connected): NOT removed."); continue }
    if ($age -lt $StaleDays -and $Targets.Count -eq 0) { $blocked += "$name (offline $age d, under the $StaleDays d threshold)"; $log.Add("  $name ($ver, Offline $age d): NOT removed - under threshold."); continue }

    $hasBk = $false; $rpAge = $null
    try {
      $newest = $null
      foreach ($b in @(Get-VBRBackup -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -match [regex]::Escape($name) })) {
        $pts = @(Get-VBRRestorePoint -Backup $b -ErrorAction SilentlyContinue)
        if ($pts.Count -eq 0) { continue }
        $hasBk = $true
        $n = ($pts | Sort-Object CreationTime -Descending | Select-Object -First 1).CreationTime
        if ($n -and (-not $newest -or $n -gt $newest)) { $newest = $n }
      }
      if ($newest) { $rpAge = [int]((Get-Date) - $newest).TotalDays }
    } catch { $hasBk = $true; $rpAge = 0; $log.Add("  Could not verify backups for '$name' - treating as RECENTLY PROTECTED.") }

    if ($hasBk -and $null -ne $rpAge -and $rpAge -lt $RpDays) {
      $blocked += "$name (offline $age d, newest restore point $rpAge d old - under the $RpDays d threshold)"
      $log.Add("  $name ($ver, Offline $age d): newest restore point is $rpAge d old - NOT removed."); continue
    }
    $desc = if ($hasBk) { "newest restore point $rpAge d old" } else { 'no backups' }
    if ($ReportOnly) { $log.Add("  $name ($ver, Offline $age d, $desc): would remove."); continue }
    try {
      $log.Add("  $name ($ver, Offline $age d, last seen $last, $desc): removing stale registration. Backup files are retained on the repository.")
      $cmd = Get-Command Remove-VBRDiscoveredComputer -ErrorAction Stop
      $pn = @('Computer','DiscoveredComputer','Item','InputObject') | Where-Object { $cmd.Parameters.ContainsKey($_) } | Select-Object -First 1
      if ($pn) {
        # PowerShell splats from a VARIABLE only - a literal @{} is passed as a
        # positional argument and throws. This was the 0-for-3 removal bug.
        $rp = @{ $pn = $dc; Confirm = $false; ErrorAction = 'Stop' }
        Remove-VBRDiscoveredComputer @rp
      }
      else { $dc | Remove-VBRDiscoveredComputer -Confirm:$false -ErrorAction Stop }
      $removed += "$name (agent $ver, offline $age d, $desc)"
    } catch { $log.Add("  $name removal failed: $($_.Exception.Message)"); $blocked += "$name (removal failed: $($_.Exception.Message))" }
  }

  @{ ok=$true; log=@($log); removed=@($removed); upgraded=@($upgraded); blocked=@($blocked) } | ConvertTo-Json -Depth 4 -Compress
}
catch {
  @{ ok=$false; error=[string]$_.Exception.Message; log=@($log); removed=@($removed); upgraded=@($upgraded); blocked=@($blocked) } | ConvertTo-Json -Depth 4 -Compress
}
'@
    return Invoke-VeeamQuery -Script $code -Prefix $prefix
}

function Invoke-AgentRemediation {
    param([string[]]$TargetNames = @(), [int]$StaleDays = 180, [int]$RestorePointDays = 60, [switch]$ReportOnly)

    $result = @{ Upgraded = @(); Removed = @(); Blocked = @() }
    $r = $null
    try {
        $r = Invoke-AgentRemediationQuery -TargetNames $TargetNames -StaleDays $StaleDays `
                -RestorePointDays $RestorePointDays -ReportOnly:([bool]$ReportOnly)
    } catch {
        Write-Log "Agent remediation query failed: $($_.Exception.Message)" 'WARN'
        return $result
    }
    if ($null -eq $r) { return $result }
    foreach ($l in @($r.log)) { if ($l) { Write-Log $l } }
    if ($r.skipped) { Write-Log "Agent remediation skipped: $($r.skipped)" 'WARN'; return $result }
    if (-not $r.ok) { Write-Log "Agent remediation error: $($r.error)" 'WARN' }

    $result.Removed  = @($r.removed)
    $result.Upgraded = @($r.upgraded)
    $result.Blocked  = @($r.blocked)

    if ($result.Removed.Count -gt 0) {
        Write-Log ("AGENT CLEANUP - removed {0} stale registration(s): {1}" -f $result.Removed.Count, ($result.Removed -join '; ')) 'WARN'
        Write-Log 'NOTE: registration removal only - backup files remain on the repository. Removal from a Custom protection group is permanent.' 'WARN'
    }
    if ($result.Upgraded.Count -gt 0) {
        Write-Log ("AGENT CLEANUP - upgraded {0} agent(s): {1}" -f $result.Upgraded.Count, ($result.Upgraded -join '; '))
    }
    return $result
}

function Get-SetupReportAgentBlockers {
    param([string]$ReportPath)
    $out = @{ Names = @(); Titles = @(); OtherErrors = @() }
    if (-not (Test-Path -LiteralPath $ReportPath)) { return $out }
    try {
        [xml]$rpt = Get-Content -LiteralPath $ReportPath -Raw
        foreach ($i in @($rpt.report.issue)) {
            if ([string]$i.severity -ne 'error') { continue }
            $title = [string]$i.title
            $out.Titles += $title
            $objs = @($i.object)
            if ($objs.Count -gt 0 -and $title -match '(?i)agent') {
                foreach ($o in $objs) {
                    $raw = [string]$o.name
                    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                    $out.Names += ($raw -split '\s*\(')[0].Trim()
                }
            } else { $out.OtherErrors += $title }
        }
    } catch { Write-Log "Could not parse setup report ${ReportPath}: $($_.Exception.Message)" 'WARN' }
    return $out
}

function Get-PostUpgradeCopyStatus {
    param($BaselineCopyJobs, $LiveSessions, [datetime]$SinceUtc)

    $out = @{ Failed = @(); Succeeded = @(); NotYet = @(); PreBroken = @() }
    foreach ($cj in @($BaselineCopyJobs)) {
        $healthy = ([string]$cj.lastResult -in @('Success','Warning','None'))
        if (-not $healthy) { $out.PreBroken += [string]$cj.name; continue }
        if (-not [bool]$cj.enabled) { continue }

        $post = @($LiveSessions) |
            Where-Object { [string]$_.jobName -eq [string]$cj.name -and
                           [datetime]::Parse([string]$_.createdUtc).ToUniversalTime() -gt $SinceUtc } |
            Sort-Object { [datetime]::Parse([string]$_.createdUtc) } -Descending | Select-Object -First 1
        if (-not $post) { $out.NotYet += [string]$cj.name }
        elseif ([string]$post.result -eq 'Failed') { $out.Failed += ("{0} (session {1}, {2})" -f $cj.name, $post.createdUtc, $post.result) }
        else { $out.Succeeded += [string]$cj.name }
    }
    return $out
}

# =============================================================================
# SERVICE / INSTALLER HANDLING
# =============================================================================

function Stop-VeeamMaintenanceWorkers {
    $killed = @()
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='Veeam.Backup.Manager.exe'" -ErrorAction SilentlyContinue)) {
            $cl = [string]$p.CommandLine
            if ($cl -match $MaintenanceVerbs) {
                $verb = ([regex]::Match($cl, $MaintenanceVerbs)).Value
                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                $killed += "$verb(PID $($p.ProcessId))"
            }
        }
    } catch { }
    return ,$killed
}

function Test-VeeamServiceWedged {
    # StopPending/StartPending never resolve on their own and halt every
    # subsequent run. Only a reboot clears it - force-killing wedged this
    # platform previously.
    $wedged = @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -in @('StopPending','StartPending','PausePending','ContinuePending') })
    if ($wedged.Count -eq 0) { return $null }
    return (($wedged | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ')
}

function Restore-VeeamServiceRecovery {
    if (-not (Test-Path -LiteralPath $FailureActionsFile)) { return }
    $restored = 0
    $prevEap = $ErrorActionPreference
    try {
        $saved = Get-Content -LiteralPath $FailureActionsFile -Raw | ConvertFrom-Json
        $ErrorActionPreference = 'Continue'
        foreach ($p in $saved.PSObject.Properties) {
            $svcName = $p.Name; $acts = [string]$p.Value.actions; $reset = [int]$p.Value.reset
            if ([string]::IsNullOrWhiteSpace($acts)) { continue }
            & cmd.exe /c "sc failure `"$svcName`" reset= $reset actions= $acts" 2>&1 | Out-Null
            $restored++
        }
        $ErrorActionPreference = $prevEap
        Remove-Item -LiteralPath $FailureActionsFile -Force -ErrorAction SilentlyContinue
        Write-Log "SCM recovery actions restored on $restored Veeam service(s)."
    } catch {
        $ErrorActionPreference = $prevEap
        Write-Log "Could not restore SCM recovery actions: $($_.Exception.Message)." 'WARN'
    }
}

function Disable-VeeamServiceRecovery {
    $saved = [ordered]@{}
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    foreach ($s in @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue)) {
        $q = ((& sc.exe qfailure $s.Name 2>$null) -join "`n")
        $acts = @()
        foreach ($m in [regex]::Matches($q, '(?i)(RESTART|RUN PROCESS|REBOOT)\s*--\s*Delay\s*=\s*(\d+)')) {
            $verb = 'restart'
            if ($m.Groups[1].Value -match '(?i)RUN')    { $verb = 'run' }
            if ($m.Groups[1].Value -match '(?i)REBOOT') { $verb = 'reboot' }
            $acts += ("{0}/{1}" -f $verb, $m.Groups[2].Value)
        }
        $reset = 0
        if ($q -match '(?i)RESET_PERIOD \(in seconds\)\s*:\s*(\d+)') { $reset = [int]$Matches[1] }
        $saved[$s.Name] = [ordered]@{ actions = ($acts -join '/'); reset = $reset }
        & cmd.exe /c "sc failure `"$($s.Name)`" reset= 0 actions= `"`"" 2>&1 | Out-Null
    }
    $ErrorActionPreference = $prevEap
    $saved | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $FailureActionsFile -Encoding UTF8 -Force
    Write-Log "SCM auto-restart cleared on $($saved.Count) Veeam service(s) for the install window."
}

function Repair-VeeamServiceState {
    param([int]$SettleSeconds = 25)

    $disabled = @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue |
        Where-Object { $_.StartType -eq 'Disabled' -and $_.Name -ne 'VeeamMBPDeploymentService' })
    if ($disabled.Count -gt 0) {
        Write-Log ("Re-enabling {0} Disabled Veeam service(s): {1}" -f $disabled.Count, (($disabled | Select-Object -ExpandProperty Name) -join ', ')) 'WARN'
        foreach ($s in $disabled) {
            try { Set-Service -Name $s.Name -StartupType Automatic -ErrorAction Stop }
            catch { Write-Log "  $($s.Name): enable failed - $($_.Exception.Message)" 'WARN' }
        }
    }

    $down = @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue |
        Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -eq 'Stopped' })
    if ($down.Count -eq 0 -and $disabled.Count -eq 0) { Write-Log 'All auto-start Veeam services already running.'; return }

    $ordered = @($down | Where-Object { $_.Name -eq 'VeeamBackupSvc' }) +
               @($down | Where-Object { $_.Name -ne 'VeeamBackupSvc' })
    if ($ordered.Count -gt 0) {
        Write-Log ("Starting {0} stopped auto-start Veeam service(s)." -f $ordered.Count) 'WARN'
        foreach ($s in $ordered) {
            try { Start-Service -Name $s.Name -ErrorAction Stop }
            catch { Write-Log "  $($s.Name): start failed - $($_.Exception.Message)" 'WARN' }
        }
        Start-Sleep -Seconds $SettleSeconds
    }

    $still = @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue |
        Where-Object { $_.StartType -eq 'Automatic' -and $_.Status -ne 'Running' })
    if ($still.Count -gt 0) {
        Write-Log ("Still not running: {0}" -f (($still | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ')) 'WARN'
    } else { Write-Log 'All auto-start Veeam services running.' }
}

function Stop-VeeamForUpgrade {
    param([int]$TimeoutSeconds = 600)

    Disable-VeeamServiceRecovery

    $pre = Stop-VeeamMaintenanceWorkers
    if ($pre.Count -gt 0) { Write-Log ("Cleared {0} maintenance worker(s) before stopping: {1}" -f $pre.Count, ($pre -join ', ')) }

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    $others = @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'VeeamBackupSvc' -and $_.Status -ne 'Stopped' })
    if ($others.Count -gt 0) {
        Write-Log ("Stopping {0} auxiliary Veeam service(s)." -f $others.Count)
        foreach ($s in $others) { & sc.exe stop $s.Name | Out-Null }
        Start-Sleep -Seconds 20
    }

    $svc = Get-Service -Name 'VeeamBackupSvc' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne 'Stopped') {
        Write-Log "Stopping VeeamBackupSvc (up to $TimeoutSeconds s; the installer itself allows only 300 s) ..."
        & sc.exe stop VeeamBackupSvc | Out-Null
        $sw = [System.Diagnostics.Stopwatch]::StartNew(); $lastReport = 0
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Seconds 10
            $st = (Get-Service -Name 'VeeamBackupSvc' -ErrorAction SilentlyContinue).Status
            if ($st -eq 'Stopped') { break }
            if ($sw.Elapsed.TotalSeconds -ge $StopPendingGraceSecs) {
                $k = Stop-VeeamMaintenanceWorkers
                if ($k.Count -gt 0) { Write-Log ("  Terminated {0} maintenance worker(s) holding the stop: {1}" -f $k.Count, ($k -join ', ')) 'WARN' }
            }
            if (($sw.Elapsed.TotalSeconds - $lastReport) -ge 120) {
                $lastReport = $sw.Elapsed.TotalSeconds
                Write-Log ("  VeeamBackupSvc still {0} after {1:n0} s ..." -f $st, $sw.Elapsed.TotalSeconds)
            }
        }
    }
    $ErrorActionPreference = $prevEap

    $final = (Get-Service -Name 'VeeamBackupSvc' -ErrorAction SilentlyContinue).Status
    if ($final -ne 'Stopped') {
        Write-Log "VeeamBackupSvc is still '$final' after $TimeoutSeconds s." 'WARN'
        Restore-VeeamServiceRecovery
        return $false
    }
    Write-Log 'VeeamBackupSvc stopped cleanly.'
    return $true
}

function Get-NinjaSecureField {
    param([string]$FieldName)
    if (Get-Command Ninja-Property-Get -ErrorAction SilentlyContinue) {
        try {
            $v = Ninja-Property-Get $FieldName 2>$null
            if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
        } catch { }
    }
    $cliCandidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'NinjaRMMAgent\ninjarmm-cli.exe'),
        (Join-Path $env:ProgramFiles        'NinjaRMMAgent\ninjarmm-cli.exe'),
        'C:\ProgramData\NinjaRMMAgent\ninjarmm-cli.exe'
    )
    foreach ($cli in $cliCandidates) {
        if (Test-Path -LiteralPath $cli) {
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $v = & $cli get $FieldName 2>$null
            $ErrorActionPreference = $prevEap
            if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return ([string]$v).Trim() }
        }
    }
    return $null
}

function Test-LocalCredential {
    # One real logon attempt. DTCBSURE-5043 proved the cost of skipping it: the
    # task registered with a stale password, Windows rejected it at launch
    # (Security 4625, substatus 0xC000006A = bad password), the task never ran,
    # and LastTaskResult 0 read as success. Fails here, before an 18 GB download.
    param([string]$User, [string]$Password)
    try {
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
        $ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Machine', $env:COMPUTERNAME)
        try { return [bool]$ctx.ValidateCredentials($User, $Password) }
        finally { $ctx.Dispose() }
    } catch {
        Write-Log "Credential pre-validation could not run ($($_.Exception.Message)) - proceeding; the task-launch check still catches a bad password." 'WARN'
        return $true
    }
}

function Write-FailedComponentSummary {
    param([datetime]$SinceUtc)
    $found = 0
    foreach ($pl in @(Get-ChildItem -LiteralPath $LogFolder -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(VeeamPlugin|VeeamExplorer|Veeam[A-Za-z]+)\.log$' -and
                           $_.LastWriteTime.ToUniversalTime() -ge $SinceUtc })) {
        $t = Get-Content -LiteralPath $pl.FullName -Raw -ErrorAction SilentlyContinue
        if ($t -match 'Installation operation failed|error status: 1603') {
            $why = if ($t -match 'MsiSystemRebootPending = 1') { ' (a reboot became pending mid-install - the reboot below clears it)' } else { '' }
            Write-Log "  COMPONENT FAILED: $($pl.BaseName)$why" 'WARN'
            $found++
        }
    }
    if ($found -eq 0) { Write-Log '  No individual component log identified the failure.' 'WARN' }
}

function Invoke-IsoDownload {
    param([string]$Url, [string]$Destination)
    $partial = "$Destination.partial"
    $curl = Join-Path $env:WINDIR 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        Write-Log 'Downloading via curl.exe (resume-capable).'
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $curlOut = & $curl -L --fail --silent --show-error --retry 5 --retry-delay 20 -C - -o $partial $Url 2>&1
        $curlExit = $LASTEXITCODE
        $ErrorActionPreference = $prevEap
        foreach ($line in @($curlOut)) { if ("$line".Trim()) { Write-Log "curl: $("$line".Trim())" 'WARN' } }
        if ($curlExit -eq 0 -and (Test-Path -LiteralPath $partial)) {
            Move-Item -LiteralPath $partial -Destination $Destination -Force
            return
        }
        Write-Log "curl exited $curlExit; falling back to BITS." 'WARN'
    }
    try {
        Start-BitsTransfer -Source $Url -Destination $partial -ErrorAction Stop
        Move-Item -LiteralPath $partial -Destination $Destination -Force
        return
    } catch { Write-Log "BITS failed ($($_.Exception.Message)); falling back to WebClient." 'WARN' }
    (New-Object System.Net.WebClient).DownloadFile($Url, $partial)
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}

function Test-IsoHash {
    param([string]$Path, [string]$Expected)
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    Write-Log "SHA256 computed: $actual"
    return ($actual -eq $Expected.Trim().ToUpper())
}

function Expand-IsoToLocal {
    param([string]$IsoPath, [string]$Destination)
    $installer = Join-Path $Destination $InstallerRelPath
    if (Test-Path -LiteralPath $installer) { Write-Log "Local install source already present: $Destination"; return $installer }
    if (Test-Path -LiteralPath $Destination) {
        Write-Log "Removing incomplete local install source at $Destination ..." 'WARN'
        Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $Destination -ItemType Directory -Force | Out-Null

    Mount-DiskImage -ImagePath $IsoPath | Out-Null
    $script:mountedIso = $IsoPath
    $drv = $null
    for ($i = 0; $i -lt 10 -and -not $drv; $i++) {
        Start-Sleep -Seconds 3
        $drv = (Get-DiskImage -ImagePath $IsoPath | Get-Volume -ErrorAction SilentlyContinue).DriveLetter
    }
    if (-not $drv) { throw 'Could not resolve mounted drive letter after 30 seconds.' }
    Write-Log "Mounted at ${drv}: - copying install source to $Destination (the patch engine cannot run from read-only media) ..."

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & robocopy.exe "${drv}:\" $Destination /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $prevEap

    Dismount-DiskImage -ImagePath $IsoPath | Out-Null
    $script:mountedIso = $null

    if ($rc -ge 8) { throw "robocopy failed copying install source from ${drv}: to $Destination (exit $rc)." }
    if (-not (Test-Path -LiteralPath $installer)) { throw "Install source copied (robocopy exit $rc) but $InstallerRelPath is missing under $Destination." }
    Write-Log "Install source copied (robocopy exit $rc). Running setup from local disk."
    return $installer
}

function Write-InstallerResultXml {
    param([datetime]$SinceUtc)
    try {
        $xml = Get-ChildItem -LiteralPath $SetupTempFolder -Filter 'UnattendedInstallationResult_*.xml' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime.ToUniversalTime() -ge $SinceUtc } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($xml) {
            Write-Log "Installer result XML: $($xml.FullName)"
            Write-CappedLines -Lines (Get-Content -LiteralPath $xml.FullName -ErrorAction SilentlyContinue) `
                              -Max $MaxResultXmlLines -Prefix '  RESULTXML: ' -FullPath $xml.FullName
        } else {
            # Setup often writes the result document to STDERR instead of this
            # folder - it was captured into installer-stderr.txt and echoed with
            # the INSTALLER: prefix above (DTCBSURE-4947).
            Write-Log "No UnattendedInstallationResult_*.xml in $SetupTempFolder - the result document is in the INSTALLER: lines above." 'WARN'
        }
    } catch { Write-Log "Result XML capture failed: $($_.Exception.Message)" 'WARN' }

    try {
        $patch = Get-ChildItem -LiteralPath $SetupTempFolder -Filter '*Patch*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime.ToUniversalTime() -ge $SinceUtc } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($patch) {
            $txt = Get-Content -LiteralPath $patch.FullName -Raw -ErrorAction SilentlyContinue
            if ($txt -match 'EXCEPTION|Performing rollback') {
                Write-Log "Patch pass reported a problem in $($patch.Name):" 'WARN'
                Write-CappedLines -Lines (($txt -split "`r?`n") | Select-Object -Last 15) -Max 15 -Prefix '  PATCH: ' -FullPath $patch.FullName
            } else { Write-Log "Patch pass log $($patch.Name) shows no exception." }
        }
    } catch { }
}

function Invoke-InstallerAsLocalAdmin {
    param([string]$InstallerExe, [string]$AnswerFile, [string]$InstallLogFolder, [string]$User, [string]$PlainPassword)

    $wrapper = Join-Path $LogFolder 'run-installer.ps1'
    $outFile = Join-Path $LogFolder 'installer-stdout.txt'
    $errFile = Join-Path $LogFolder 'installer-stderr.txt'
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue

    $wrapperBody = @"
`$p = Start-Process -FilePath '$InstallerExe' ``
    -ArgumentList '/AnswerFile', '"$AnswerFile"', '/SkipNetworkLogonErrors', '/LogFolder', '"$InstallLogFolder"' ``
    -Wait -PassThru -WindowStyle Hidden ``
    -RedirectStandardOutput '$outFile' -RedirectStandardError '$errFile'
exit `$p.ExitCode
"@
    Set-Content -LiteralPath $wrapper -Value $wrapperBody -Encoding UTF8 -Force

    Unregister-ScheduledTask -TaskName $InstallTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$wrapper`"" -WorkingDirectory $LogFolder
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 3)

    $taskAccount = "$env:COMPUTERNAME\$User"
    Register-ScheduledTask -TaskName $InstallTaskName -Action $action -Settings $settings `
        -User $taskAccount -Password $PlainPassword -RunLevel Highest -Force | Out-Null
    Write-Log "One-shot installer task registered as $taskAccount (RunLevel Highest)."

    Start-ScheduledTask -TaskName $InstallTaskName

    # CONFIRM THE TASK ACTUALLY LAUNCHED. A rejected credential fails at launch:
    # the task never enters Running and LastTaskResult stays 0 from a prior
    # state - which earlier versions read as a successful install that never
    # happened (DTCBSURE-5043).
    $launched = $false
    $s0 = 'Unknown'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TaskLaunchWaitSecs) {
        Start-Sleep -Seconds 5
        $s0 = [string](Get-ScheduledTask -TaskName $InstallTaskName -ErrorAction SilentlyContinue).State
        if ($s0 -eq 'Running') { $launched = $true; break }
    }
    if (-not $launched) {
        $ti = Get-ScheduledTaskInfo -TaskName $InstallTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $InstallTaskName -Confirm:$false -ErrorAction SilentlyContinue
        throw ("Installer task never entered Running within $TaskLaunchWaitSecs s (state '$s0', LastTaskResult $(if ($ti) { $ti.LastTaskResult } else { 'unknown' })). Windows rejected the scheduled-task logon - almost always a stale '$LapsFieldName' value for $env:COMPUTERNAME\$User. Check Security event 4625; substatus 0xC000006A means bad password. THE INSTALLER DID NOT RUN and nothing on this box was changed.")
    }
    Write-Log 'Installer task confirmed Running. Polling for completion (StopPending watchdog active)...'

    $deadline = (Get-Date).AddHours(3)
    $stopPendingSince = $null
    $watchdogFires = 0
    do {
        Start-Sleep -Seconds 15
        $st = [string](Get-ScheduledTask -TaskName $InstallTaskName -ErrorAction SilentlyContinue).State

        $vbs = (Get-Service -Name 'VeeamBackupSvc' -ErrorAction SilentlyContinue).Status
        if ($vbs -eq 'StopPending') {
            if (-not $stopPendingSince) { $stopPendingSince = Get-Date }
            elseif (((Get-Date) - $stopPendingSince).TotalSeconds -ge $StopPendingGraceSecs) {
                $k = Stop-VeeamMaintenanceWorkers
                $watchdogFires++
                if ($k.Count -gt 0) {
                    Write-Log ("WATCHDOG: StopPending > {0} s - terminated {1} maintenance worker(s): {2}" -f $StopPendingGraceSecs, $k.Count, ($k -join ', ')) 'WARN'
                } elseif ($watchdogFires -le 3) {
                    Write-Log ("WATCHDOG: StopPending > {0} s but no maintenance workers found - something else holds the service." -f $StopPendingGraceSecs) 'WARN'
                }
                $stopPendingSince = Get-Date
            }
        } else { $stopPendingSince = $null }
    } while ($st -eq 'Running' -and (Get-Date) -lt $deadline)

    if ($st -eq 'Running') {
        Write-Log 'Installer task still running at 3 h limit - treating as failure.' 'ERROR'
        Stop-ScheduledTask -TaskName $InstallTaskName -ErrorAction SilentlyContinue
    }

    $info = Get-ScheduledTaskInfo -TaskName $InstallTaskName
    $code = [int]$info.LastTaskResult
    Unregister-ScheduledTask -TaskName $InstallTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $wrapper -Force -ErrorAction SilentlyContinue

    foreach ($f in @($outFile, $errFile)) {
        if ((Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 0) {
            Write-Log "--- installer $([IO.Path]::GetFileName($f)) ---"
            Write-CappedLines -Lines ((Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue) -split "`r?`n") `
                              -Max $MaxStdoutLines -Prefix '  INSTALLER: ' -FullPath $f
        }
    }
    return $code
}

function Invoke-PostUpgradeValidation {
    param($State)

    $fails = New-Object System.Collections.Generic.List[string]
    $copyNotYet = @()

    $bootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
    $upgUtc  = [datetime]::Parse($State.upgradeTimeUtc).ToUniversalTime()
    if ($bootUtc -le $upgUtc) {
        $fails.Add("AWAITING REBOOT: last boot $($bootUtc.ToString('o')) predates upgrade $($State.upgradeTimeUtc).")
        return @{ Passed = $false; Failures = $fails; AwaitingReboot = $true; CopyNotYet = @() }
    }
    Write-Log "VALIDATION: Reboot confirmed (boot $($bootUtc.ToString('o')))."

    Repair-VeeamServiceState -SettleSeconds $SvcStartSettleSecs

    $svcsOk = $false
    for ($i = 1; $i -le $SvcWaitAttempts; $i++) {
        $auto = @(Get-CimInstance Win32_Service -Filter "Name LIKE 'Veeam%' AND StartMode='Auto'")
        $down = @($auto | Where-Object { $_.State -ne 'Running' })
        if ($auto.Count -gt 0 -and $down.Count -eq 0) { $svcsOk = $true; break }
        Write-Log ("VALIDATION: waiting on services ({0}/{1}): {2}" -f $i, $SvcWaitAttempts, (($down | Select-Object -ExpandProperty Name) -join ', '))
        Start-Sleep -Seconds $SvcWaitSeconds
    }
    if ($svcsOk) { Write-Log 'VALIDATION: Services... PASS' }
    else {
        $downNames = (@(Get-CimInstance Win32_Service -Filter "Name LIKE 'Veeam%' AND StartMode='Auto'") |
            Where-Object { $_.State -ne 'Running' } | Select-Object -ExpandProperty Name) -join ', '
        $fails.Add("SERVICES: not running after $($SvcWaitAttempts * $SvcWaitSeconds)s: $downNames")
    }

    $minReq = $null
    if ($State.PSObject.Properties.Name -contains 'hopMinimum' -and $State.hopMinimum) { $minReq = [version]$State.hopMinimum }
    else { $minReq = [version]$State.hopTarget }
    try {
        $cur = Get-InstalledVbrBuild
        if ($cur.Build -ge $minReq) { Write-Log "VALIDATION: Build... PASS ($($cur.Build) >= minimum $minReq)" }
        else { $fails.Add("BUILD: expected >= $minReq, found $($cur.Build).") }
    } catch { $fails.Add("BUILD: query failed: $($_.Exception.Message)") }

    $live = $null
    try {
        $live = Get-VeeamLiveState
        if ($null -eq $live -or -not $live.ok) {
            $fails.Add("CONNECT: Veeam live-state query failed: $(if($live){$live.error}else{'no output'})")
            $live = $null
        } else { Write-Log 'VALIDATION: Console connect... PASS' }
    } catch { $fails.Add("CONNECT: Veeam module/session failed: $($_.Exception.Message)") }

    if ($live) {
        $bl = Get-Content -LiteralPath $State.baselineFile -Raw | ConvertFrom-Json

        try {
            if ($bl.PSObject.Properties.Name -contains 'services' -and @($bl.services).Count -gt 0) {
                $liveSvc = @{}
                foreach ($s in @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue)) { $liveSvc[[string]$s.Name] = [string]$s.StartType }
                $drift = @()
                foreach ($bs in @($bl.services)) {
                    $n = [string]$bs.name
                    if (-not $liveSvc.ContainsKey($n)) { continue }
                    if ($liveSvc[$n] -ne [string]$bs.startType) { $drift += "$n ($([string]$bs.startType)->$($liveSvc[$n]))" }
                }
                if ($drift.Count -eq 0) { Write-Log "VALIDATION: Service StartTypes... PASS ($(@($bl.services).Count))" }
                else { Write-Log ("VALIDATION: Service StartType drift on {0}: {1}" -f $drift.Count, ($drift -join ', ')) 'WARN' }
            }
        } catch { Write-Log "Service StartType comparison failed: $($_.Exception.Message)" 'WARN' }

        $liveJobs = @{}
        foreach ($j in @($live.jobs)) { $liveJobs[[string]$j.name] = [bool]$j.enabled }
        $jobFail = 0
        foreach ($bj in @($bl.jobs)) {
            if (-not $liveJobs.ContainsKey([string]$bj.name)) {
                $fails.Add("JOB MISSING: '$($bj.name)' ($($bj.type)) present at baseline, absent now."); $jobFail++
            } elseif ($liveJobs[[string]$bj.name] -ne [bool]$bj.enabled) {
                $fails.Add("JOB STATE: '$($bj.name)' enabled changed $($bj.enabled) -> $($liveJobs[[string]$bj.name])."); $jobFail++
            }
        }
        if ($jobFail -eq 0) { Write-Log "VALIDATION: Jobs... PASS ($(@($bl.jobs).Count) present, states unchanged)" }

        $liveRepos = @{}
        foreach ($r in @($live.repos)) { $liveRepos[[string]$r.name] = [string]$r.path }
        $repoFail = 0
        foreach ($br in @($bl.repos)) {
            if (-not $liveRepos.ContainsKey([string]$br.name)) {
                $fails.Add("REPO MISSING: '$($br.name)' present at baseline, absent now."); $repoFail++
            } elseif ([string]$br.type -eq 'WinLocal' -and $liveRepos[[string]$br.name] -ne [string]$br.path) {
                $fails.Add("REPO PATH: '$($br.name)' changed '$($br.path)' -> '$($liveRepos[[string]$br.name])'."); $repoFail++
            }
        }
        if ($repoFail -eq 0) { Write-Log "VALIDATION: Repositories... PASS ($(@($bl.repos).Count))" }

        $liveObj = @{}
        foreach ($o in @($live.objectRepos)) { $liveObj[[string]$o.name] = $true }
        $objFail = 0
        foreach ($bo in @($bl.objectRepos)) {
            if (-not $liveObj.ContainsKey([string]$bo.name)) {
                $fails.Add("OFFSITE REPO MISSING: object storage repo '$($bo.name)' present at baseline, absent now."); $objFail++
            }
        }
        if ($objFail -eq 0) { Write-Log "VALIDATION: Object storage repos... PASS ($(@($bl.objectRepos).Count))" }

        if ([int]$live.s3CredCount -lt [int]$bl.s3CredCount) {
            $fails.Add("S3 CREDENTIALS: baseline $($bl.s3CredCount) -> found $($live.s3CredCount).")
        } else { Write-Log "VALIDATION: S3 credentials... PASS ($($live.s3CredCount))" }

        $liveCopy = @{}
        foreach ($cj in @($live.copyJobs)) { $liveCopy[[string]$cj.name] = [bool]$cj.enabled }
        $cpFail = 0
        foreach ($bc in @($bl.copyJobs)) {
            if (-not $liveCopy.ContainsKey([string]$bc.name)) {
                $fails.Add("COPY JOB MISSING: '$($bc.name)' present at baseline, absent now."); $cpFail++
            } elseif ($liveCopy[[string]$bc.name] -ne [bool]$bc.enabled) {
                $fails.Add("COPY JOB STATE: '$($bc.name)' enabled changed $($bc.enabled) -> $($liveCopy[[string]$bc.name])."); $cpFail++
            }
        }
        if ($cpFail -eq 0) { Write-Log "VALIDATION: Copy jobs... PASS ($(@($bl.copyJobs).Count) present, states unchanged)" }

        try {
            $cs = Get-PostUpgradeCopyStatus -BaselineCopyJobs $bl.copyJobs -LiveSessions $live.sessions `
                    -SinceUtc ([datetime]::Parse($State.upgradeTimeUtc).ToUniversalTime())
            foreach ($f in $cs.Failed) { $fails.Add("OFFSITE COPY FAILED post-upgrade: $f (was healthy at baseline).") }
            foreach ($p in $cs.PreBroken) { Write-Log "VALIDATION: copy job '$p' was ALREADY failing at baseline - pre-existing, not blocking." 'WARN' }
            if ($cs.Succeeded.Count -gt 0) { Write-Log "VALIDATION: Offsite copy exercised... PASS ($($cs.Succeeded -join ', '))" }
            $copyNotYet = $cs.NotYet
            if ($copyNotYet.Count -gt 0) { Write-Log "VALIDATION: offsite copy not yet run post-upgrade for: $($copyNotYet -join ', ') - copy-watch will hold exit 0." 'WARN' }
        } catch { $fails.Add("OFFSITE COPY CHECK: failed: $($_.Exception.Message)") }

        $liveBk = @{}
        foreach ($b in @($live.backups)) { $liveBk[[string]$b.name] = $b }
        $ptFail = 0
        foreach ($bb in @($bl.backups)) {
            $n = [string]$bb.name
            if (-not $liveBk.ContainsKey($n)) { $fails.Add("BACKUP MISSING: object '$n' present at baseline, absent now."); $ptFail++; continue }
            $cur = $liveBk[$n]
            $blNewest  = if ($bb.newestUtc)  { [datetime]::Parse([string]$bb.newestUtc).ToUniversalTime() }  else { $null }
            $curNewest = if ($cur.newestUtc) { [datetime]::Parse([string]$cur.newestUtc).ToUniversalTime() } else { $null }
            # A box that misses ONE hourly cycle during its upgrade reboot is
            # normal (DTCBSURE-4178: newest 5 h back; -4937: 8 points fewer -
            # both false positives that permanently held healthy boxes). The
            # real cases are far outside these tolerances: DTCBSURE-4478
            # (newest point 4.5 MONTHS back) and -4480 (-85 of 265 points).
            if ($curNewest -and $blNewest -and $curNewest -lt $blNewest.AddHours(-$RpBackwardsToleranceHours)) {
                $fails.Add("RESTORE POINTS: '$n' newest point went BACKWARDS $($bb.newestUtc) -> $($cur.newestUtc) (beyond the $RpBackwardsToleranceHours h tolerance)."); $ptFail++
            }
            elseif ([int]$cur.pointCount -lt ([int]$bb.pointCount * $RpCountTolerancePct)) {
                $fails.Add("RESTORE POINTS: '$n' baseline $($bb.pointCount) -> found $($cur.pointCount) - a larger drop than retention explains."); $ptFail++
            }
            elseif ([int]$cur.pointCount -lt [int]$bb.pointCount) {
                Write-Log "VALIDATION: '$n' $($bb.pointCount) -> $($cur.pointCount) point(s) - within retention tolerance, not a regression." 'WARN'
            }
        }
        if ($ptFail -eq 0) { Write-Log "VALIDATION: Restore points... PASS ($(@($bl.backups).Count) objects, no regression)" }
    }

    return @{ Passed = ($fails.Count -eq 0); Failures = $fails; AwaitingReboot = $false; CopyNotYet = $copyNotYet }
}

# --- Single instance -----------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, $MutexName)
try   { $haveMutex = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $haveMutex = $true }
if (-not $haveMutex) { Write-Host 'HALTED: another instance of this script is already running.'; exit 2 }
$script:haveMutexRef = $mutex

# --- Transcript with rotation ----------------------------------------------------
if (-not (Test-Path -LiteralPath $LogFolder)) { New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null }
Get-ChildItem -LiteralPath $LogFolder -Filter 'veeam-upgrade_*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip $LogRetention |
    Remove-Item -Force -ErrorAction SilentlyContinue

$transcript = Join-Path $LogFolder ("veeam-upgrade_{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $transcript -Force | Out-Null

try {
    Write-Log "=== DTC Veeam Upgrade v4.2 - HALO 1146283 - $env:COMPUTERNAME ==="
    $pwLoc = Get-PwshPath
    Write-Log ("Identity: {0} | Host PS {1} | pwsh: {2}" -f `
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name, $PSVersionTable.PSVersion,
        $(if ($pwLoc) { 'yes' } else { 'NOT FOUND' }))
    if ($PreflightOnly) { Write-Log 'PREFLIGHT-ONLY MODE - no changes will be made.' 'WARN' }

    Restore-VeeamServiceRecovery

    # A service stuck mid-transition never resolves and blocks every subsequent
    # run. Clear it before anything else inspects state.
    $wedged = Test-VeeamServiceWedged
    if ($wedged) {
        Write-Log "Veeam service(s) stuck mid-transition: $wedged. This never resolves on its own." 'ERROR'
        if ($PreflightOnly) { Write-Log 'Preflight-only: reboot NOT issued.' 'WARN'; exit 2 }
        Invoke-ForcedReboot -Reason 'clearing a wedged Veeam service'
        exit 2
    }

    # =========================================================================
    # PHASE 0 - VALIDATION
    # =========================================================================
    if (Test-Path -LiteralPath $StateFile) {
        $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        Write-Log "Pending validation found: hop $($state.fromBuild) -> $($state.hopTarget), upgraded $($state.upgradeTimeUtc)."

        $v = Invoke-PostUpgradeValidation -State $state

        if ($v.AwaitingReboot) {
            if ($PreflightOnly) { Write-Log 'Preflight-only: reboot NOT issued.' 'WARN'; exit 2 }
            Invoke-ForcedReboot -Reason 'completing the deferred post-upgrade reboot'
            exit 2
        }

        if (-not $v.Passed) {
            Write-Log "VALIDATION FAILED - $($v.Failures.Count) issue(s). Marker retained; NO further hop will run on this box." 'ERROR'
            foreach ($f in $v.Failures) { Write-Log "  $f" 'ERROR' }
            exit 2
        }

        Write-Log 'VALIDATION PASSED - configuration, restore points, and offsite topology intact.'
        if ($PreflightOnly) { Write-Log 'Preflight-only: markers retained for a normal run to clear.'; exit 0 }
        Remove-Item -LiteralPath $StateFile -Force

        if ($UpgradeComponents) {
            Write-Log '--- Managed component upgrade ---'
            try {
                $cu = Invoke-ComponentUpgrade
                if ($cu) {
                    foreach ($l in @($cu.log)) { if ($l) { Write-Log $l } }
                    if ($cu.skipped) { Write-Log "Component upgrade skipped: $($cu.skipped)" 'WARN' }
                    elseif (-not $cu.ok) { Write-Log "Component upgrade error: $($cu.error)" 'WARN' }
                }
            } catch { Write-Log "Component upgrade failed: $($_.Exception.Message)" 'WARN' }
        }

        if (@($v.CopyNotYet).Count -gt 0) {
            [pscustomobject]@{
                sinceUtc = $state.upgradeTimeUtc; jobs = @($v.CopyNotYet)
                baselineFile = $state.baselineFile; hopTarget = $state.hopTarget
            } | ConvertTo-Json | Set-Content -LiteralPath $CopyWatchFile -Encoding UTF8 -Force
            Write-Log "OFFSITE COPY WATCH opened for: $($v.CopyNotYet -join ', ')."
        }

        $now = Get-InstalledVbrBuild
        if ($now.Build -lt $TargetBuild) {
            Write-Log "Validated at $($now.Build) - below target. Continuing to next hop in this run."
        }
        elseif (Test-Path -LiteralPath $CopyWatchFile) {
            Write-Log "TARGET REACHED AND VALIDATED ($($now.Build)) - OFFSITE COPY WATCH active. Exit 0 withheld until a post-upgrade copy session completes." 'WARN'
            Write-Log 'MANUAL STEP: VSPC/Service Provider Console dependencies cannot be upgraded by cmdlet - no such surface exists in the v13 module. Open the Veeam console AS ADMINISTRATOR on this device and accept the dependency prompt.' 'WARN'
            exit 2
        }
        else {
            Write-Log "TARGET REACHED AND VALIDATED: $($now.Build). Offsite copy exercised. Cleaning staged media."
            Remove-AllStagedMedia
            Write-Log 'MANUAL STEP: VSPC/Service Provider Console dependencies cannot be upgraded by cmdlet - no such surface exists in the v13 module. Open the Veeam console AS ADMINISTRATOR on this device and accept the dependency prompt.' 'WARN'
            exit 0
        }
    }

    # =========================================================================
    # PHASE 0.5 - OFFSITE COPY WATCH
    # =========================================================================
    if ((Test-Path -LiteralPath $CopyWatchFile) -and -not (Test-Path -LiteralPath $StateFile)) {
        $watch = Get-Content -LiteralPath $CopyWatchFile -Raw | ConvertFrom-Json
        $nowB = Get-InstalledVbrBuild
        if ($nowB.Build -ge $TargetBuild) {
            Write-Log "Offsite copy watch active since $($watch.sinceUtc) for: $($watch.jobs -join ', ')."
            Repair-VeeamServiceState -SettleSeconds $SvcStartSettleSecs
            $live = Get-VeeamLiveState
            if ($null -eq $live -or -not $live.ok) {
                Write-Log "Copy watch: Veeam query failed ($(if($live){$live.error}else{'no output'})). Re-run to retry." 'WARN'
                exit 2
            }
            $bl = Get-Content -LiteralPath $watch.baselineFile -Raw | ConvertFrom-Json
            $watchJobs = @($bl.copyJobs | Where-Object { [string]$_.name -in @($watch.jobs) })
            $cs = Get-PostUpgradeCopyStatus -BaselineCopyJobs $watchJobs -LiveSessions $live.sessions `
                    -SinceUtc ([datetime]::Parse($watch.sinceUtc).ToUniversalTime())

            if ($cs.Failed.Count -gt 0) {
                Write-Log 'OFFSITE COPY FAILED post-upgrade (was healthy at baseline):' 'ERROR'
                foreach ($f in $cs.Failed) { Write-Log "  $f" 'ERROR' }
                exit 2
            }
            $stillWaiting = @($cs.NotYet)
            if ($stillWaiting.Count -eq 0) {
                Write-Log "Offsite copy exercised post-upgrade: $($cs.Succeeded -join ', '). Watch cleared."
                if (-not $PreflightOnly) { Remove-Item -LiteralPath $CopyWatchFile -Force; Remove-AllStagedMedia }
                Write-Log "CONVERGED: at target $($nowB.Build), validated, offsite copy verified."
                exit 0
            }
            $ageH = ((Get-Date).ToUniversalTime() - [datetime]::Parse($watch.sinceUtc).ToUniversalTime()).TotalHours
            if ($ageH -ge $CopyWatchHours) {
                Write-Log "OFFSITE COPY has not run in $([math]::Round($ageH,1)) h post-upgrade for: $($stillWaiting -join ', '). Copies are hourly per standard - this is itself a finding." 'ERROR'
                exit 2
            }
            Write-Log "Offsite copy not yet observed for: $($stillWaiting -join ', ') ($([math]::Round($ageH,1)) h of $CopyWatchHours). Re-run after the next hourly copy cycle."
            exit 2
        }
    }

    # =========================================================================
    # STAGE 1 - Detect installed build and select track
    # =========================================================================
    $vbr = Get-InstalledVbrBuild
    $installed = $vbr.Build
    $arpVer = Get-VbrArpVersion
    Write-Log ("Installed build: {0} (file version) | ARP DisplayVersion: {1}" -f $installed, $(if ($arpVer) { $arpVer } else { '<not found>' }))

    if ($installed -ge $TargetBuild) {
        Write-Log "Already at or above target $TargetBuild (no pending markers). Nothing to do."
        exit 0
    }

    if ($installed -ge $GateBuild) {
        $track = 'DIRECT'; $isoUrl = $DownloadUrlV13; $isoName = $SaveFileV13
        $isoHash = $Sha256V13; $hopTarget = $TargetBuild; $hopMinimum = $TargetBuild
        $emitProactive = $true
    } else {
        $track = 'INTERMEDIATE'; $isoUrl = $DownloadUrlV12; $isoName = $SaveFileV12
        $isoHash = $Sha256V12; $hopTarget = [version]'12.3.2.4465'; $hopMinimum = $GateBuild
        $emitProactive = $false
    }
    Write-Log "Track: $track  ->  hop target $hopTarget (minimum acceptable: $hopMinimum)"

    if ([string]::IsNullOrWhiteSpace($isoUrl) -or [string]::IsNullOrWhiteSpace($isoName) -or [string]::IsNullOrWhiteSpace($isoHash)) {
        throw "Missing RMM variables for track $track (url / filename / sha256)."
    }

    $script:IsoFolder = Resolve-StagingFolder
    $stagingDrive = $script:IsoFolder.Substring(0,2)
    $isoPath   = Join-Path $script:IsoFolder $isoName
    $srcFolder = Join-Path $script:IsoFolder ('src_' + [IO.Path]::GetFileNameWithoutExtension($isoName))

    # =========================================================================
    # STAGE 2 - Preflight gates
    # =========================================================================
    Write-Log '--- Preflight ---'

    # Repository paths are needed before pruning, so query Veeam first.
    $pf = $null
    try { $pf = Get-VeeamPreflightState } catch { Add-Gate 'VeeamPowerShell' $false "Veeam query failed: $($_.Exception.Message)" }
    $repoPaths = @()
    if ($pf -and $pf.repoPaths) { $repoPaths = @($pf.repoPaths) }

    if (-not $PreflightOnly) {
        Repair-VeeamServiceState -SettleSeconds $SvcStartSettleSecs
        Remove-StaleInstallMedia -KeepIsoName $isoName -KeepSrcFolder $srcFolder
        Remove-OldVeeamLogs -RetentionDays $VeeamLogRetentionDays -RepoPaths $repoPaths
    }
    $isoStaged = Test-Path -LiteralPath $isoPath

    $pgSvc  = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'postgresql*' } | Select-Object -First 1
    $sqlSvc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'MSSQL$*' } | Select-Object -First 1
    if ($pgSvc)      { Write-Log "DB engine: PostgreSQL ($($pgSvc.Name)) - not upgraded, not stopped by this script." }
    elseif ($sqlSvc) { Write-Log "DB engine: MSSQL ($($sqlSvc.Name)) - not upgraded, not stopped by this script." }
    else             { Write-Log 'DB engine: no local postgresql*/MSSQL$* service found (remote or unknown).' 'WARN' }

    $pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                     (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    Add-Gate 'PendingReboot' (-not $pendingReboot) $(if ($pendingReboot) { 'Reboot pending' } else { 'Clear' })

    $minFree = if ($isoStaged) { $MinFreeGBStaged } else { $MinFreeGBUnstaged }
    $stagingVol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$stagingDrive'" -ErrorAction SilentlyContinue
    $freeGB  = if ($stagingVol) { [math]::Round($stagingVol.FreeSpace / 1GB, 1) } else { 0 }
    Add-Gate 'FreeSpace' ($freeGB -ge $minFree) "$freeGB GB free on $stagingDrive (need $minFree GB; ISO staged: $isoStaged)"

    # Veeam setup needs ~29.3 GB on C: for MSI extraction and component installs
    # no matter where the ISO is staged (event id=105, DTCBSURE-4244 and -4257).
    # v4.1 moved the whole gate to the staging volume and lost this check.
    $sysVol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
    $sysFreeGB = if ($sysVol) { [math]::Round($sysVol.FreeSpace / 1GB, 1) } else { 0 }
    Add-Gate 'SystemDriveFreeSpace' ($sysFreeGB -ge $MinFreeGBSystem) "$sysFreeGB GB free on C: (setup needs ~29.3 GB there regardless of staging volume; gate is $MinFreeGBSystem GB)"

    # v13 installs its own web service which legitimately binds 443 - only a
    # NON-Veeam listener is a genuine conflict (fleet: 17 halts became 0).
    $o443 = Get-PortOwner -Port 443
    $any443 = Test-PortListening -Port 443
    $veeam443 = ($o443 -and $o443 -match '(?i)veeam')
    Add-Gate 'Port443' ((-not $any443) -or $veeam443) $(
        if (-not $any443)  { 'Free' }
        elseif ($veeam443) { "Bound by $o443 (Veeam's own service - not a conflict)" }
        else               { "Bound by $(if ($o443) { $o443 } else { 'an unidentified process' })" })

    $console = Get-Process -Name 'Veeam.Backup.Shell' -ErrorAction SilentlyContinue
    Add-Gate 'ConsoleClosed' (-not $console) $(if ($console) { 'Console open' } else { 'Closed' })

    $latfp = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
                -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue).LocalAccountTokenFilterPolicy
    Add-Gate 'LocalAccountTokenFilterPolicy' ($latfp -eq 1) "Value=$(if ($null -eq $latfp) { '<absent>' } else { $latfp }) (expected 1)"

    $svcAcct = (Get-CimInstance Win32_Service -Filter "Name='VeeamBackupSvc'" -ErrorAction SilentlyContinue).StartName
    Add-Gate 'ServiceAccount' ($svcAcct -in @('LocalSystem','NT AUTHORITY\SYSTEM')) "Runs as '$svcAcct'"

    $vbsStatus = (Get-Service -Name 'VeeamBackupSvc' -ErrorAction SilentlyContinue).Status
    Add-Gate 'BackupServiceRunning' ($vbsStatus -eq 'Running') "VeeamBackupSvc=$vbsStatus"

    $listening9392 = Test-PortListening -Port 9392
    Add-Gate 'BackupServiceListening' $listening9392 $(if ($listening9392) { 'Listening on 9392' } else { 'Nothing listening on 9392 - service up but not serving' })

    $pwVer = $null
    if ($pwLoc) { try { $pwVer = (& $pwLoc -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null) } catch { } }
    Add-Gate 'Ps7Available' ([bool]$pwLoc) $(if ($pwLoc) { "pwsh $pwVer" } else { 'pwsh.exe NOT FOUND - required for the Veeam v13 PowerShell module.' })

    $adminOk = $false; $adminDetail = ''
    try {
        $u = Get-LocalUser -Name $InstallAdminUser -ErrorAction Stop
        $inAdmins = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -like "*\$InstallAdminUser" }).Count -gt 0
        $adminOk = ($u.Enabled -and $inAdmins)
        $adminDetail = "Enabled=$($u.Enabled) InAdministrators=$inAdmins"
    } catch { $adminDetail = "Account '$InstallAdminUser' not found: $($_.Exception.Message)" }
    Add-Gate 'InstallAdminAccount' $adminOk $adminDetail

    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $mgmt = @(Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '^Veeam Backup Enterprise Manager|^Veeam ONE' } |
        Select-Object -ExpandProperty DisplayName -Unique)
    Add-Gate 'NoCoResidentMgmt' ($mgmt.Count -eq 0) $(if ($mgmt.Count) { ($mgmt -join '; ') + ' present - must be upgraded before VBR' } else { 'None detected' })

    if ($pf -and $pf.ok) {
        if ($null -ne $pf.workingSessions) {
            Add-Gate 'NoActiveSessions' ([int]$pf.workingSessions -eq 0) $(
                if ([int]$pf.workingSessions -eq 0) { '0 session(s) working' }
                else { "$($pf.workingSessions) session(s) working ($($pf.workingJobNames)) - re-run outside the job window" })
        } else { Add-Gate 'NoActiveSessions' $false "Query failed: $($pf.workingSessionsError)" }

        if ($null -ne $pf.legacyChain) { Add-Gate 'LegacyChainFormat' ([int]$pf.legacyChain -eq 0) "$($pf.legacyChain) legacy-format backup(s) of $($pf.backupCount)" }
        else { Add-Gate 'LegacyChainFormat' $false "Query failed: $($pf.legacyChainError)" }

        if ($null -ne $pf.legacyCopyJobs) { Add-Gate 'LegacyBackupCopyJob' ([int]$pf.legacyCopyJobs -eq 0) "$($pf.legacyCopyJobs) legacy copy job(s)" }
        else { Add-Gate 'LegacyBackupCopyJob' $false "Query failed: $($pf.legacyCopyJobsError)" }

        if ($null -ne $pf.hardenedRepos) { Add-Gate 'NoHardenedRepo' ([int]$pf.hardenedRepos -eq 0) "$($pf.hardenedRepos) hardened repo(s)" }
        else { Add-Gate 'NoHardenedRepo' $false "Query failed: $($pf.hardenedReposError)" }

        Write-Log "OFFSITE: $($pf.objectRepoCount) object storage repo(s), $($pf.copyJobCount) copy job(s). Configuration backup: not evaluated (separate workstream)."
    } elseif ($pf) {
        Add-Gate 'VeeamPowerShell' $false "Veeam preflight query error: $($pf.error)"
    }

    # --- Report ---
    Write-Log '--- Gate results ---'
    foreach ($g in $gates) { Write-Log ("{0,-32} {1,-6} {2}" -f $g.Gate, $(if ($g.Pass) { 'PASS' } else { 'FAIL' }), $g.Detail) }
    $failed = @($gates | Where-Object { -not $_.Pass })

    if ($PreflightOnly) {
        Write-Log '--- Agent inventory (report only) ---'
        [void](Invoke-AgentRemediation -StaleDays $StaleAgentDays -RestorePointDays $StaleRestorePointDays -ReportOnly)
        Write-Log "PREFLIGHT-ONLY complete. $($failed.Count) gate(s) failed. No changes made."
        Write-Log 'NOTE: preflight-only skips disk reclamation, so FreeSpace reflects the uncleaned volume.' 'WARN'
        exit $(if ($failed.Count -gt 0) { 2 } else { 0 })
    }

    if ($failed.Count -gt 0) {
        Write-Log "HALTED - $($failed.Count) preflight gate(s) failed. Upgrade NOT attempted." 'ERROR'
        foreach ($g in $failed) { Write-Log ("  BLOCKED BY: {0} - {1}" -f $g.Gate, $g.Detail) 'ERROR' }
        if ($pendingReboot) { Invoke-ForcedReboot -Reason 'clearing pending reboot so the next run proceeds' }
        exit 2
    }
    Write-Log 'All preflight gates passed.'

    # =========================================================================
    # STAGE 2.6 - Retrieve AND VALIDATE install credential
    # =========================================================================
    Write-Log "Retrieving install credential from device field '$LapsFieldName' ..."
    $AdminPassword = Get-NinjaSecureField -FieldName $LapsFieldName
    if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
        throw "Could not retrieve '$LapsFieldName' from this device's custom fields. If the field exists, its Scripts permission must allow Read. The installer cannot run without the local admin credential (SYSTEM is refused by the Veeam setup engine)."
    }
    if (-not (Test-LocalCredential -User $InstallAdminUser -Password $AdminPassword)) {
        $AdminPassword = $null
        throw "The '$LapsFieldName' value does NOT authenticate for $env:COMPUTERNAME\$InstallAdminUser. LAPS has almost certainly rotated without the custom field being updated - the same fault as DTCBSURE-5043 (Security 4625, substatus 0xC000006A) and DTCBSURE-4910. Nothing was changed and no download was started."
    }
    Write-Log "Credential retrieved and validated for .\$InstallAdminUser (value not logged)."

    # =========================================================================
    # STAGE 2.7 - Agent blocker remediation
    # =========================================================================
    Write-Log '--- Agent remediation ---'
    $agentPre = Invoke-AgentRemediation -StaleDays $StaleAgentDays -RestorePointDays $StaleRestorePointDays
    if ($agentPre.Blocked.Count -gt 0) {
        Write-Log 'Agent(s) require a human decision - not auto-remediated:' 'WARN'
        foreach ($b in $agentPre.Blocked) { Write-Log "  $b" 'WARN' }
    }

    # =========================================================================
    # STAGE 2.5 - Baseline snapshot
    # =========================================================================
    Write-Log 'Capturing pre-upgrade baseline ...'
    $liveNow = Get-VeeamLiveState
    if ($null -eq $liveNow -or -not $liveNow.ok) {
        throw "Baseline capture failed: $(if($liveNow){$liveNow.error}else{'no output from the Veeam query'}). Proceeding without a baseline defeats post-upgrade validation."
    }
    $baseline = [ordered]@{
        capturedUtc = (Get-Date).ToUniversalTime().ToString('o')
        fromBuild   = [string]$installed
        services    = @(Get-Service -Name 'Veeam*' -ErrorAction SilentlyContinue | ForEach-Object {
                          [ordered]@{ name = [string]$_.Name; startType = [string]$_.StartType; status = [string]$_.Status } })
        jobs        = @($liveNow.jobs)
        repos       = @($liveNow.repos)
        objectRepos = @($liveNow.objectRepos)
        s3CredCount = [int]$liveNow.s3CredCount
        copyJobs    = @($liveNow.copyJobs)
        backups     = @($liveNow.backups)
    }
    $baseline | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $BaselineFile -Encoding UTF8 -Force
    Write-Log ("Baseline: {0} service(s), {1} job(s), {2} repo(s), {3} object repo(s), {4} S3 cred(s), {5} copy job(s), {6} backup object(s)" -f `
        @($baseline.services).Count, @($baseline.jobs).Count, @($baseline.repos).Count, @($baseline.objectRepos).Count,
        $baseline.s3CredCount, @($baseline.copyJobs).Count, @($baseline.backups).Count)

    # =========================================================================
    # STAGE 3 - Stage and verify ISO
    # =========================================================================
    if (-not (Test-Path -LiteralPath $script:IsoFolder)) { New-Item -Path $script:IsoFolder -ItemType Directory -Force | Out-Null }

    if (-not $isoStaged) { Write-Log "Downloading $isoName to $($script:IsoFolder) ..."; Invoke-IsoDownload -Url $isoUrl -Destination $isoPath }
    else { Write-Log "ISO already staged: $isoPath" }

    Write-Log 'Verifying SHA256 (several minutes on an 18 GB file) ...'
    if (-not (Test-IsoHash -Path $isoPath -Expected $isoHash)) {
        Write-Log 'SHA256 mismatch. Deleting and re-downloading once.' 'WARN'
        Remove-Item -LiteralPath $isoPath -Force
        Invoke-IsoDownload -Url $isoUrl -Destination $isoPath
        if (-not (Test-IsoHash -Path $isoPath -Expected $isoHash)) {
            Remove-Item -LiteralPath $isoPath -Force -ErrorAction SilentlyContinue
            throw "SHA256 mismatch after re-download. Expected $isoHash. Corrupt ISO deleted. NOTE: if the source is Veeam's CDN, an auth redirect (HTML instead of ISO) produces exactly this symptom."
        }
    }
    Write-Log 'SHA256 verified.'
    Unblock-File -LiteralPath $isoPath -ErrorAction SilentlyContinue

    # =========================================================================
    # STAGE 4 - Copy install source to writable local disk
    # =========================================================================
    $exe = Expand-IsoToLocal -IsoPath $isoPath -Destination $srcFolder
    Write-Log ("Setup engine: {0}" -f (Get-Item -LiteralPath $exe).VersionInfo.FileVersion)

    # =========================================================================
    # STAGE 5 - Answer file
    # =========================================================================
    $proactive = if ($emitProactive) { "`r`n        <property name=`"VBR_PROACTIVE_SUPPORT`" value=`"0`" />" } else { '' }
    $answerXml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattendedInstallationConfiguration bundle="Vbr" mode="upgrade" version="1.0">
    <properties>
        <property name="ACCEPT_EULA" value="1" />
        <property name="ACCEPT_LICENSING_POLICY" value="1" />
        <property name="ACCEPT_THIRDPARTY_LICENSES" value="1" />
        <property name="ACCEPT_REQUIRED_SOFTWARE" value="1" />
        <property name="VBR_LICENSE_AUTOUPDATE" value="1" />$proactive
        <property name="VBR_ENTRAID_DATABASE_INSTALL" value="0" />
        <property name="VBR_AUTO_UPGRADE" value="$AutoUpgrade" />
        <property name="REBOOT_IF_REQUIRED" value="0" />
    </properties>
</unattendedInstallationConfiguration>
"@
    $answerFile = Join-Path $LogFolder 'VbrAnswerFile_upgrade.xml'
    Set-Content -LiteralPath $answerFile -Value $answerXml -Encoding UTF8 -Force
    Write-Log "Answer file written (VBR_AUTO_UPGRADE=$AutoUpgrade, REBOOT_IF_REQUIRED=0)."

    # =========================================================================
    # STAGE 5.5 / 6 - Stop services and install
    # =========================================================================
    $code = -1; $upgradeStartUtc = $null; $attempt = 0; $partialSuccess = $false
    while ($attempt -lt $MaxInstallAttempts) {
        $attempt++
        Remove-Item -LiteralPath $DbReportFile -Force -ErrorAction SilentlyContinue

        if (-not (Stop-VeeamForUpgrade -TimeoutSeconds $SvcStopTimeoutSecs)) {
            Write-Log 'Graceful stop did not complete. NOT force-killing the service - that wedged this platform previously. Nothing on this box was changed.' 'WARN'
            Invoke-ForcedReboot -Reason 'clean-boot retry before install'
            exit 2
        }

        $upgradeStartUtc = (Get-Date).ToUniversalTime().ToString('o')
        Write-Log "Starting upgrade to $hopTarget as $env:COMPUTERNAME\$InstallAdminUser (attempt $attempt of $MaxInstallAttempts). This will take a while."
        $code = [int](Invoke-InstallerAsLocalAdmin -InstallerExe $exe -AnswerFile $answerFile `
            -InstallLogFolder $LogFolder -User $InstallAdminUser -PlainPassword $AdminPassword)
        Write-Log "Installer exit code: $code"

        Write-InstallerResultXml -SinceUtc ([datetime]::Parse($upgradeStartUtc).ToUniversalTime())
        Restore-VeeamServiceRecovery
        Repair-VeeamServiceState -SettleSeconds $SvcStartSettleSecs

        if ($code -eq 0 -or $code -eq 3010) { break }

        $probe = $null
        try { $probe = Get-InstalledVbrBuild } catch { }
        if ($probe -and $probe.Build -ge $hopMinimum) {
            Write-Log "Installer returned $code, but the core product is at $($probe.Build) (>= required $hopMinimum). PARTIAL SUCCESS - an ancillary component failed:" 'WARN'
            Write-FailedComponentSummary -SinceUtc ([datetime]::Parse($upgradeStartUtc).ToUniversalTime())
            $partialSuccess = $true
            break
        }

        if ($attempt -ge $MaxInstallAttempts) { break }

        $blockers = Get-SetupReportAgentBlockers -ReportPath $DbReportFile
        if ($blockers.OtherErrors.Count -gt 0) {
            Write-Log ("Setup reported blocking error(s) this script cannot remediate: {0}" -f (($blockers.OtherErrors | Select-Object -Unique) -join '; ')) 'ERROR'
            break
        }
        if ($blockers.Names.Count -eq 0) { Write-Log 'No remediable agent blockers found in the setup report - not retrying.' 'WARN'; break }

        Write-Log ("Setup blocked on {0} agent(s): {1}. Remediating and retrying the install once." -f $blockers.Names.Count, ($blockers.Names -join ', ')) 'WARN'
        $fix = Invoke-AgentRemediation -TargetNames $blockers.Names -StaleDays $StaleAgentDays -RestorePointDays $StaleRestorePointDays
        if (($fix.Removed.Count + $fix.Upgraded.Count) -eq 0) {
            Write-Log 'None of the blocking agents could be remediated automatically:' 'ERROR'
            foreach ($b in $fix.Blocked) { Write-Log "  $b" 'ERROR' }
            break
        }
    }

    $AdminPassword = $null

    if (-not $partialSuccess -and $code -ne 0 -and $code -ne 3010) {
        $probe2 = $null
        try { $probe2 = Get-InstalledVbrBuild } catch { }
        throw "Upgrade failed with exit code $code after $attempt attempt(s); installed build $(if ($probe2) { $probe2.Build } else { 'unreadable' }) did not reach $hopMinimum. See $LogFolder and $SetupTempFolder."
    }

    # =========================================================================
    # STAGE 7 - Verify, write state marker, reboot
    # =========================================================================
    $post = Get-InstalledVbrBuild
    Write-Log "Post-upgrade build: $($post.Build)"
    if ($post.Build -lt $hopMinimum) {
        if ($code -eq 3010) {
            # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED. Setup installed a prerequisite
            # and stopped deliberately BEFORE the product install - DTCBSURE-4947:
            # event id="012" "Reboot is required to finalize prerequisites
            # installation" / Microsoft Visual C++ 2017-2026 Redistributable.
            # Reboot and re-run; the hop completes on the next pass. NOT a failure.
            Write-Log 'Installer returned 3010 with the build unchanged: a prerequisite was installed and needs a reboot before setup will proceed. Rebooting; the next run performs the upgrade.' 'WARN'
            $exitCode = 2
            Invoke-ForcedReboot -Reason 'finalizing installer prerequisites before the upgrade'
            exit $exitCode
        }
        throw "Build did not advance to hop minimum $hopMinimum (found $($post.Build)) although the installer reported $code. Setup exited without upgrading - check $SetupTempFolder for a SuiteEngine log from this run; if none exists, setup never started."
    }
    if ($post.Build -lt $hopTarget) {
        Write-Log "Build $($post.Build) is below the ISO label ($hopTarget) but clears the required floor ($hopMinimum) - acceptable; next run takes the DIRECT track." 'WARN'
    }

    $svc = Get-CimInstance Win32_Service -Filter "Name='VeeamBackupSvc'" -ErrorAction SilentlyContinue
    if (-not $svc) { throw 'Post-upgrade: VeeamBackupSvc is not registered.' }
    if ($svc.StartMode -ne 'Auto') {
        Write-Log "VeeamBackupSvc StartMode is '$($svc.StartMode)' - setting to Automatic." 'WARN'
        Set-Service -Name 'VeeamBackupSvc' -StartupType Automatic
    }

    $svcAll  = @(Get-CimInstance Win32_Service -Filter "Name LIKE 'Veeam%'")
    $svcDown = @($svcAll | Where-Object { $_.State -ne 'Running' })
    Write-Log ("Veeam services pre-reboot: {0} total, {1} running{2}" -f $svcAll.Count, ($svcAll.Count - $svcDown.Count),
        $(if ($svcDown.Count) { "; not running: " + (($svcDown | Select-Object -ExpandProperty Name) -join ', ') } else { '' }))

    $ctlKey = 'HKLM:\SYSTEM\CurrentControlSet\Control'
    $prior  = (Get-ItemProperty -Path $ctlKey -Name 'ServicesPipeTimeout' -ErrorAction SilentlyContinue).ServicesPipeTimeout
    if (-not $prior -or $prior -lt $RestSvcTimeoutMs) {
        Set-ItemProperty -Path $ctlKey -Name 'ServicesPipeTimeout' -Value $RestSvcTimeoutMs -Type DWord
        Write-Log "ServicesPipeTimeout set to $RestSvcTimeoutMs ms (takes effect on the reboot below)."
    }

    [pscustomobject]@{
        fromBuild = [string]$installed; hopTarget = [string]$hopTarget; hopMinimum = [string]$hopMinimum
        upgradeTimeUtc = $upgradeStartUtc; baselineFile = $BaselineFile
        installerCode = $code; partialSuccess = $partialSuccess
        stagingFolder = $script:IsoFolder
    } | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8 -Force
    Write-Log 'State marker written (next run validates).'

    Write-Log "HOP COMPLETE ($installed -> $($post.Build))$(if ($partialSuccess) { ' [PARTIAL]' }). Exit 2 = validation pending on next run."
    $exitCode = 2
    Invoke-ForcedReboot -Reason "finalizing hop to $hopTarget"
    exit $exitCode
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    $exitCode = 1
}
finally {
    $AdminPassword = $null
    try { Restore-VeeamServiceRecovery } catch { }
    try { Unregister-ScheduledTask -TaskName $InstallTaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    if ($mountedIso) { try { Dismount-DiskImage -ImagePath $mountedIso | Out-Null } catch { } }
    Get-ChildItem -LiteralPath $LogFolder -Filter 'veeamq_*.ps1' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    try { Stop-Transcript | Out-Null } catch { }
    if ($haveMutex) { try { $mutex.ReleaseMutex() } catch { } }
}

exit $exitCode