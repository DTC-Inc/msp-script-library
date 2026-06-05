<#
.SYNOPSIS
  NinjaOne Backup - Lockhart Remediation / Repair. Diagnoses and repairs failed
  NinjaOne Backup jobs by examining the Lockhart service and its dependencies,
  then restoring the device to a backup-ready state when safe to do so.

.DESCRIPTION
  Responds to NinjaOne condition "Backup Job Last success 25 hours ago"
  (policy 58). Flow: HV0-skip -> CHECK -> DIAGNOSE -> REPAIR (gated) ->
  CONFIRM -> STATE.

  Excluded hosts: any hostname matching ^HV0 (Hyper-V hosts). Checked at
  entry point before any file writes, transcript, or mutex creation.

  RMM INTEGRATION (per repo CLAUDE.md):
    - Execution context detected via $env:RMM ('1' = RMM mode).
    - NinjaRMM passes script preset variables as ENVIRONMENT variables.
      Every parameter below can be overridden by a same-named NinjaOne
      script variable. In particular the NOC checkboxes:
        ForceDisruptiveRepairs=1  and  ClearStateAndExit=1
      are read from $env: (CLI switches also work for interactive use).
    - $env:Description captured for audit trail.
    - Transcript logging: $env:RMMScriptPath\logs\ in RMM mode (fallback
      $env:WINDIR\logs\), $env:WINDIR\logs\ interactive. 10MB rotation.
    - Template deviation (deliberate): no Read-Host prompts. This script
      is condition-triggered automation and must never block on input;
      a hung prompt would silence backup remediation fleet-wide.

  Device-offline short-circuit (sole reason, no counter increment):
    - Public internet unreachable
    - System uptime < MinUptimeMinutes

  Business hours gating (default 07:00-18:00 device-local):
    During business hours, these repairs defer to off-hours:
      - Dnscache service restart
      - ARP cache clear
      - VSS DLL re-registration (escalation)
      - NinjaRMMAgent restart (escalation)
    Override with -ForceDisruptiveRepairs or env ForceDisruptiveRepairs=1.

  Anytime repairs:
    - DNS cache flush
    - Time resync
    - Windows\Temp cleanup
    - NinjaRMMAgent start (if stopped)
    - VSS stack reset
    - Force-kill stuck Lockhart
    - Lockhart start/restart

  Diagnosed but not repaired (forensic capture, NOC escalation):
    - Cloud endpoints unreachable post-repair
    - DNS / default gateway unreachable post-repair
    - AV quarantine of lockhart.exe
    - Lockhart binary missing
    - agent.yaml missing or corrupt
    - Disk space critically low post-cleanup

  Counter: tracks remediation INTERVENTIONS (successful or not) within the
  CounterResetHours window. Auto-reset after a 48h gap, or when a run finds
  everything healthy with no repairs needed (AlreadyHealthy_CounterCleared).
  No increment on DeviceOffline*, RemediationDeferred, or LiveJobSkipped.
  Guardrail at MaxConsecutiveAttempts interventions - needing repeated
  intervention, even successful, indicates a recurring root cause that
  requires human investigation.

  Auto-close: NinjaOne condition clears alert + Halo ticket when next
  scheduled backup succeeds. Script does not touch alert or Halo flow.

.PARAMETER SampleSeconds
  Duration of process I/O + CPU sampling window for live backup detection.
  Default 90. Lower = faster runs but more false-positive "stuck" classifications.

.PARAMETER ActiveIoThresholdMB
  Process I/O delta in MB over SampleSeconds that indicates an active backup.
  Default 10.

.PARAMETER ActiveCpuThresholdSec
  Process CPU delta in seconds over SampleSeconds that indicates active work.
  Default 5.0.

.PARAMETER MaxConsecutiveAttempts
  Number of consecutive remediation interventions (successful or failed)
  within the CounterResetHours window before the script stops acting and
  escalates to NOC. Repeated interventions - even when each one succeeds -
  indicate a recurring underlying issue. Default 2.

.PARAMETER CounterResetHours
  Hours of no script execution before the intervention counter auto-resets.
  Default 48 (the condition wouldn't re-fire if backups were working).

.PARAMETER MinFreeSpacePercent
  Minimum system drive free space percentage. Below this triggers temp cleanup
  and is reported as a hard blocker if cleanup doesn't recover it. Default 10.

.PARAMETER NetTestTimeoutMs
  TCP connection test timeout per endpoint in milliseconds. Default 5000.

.PARAMETER DnsTimeoutMs
  DNS resolution test timeout per host in milliseconds. Default 4000.

.PARAMETER TempCleanupMinAgeDays
  Files in Windows\Temp older than this many days are eligible for cleanup
  when free space is low. Default 7.

.PARAMETER MaxRuntimeSeconds
  Hard cap on total script runtime. Background job force-kills the script
  process if this is exceeded. Default 400.

.PARAMETER HistoryRetentionEntries
  Number of historical run entries kept in the state file. Default 20.

.PARAMETER TimeSkewToleranceMinutes
  Time sync age (minutes since last successful w32tm sync) above which
  triggers a resync. Default 5.

.PARAMETER BusinessHoursStartHour
  Hour of day (0-23, device-local time) when business hours start. Default 7.

.PARAMETER BusinessHoursEndHour
  Hour of day (0-23, device-local time) when business hours end. Default 18.

.PARAMETER MinUptimeMinutes
  System uptime below this triggers DeviceOffline_RecentReboot. Default 30.

.PARAMETER ForceDisruptiveRepairs
  Override business-hours gating and allow disruptive repairs immediately.
  RMM: set NinjaOne script variable ForceDisruptiveRepairs (Checkbox) - read
  via $env:ForceDisruptiveRepairs per repo convention. CLI switch works for
  interactive runs.

.PARAMETER ClearStateAndExit
  Wipe state file and exit without remediation. Used by NOC after manually
  resolving an underlying issue on a device sitting at MaxAttemptsReached.
  RMM: set NinjaOne script variable ClearStateAndExit (Checkbox) - read via
  $env:ClearStateAndExit per repo convention. CLI switch works for
  interactive runs.

.NOTES
  Author:    Zachary Boogher, DTC
  Date:      2026-06-03
  Version:   8.0
  Repo:      dtc-inc/msp-script-library
  Path:      rmm-ninja/lockhart-remediation.ps1
  Target:    PowerShell 5.1 (NinjaOne)
  Requires:  LocalSystem / Administrator privileges
  Runtime:   ~120-180 seconds typical
  Exit:      0 = success / not applicable / live job skipped / deferred
             1 = remediation failed or hard blocker
             2 = max attempts reached, NOC must investigate
#>

## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $RMM - Set to 1 when running from RMM (selects RMMScriptPath log location)
## $Description - Ticket # or initials for audit trail (optional; defaulted if blank)
## $ForceDisruptiveRepairs - 1 to override business-hours gating (Checkbox)
## $ClearStateAndExit - 1 to wipe remediation state file and exit (Checkbox)
## Optional tuning overrides (advanced; same names as parameters):
## $SampleSeconds, $ActiveIoThresholdMB, $ActiveCpuThresholdSec,
## $MaxConsecutiveAttempts, $CounterResetHours, $MinFreeSpacePercent,
## $NetTestTimeoutMs, $DnsTimeoutMs, $TempCleanupMinAgeDays,
## $MaxRuntimeSeconds, $HistoryRetentionEntries, $TimeSkewToleranceMinutes,
## $BusinessHoursStartHour, $BusinessHoursEndHour, $MinUptimeMinutes

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'All parameters consumed by Invoke-LockhartRemediation via script-scope variable inheritance; PSScriptAnalyzer does not follow control flow into nested function calls.')]
[CmdletBinding()]
param(
    [int]$SampleSeconds            = 90,
    [int]$ActiveIoThresholdMB      = 10,
    [double]$ActiveCpuThresholdSec = 5.0,
    [int]$MaxConsecutiveAttempts   = 2,
    [int]$CounterResetHours        = 48,
    [int]$MinFreeSpacePercent      = 10,
    [int]$NetTestTimeoutMs         = 5000,
    [int]$DnsTimeoutMs             = 4000,
    [int]$TempCleanupMinAgeDays    = 7,
    [int]$MaxRuntimeSeconds        = 400,
    [int]$HistoryRetentionEntries  = 20,
    [int]$TimeSkewToleranceMinutes = 5,
    [int]$BusinessHoursStartHour   = 7,
    [int]$BusinessHoursEndHour     = 18,
    [int]$MinUptimeMinutes         = 30,
    [switch]$ForceDisruptiveRepairs,
    [switch]$ClearStateAndExit
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ============================================================
# INPUT HANDLING SECTION (per CLAUDE.md / script-template-powershell.ps1)
# NinjaRMM passes preset variables as ENVIRONMENT variables. Bare param
# references do not bind from env vars, so every RMM-suppliable value is
# resolved here: env var wins when present and valid, else the param/default.
# NOTE (template deviation, deliberate): no Read-Host. This script is
# condition-triggered automation and must never block on input - a hung
# prompt would silence backup remediation fleet-wide if the RMM preset
# were ever missing. Interactive runs use parameter defaults instead.
# ============================================================
function Get-RmmInt {
    param([string]$Name, [int]$Current)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($v -match '^\d+$') { return [int]$v }
    return $Current
}

function Get-RmmDouble {
    param([string]$Name, [double]$Current)
    $v = [Environment]::GetEnvironmentVariable($Name)
    $out = 0.0
    if (-not [string]::IsNullOrWhiteSpace($v) -and [double]::TryParse($v, [ref]$out)) { return $out }
    return $Current
}

function Test-RmmFlag {
    param([string]$Name)
    return ([Environment]::GetEnvironmentVariable($Name) -match '^(?i)(1|true|yes|on)$')
}

# Numeric tunables: env override -> param -> default
$SampleSeconds            = Get-RmmInt    'SampleSeconds'            $SampleSeconds
$ActiveIoThresholdMB      = Get-RmmInt    'ActiveIoThresholdMB'      $ActiveIoThresholdMB
$ActiveCpuThresholdSec    = Get-RmmDouble 'ActiveCpuThresholdSec'    $ActiveCpuThresholdSec
$MaxConsecutiveAttempts   = Get-RmmInt    'MaxConsecutiveAttempts'   $MaxConsecutiveAttempts
$CounterResetHours        = Get-RmmInt    'CounterResetHours'        $CounterResetHours
$MinFreeSpacePercent      = Get-RmmInt    'MinFreeSpacePercent'      $MinFreeSpacePercent
$NetTestTimeoutMs         = Get-RmmInt    'NetTestTimeoutMs'         $NetTestTimeoutMs
$DnsTimeoutMs             = Get-RmmInt    'DnsTimeoutMs'             $DnsTimeoutMs
$TempCleanupMinAgeDays    = Get-RmmInt    'TempCleanupMinAgeDays'    $TempCleanupMinAgeDays
$MaxRuntimeSeconds        = Get-RmmInt    'MaxRuntimeSeconds'        $MaxRuntimeSeconds
$HistoryRetentionEntries  = Get-RmmInt    'HistoryRetentionEntries'  $HistoryRetentionEntries
$TimeSkewToleranceMinutes = Get-RmmInt    'TimeSkewToleranceMinutes' $TimeSkewToleranceMinutes
$BusinessHoursStartHour   = Get-RmmInt    'BusinessHoursStartHour'   $BusinessHoursStartHour
$BusinessHoursEndHour     = Get-RmmInt    'BusinessHoursEndHour'     $BusinessHoursEndHour
$MinUptimeMinutes         = Get-RmmInt    'MinUptimeMinutes'         $MinUptimeMinutes

# NOC checkboxes: env var (NinjaOne UI path) OR CLI switch (interactive path)
$script:ForceDisruptiveResolved = $ForceDisruptiveRepairs.IsPresent -or (Test-RmmFlag 'ForceDisruptiveRepairs')
$script:ClearStateResolved      = $ClearStateAndExit.IsPresent      -or (Test-RmmFlag 'ClearStateAndExit')

# Execution context + audit trail (env vars are strings: compare against '1')
$script:IsRmmMode   = ($env:RMM -eq '1')
$script:Description = if (-not [string]::IsNullOrWhiteSpace($env:Description)) { $env:Description }
                      else { 'No description provided (automated condition trigger)' }

# Transcript log path per CLAUDE.md: SYSTEM-context script
$script:ScriptLogName = 'lockhart-remediation.log'
if ($script:IsRmmMode -and -not [string]::IsNullOrWhiteSpace($env:RMMScriptPath)) {
    $script:LogPath = Join-Path $env:RMMScriptPath "logs\$($script:ScriptLogName)"
} else {
    $script:LogPath = Join-Path $env:WINDIR "logs\$($script:ScriptLogName)"
}

# =================== constants ===================
$script:ServiceName     = 'Lockhart'
$script:ParentAgentName = 'NinjaRMMAgent'
$script:MutexName       = 'Global\DTC_NinjaOneBackup_LockhartRemediation_v8'
$script:CloudEndpoints  = @(
    @{ Host='app.ninjarmm.com';           Port=443 },
    @{ Host='backup.ninjarmm.com';        Port=443 },
    @{ Host='s3.amazonaws.com';           Port=443 },
    @{ Host='s3.us-east-1.amazonaws.com'; Port=443 }
)
$script:OldStateFile = 'C:\ProgramData\DTC\lockhart_autoremediation.json'  # legacy v5/v6 location

# =================== logging ===================
function Write-DTCLog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'NinjaOne captures Write-Host output for script result display; Write-Information is suppressed by default in NinjaOne agent context.')]
    [CmdletBinding()]
    param(
        [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level,
        [string]$Message
    )
    Write-Host "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))][$Level] $Message"
}

# =================== transcript ===================
function Start-RemediationTranscript {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Script runs unattended via NinjaOne; ShouldProcess support is dead code in this runtime.')]
    [CmdletBinding()]
    param()
    try {
        $dir = Split-Path $script:LogPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ((Test-Path $script:LogPath) -and ((Get-Item $script:LogPath).Length -gt 10MB)) {
            Move-Item -Path $script:LogPath -Destination "$($script:LogPath).old" -Force
        }
        Start-Transcript -Path $script:LogPath -Append -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-Verbose "Transcript start failed (continuing without): $_"
        return $false
    }
}

# =================== device class ===================
function Get-DeviceClass {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ($os.ProductType -in @(2,3)) { return 'Server' }
        return 'Workstation'
    } catch {
        Write-Verbose "Get-DeviceClass failed, defaulting to Workstation: $_"
        return 'Workstation'
    }
}

# =================== paths (resolved after device class detection) ===================
function Initialize-Path {
    param([string]$DeviceClass)
    $base = if ($DeviceClass -eq 'Server') { 'C:\DTC' } else { 'C:\ProgramData\DTC' }
    $script:StateDir     = $base
    $script:StateFile    = Join-Path $base 'lockhart_autoremediation.json'
    $script:ForensicsDir = Join-Path $base 'Forensics'
}

function Move-LegacyStateFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Script runs unattended via NinjaOne; ShouldProcess support is dead code in this runtime.')]
    [CmdletBinding()]
    param()
    if ($script:StateFile -eq $script:OldStateFile) { return }
    if (Test-Path $script:StateFile) { return }
    if (-not (Test-Path $script:OldStateFile)) { return }
    try {
        if (-not (Test-Path $script:StateDir)) { New-Item -Path $script:StateDir -ItemType Directory -Force | Out-Null }
        Move-Item -Path $script:OldStateFile -Destination $script:StateFile -Force -ErrorAction Stop
        Write-DTCLog INFO "Migrated state file from $($script:OldStateFile) to $($script:StateFile)"
    } catch {
        Write-Verbose "Legacy state migration failed (continuing with empty state): $_"
    }
}

# =================== business hours ===================
function Test-WithinBusinessHours {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = '"BusinessHours" is a compound noun for the configured operating window; singular changes meaning.')]
    param([int]$StartHour, [int]$EndHour)
    $h = (Get-Date).Hour
    return ($h -ge $StartHour -and $h -lt $EndHour)
}

# =================== state file ===================
function Get-State {
    if (-not (Test-Path $script:StateDir)) { New-Item -Path $script:StateDir -ItemType Directory -Force | Out-Null }
    if (Test-Path $script:StateFile) {
        try {
            return Get-Content $script:StateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-DTCLog WARN "State file unreadable, resetting: $_"
        }
    }
    return [PSCustomObject]@{
        ConsecutiveAttempts = 0
        LastRun             = $null
        LastResult          = 'Unknown'
        History             = @()
    }
}

function Set-State {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Script runs unattended via NinjaOne; ShouldProcess support is dead code in this runtime.')]
    [CmdletBinding()]
    param($State)
    if ($State.History.Count -gt $HistoryRetentionEntries) {
        $State.History = @($State.History | Select-Object -First $HistoryRetentionEntries)
    }
    try {
        $State | ConvertTo-Json -Depth 8 | Set-Content -Path $script:StateFile -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-DTCLog ERROR "Failed to write state file: $_"
    }
}

# =================== diagnostics ===================
function Get-SystemUptime {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        return [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalMinutes, 1)
    } catch {
        Write-Verbose "Get-SystemUptime failed: $_"
        return $null
    }
}

function Test-PublicInternet {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '',
        Justification = '1.1.1.1 (Cloudflare DNS) is the intentional public internet reachability probe, not a managed device.')]
    [CmdletBinding()]
    param()
    try { return [bool](Test-Connection -ComputerName '1.1.1.1' -Count 2 -Quiet -ErrorAction SilentlyContinue) }
    catch {
        Write-Verbose "Test-PublicInternet failed: $_"
        return $false
    }
}

function Test-TcpEndpoint {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async) | Out-Null
        return $true
    } catch {
        Write-Verbose "Test-TcpEndpoint $TargetHost`:$Port failed: $_"
        return $false
    } finally {
        try { $client.Close() } catch { Write-Verbose "TcpClient close failed (expected during cleanup): $_" }
    }
}

function Test-DnsResolutionWithTimeout {
    param([string]$TargetHost, [int]$TimeoutMs)
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({ param($h) try { [System.Net.Dns]::GetHostAddresses($h) | Out-Null; $true } catch { $false } }).AddArgument($TargetHost)
    $async = $ps.BeginInvoke()
    if ($async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
        try { return [bool]($ps.EndInvoke($async))[0] }
        catch {
            Write-Verbose "DNS EndInvoke failed for $TargetHost`: $_"
            return $false
        } finally { $ps.Dispose() }
    } else {
        try { $ps.Stop() } catch { Write-Verbose "PS.Stop failed for DNS timeout: $_" }
        $ps.Dispose()
        return $false
    }
}

$script:ServiceCache = @{}
function Get-ServiceState {
    param([string]$Name, [switch]$Refresh)
    if ($Refresh -or -not $script:ServiceCache.ContainsKey($Name)) {
        $cim = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
        if (-not $cim) {
            $script:ServiceCache[$Name] = [PSCustomObject]@{
                Exists=$false; State='NotInstalled'; ProcessId=0; PathName=$null; StartMode=$null
            }
        } else {
            $script:ServiceCache[$Name] = [PSCustomObject]@{
                Exists=$true; State=$cim.State; ProcessId=$cim.ProcessId
                PathName=$cim.PathName; StartMode=$cim.StartMode
            }
        }
    }
    return $script:ServiceCache[$Name]
}

function Get-ExePathFromService {
    param($SvcInfo)
    if (-not $SvcInfo -or -not $SvcInfo.PathName) { return $null }
    if ($SvcInfo.PathName.StartsWith('"')) {
        return $SvcInfo.PathName.Substring(1).Split('"')[0]
    }
    return ($SvcInfo.PathName -split ' ')[0]
}

function Get-BinaryVersion {
    param([string]$Path)
    try {
        if (Test-Path $Path) { return (Get-Item $Path).VersionInfo.FileVersion }
    } catch {
        Write-Verbose "Get-BinaryVersion failed for $Path`: $_"
    }
    return $null
}

function Test-AgentYaml {
    param($LockhartSvcInfo)
    $exe = Get-ExePathFromService -SvcInfo $LockhartSvcInfo
    if (-not $exe) { return [PSCustomObject]@{ Exists=$false; Readable=$false; Valid=$false; Path=$null } }
    $yamlPath = Join-Path (Split-Path $exe) 'agent.yaml'
    if (-not (Test-Path $yamlPath)) {
        return [PSCustomObject]@{ Exists=$false; Readable=$false; Valid=$false; Path=$yamlPath }
    }
    try {
        $content = Get-Content $yamlPath -Raw -ErrorAction Stop
        $valid = ($content -match 'logs:') -and ($content -match 'backup:')
        return [PSCustomObject]@{
            Exists=$true; Readable=$true; Valid=$valid; Path=$yamlPath
            SizeBytes=(Get-Item $yamlPath).Length
        }
    } catch {
        Write-Verbose "Test-AgentYaml read failed: $_"
        return [PSCustomObject]@{ Exists=$true; Readable=$false; Valid=$false; Path=$yamlPath }
    }
}

function Get-SystemDriveFreePct {
    try {
        $d = Get-PSDrive -Name ($env:SystemDrive[0]) -ErrorAction Stop
        $total = $d.Used + $d.Free
        if ($total -le 0) { return $null }
        return [math]::Round(($d.Free / $total) * 100, 1)
    } catch {
        Write-Verbose "Get-SystemDriveFreePct failed: $_"
        return $null
    }
}

function Measure-ProcessActivity {
    param([int]$TargetPid, [int]$Seconds)
    $p1 = Get-CimInstance Win32_Process -Filter "ProcessId=$TargetPid" -ErrorAction SilentlyContinue
    if (-not $p1) { return [PSCustomObject]@{ DeltaMB=0; CpuDeltaSec=0; ProcessAlive=$false } }
    $r1=[int64]$p1.ReadTransferCount; $w1=[int64]$p1.WriteTransferCount; $o1=[int64]$p1.OtherTransferCount
    $k1=[int64]$p1.KernelModeTime;    $u1=[int64]$p1.UserModeTime
    Start-Sleep -Seconds $Seconds
    $p2 = Get-CimInstance Win32_Process -Filter "ProcessId=$TargetPid" -ErrorAction SilentlyContinue
    if (-not $p2) { return [PSCustomObject]@{ DeltaMB=0; CpuDeltaSec=0; ProcessAlive=$false } }
    $deltaBytes = ([int64]$p2.ReadTransferCount - $r1) + ([int64]$p2.WriteTransferCount - $w1) + ([int64]$p2.OtherTransferCount - $o1)
    $cpuTicks   = ([int64]$p2.KernelModeTime - $k1) + ([int64]$p2.UserModeTime - $u1)
    return [PSCustomObject]@{
        DeltaMB      = [math]::Round($deltaBytes/1MB, 2)
        CpuDeltaSec  = [math]::Round($cpuTicks/10000000, 2)
        ProcessAlive = $true
    }
}

function Get-NetworkForensics {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '',
        Justification = '1.1.1.1 (Cloudflare DNS) is the intentional public internet reachability probe.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = '"Forensics" is a collective noun describing aggregated diagnostic output; singular is grammatically incorrect.')]
    [CmdletBinding()]
    param()
    $f = [ordered]@{}
    try {
        $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
               Sort-Object RouteMetric | Select-Object -First 1).NextHop
        $f.DefaultGateway = $gw
        if ($gw) { $f.GatewayReachable = [bool](Test-Connection -ComputerName $gw -Count 1 -Quiet -ErrorAction SilentlyContinue) }
    } catch {
        Write-Verbose "Default gateway probe failed: $_"
        $f.DefaultGateway = $null
    }
    try {
        $dns = (Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.ServerAddresses.Count -gt 0 -and $_.InterfaceAlias -notmatch 'Loopback|Bluetooth|isatap' } |
                Select-Object -First 1).ServerAddresses
        $f.DnsServers = ($dns -join ',')
        if ($dns -and $dns.Count -gt 0) {
            $f.DnsServerReachable = [bool](Test-Connection -ComputerName $dns[0] -Count 1 -Quiet -ErrorAction SilentlyContinue)
        }
    } catch {
        Write-Verbose "DNS server probe failed: $_"
        $f.DnsServers = $null
    }
    try {
        $proxy = & netsh winhttp show proxy 2>$null | Out-String
        $f.WinHttpProxy = if ($proxy -match 'Direct access') { 'Direct' }
                          elseif ($proxy -match 'Proxy Server\(s\)\s*:\s*(\S+)') { $matches[1] }
                          else { 'Unknown' }
    } catch {
        Write-Verbose "WinHTTP proxy query failed: $_"
        $f.WinHttpProxy = 'QueryFailed'
    }
    try {
        $f.NetworkProfile = (Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1).NetworkCategory
    } catch {
        Write-Verbose "Network profile query failed: $_"
        $f.NetworkProfile = $null
    }
    try {
        $f.PublicInternetReachable = [bool](Test-Connection -ComputerName '1.1.1.1' -Count 1 -Quiet -ErrorAction SilentlyContinue)
    } catch {
        Write-Verbose "Public internet test failed: $_"
        $f.PublicInternetReachable = $null
    }
    return [PSCustomObject]$f
}

function Get-TimeSyncAge {
    try {
        $out = & w32tm /query /status 2>$null | Out-String
        if ($out -match 'Last Successful Sync Time:\s*(.+)') {
            $lastSync = [datetime]::Parse($matches[1].Trim())
            return [math]::Round(((Get-Date) - $lastSync).TotalMinutes, 1)
        }
    } catch {
        Write-Verbose "Time sync age query failed: $_"
    }
    return $null
}

function Get-AvQuarantineEventsForLockhart {
    try {
        $cutoff = (Get-Date).AddHours(-24)
        $events = Get-WinEvent -FilterHashtable @{
            LogName='Microsoft-Windows-Windows Defender/Operational'
            Id=@(1116,1117)
            StartTime=$cutoff
        } -ErrorAction SilentlyContinue |
            Where-Object { $_.Message -match 'lockhart|NinjaRMM|ninjarmmagent' }
        if ($events) {
            return @($events | ForEach-Object {
                "$($_.TimeCreated.ToString('s')) ID=$($_.Id) - $($_.Message.Substring(0,[Math]::Min(200,$_.Message.Length)))"
            })
        }
        return @()
    } catch {
        Write-Verbose "AV event query failed: $_"
        return @()
    }
}

# =================== repairs ===================
function Invoke-StartService {
    param([string]$Name)
    try {
        Start-Service -Name $Name -ErrorAction Stop
        Start-Sleep -Seconds 5
        return ((Get-Service -Name $Name).Status -eq 'Running')
    } catch {
        Write-DTCLog ERROR "Start-Service $Name failed: $_"
        return $false
    }
}

function Invoke-RestartService {
    param([string]$Name)
    try {
        Restart-Service -Name $Name -Force -ErrorAction Stop
        Start-Sleep -Seconds 5
        return ((Get-Service -Name $Name).Status -eq 'Running')
    } catch {
        Write-DTCLog ERROR "Restart-Service $Name failed: $_"
        return $false
    }
}

function Repair-StoppingService {
    param([string]$Name)
    $svc = Get-ServiceState -Name $Name -Refresh
    if ($svc.State -notin @('Stop Pending','StopPending')) { return $true }
    Write-DTCLog WARN "REPAIR: $Name stuck in StopPending - force-killing PID $($svc.ProcessId)"
    if ($svc.ProcessId -gt 0) {
        try {
            Stop-Process -Id $svc.ProcessId -Force -ErrorAction Stop
            Start-Sleep -Seconds 3
            return $true
        } catch {
            Write-DTCLog ERROR "Force-kill PID $($svc.ProcessId) failed: $_"
            return $false
        }
    }
    return $false
}

function Repair-DnsCache {
    Write-DTCLog WARN "REPAIR: Flushing local DNS cache"
    try { Clear-DnsClientCache -ErrorAction SilentlyContinue; return $true }
    catch {
        Write-Verbose "Clear-DnsClientCache failed: $_"
        return $false
    }
}

function Repair-DnsService {
    Write-DTCLog WARN "REPAIR: Restarting Dnscache service (off-hours operation)"
    try {
        Restart-Service -Name 'Dnscache' -Force -ErrorAction Stop
        Start-Sleep -Seconds 3
        return $true
    } catch {
        Write-DTCLog ERROR "Dnscache restart failed: $_"
        return $false
    }
}

function Repair-ArpCache {
    Write-DTCLog WARN "REPAIR: Clearing ARP cache (off-hours operation)"
    try {
        & arp.exe -d * 2>$null | Out-Null
        return $true
    } catch {
        Write-Verbose "ARP clear failed: $_"
        return $false
    }
}

function Repair-TimeSync {
    Write-DTCLog WARN "REPAIR: w32tm resync"
    try {
        & w32tm /resync /force 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        return ($LASTEXITCODE -eq 0)
    } catch {
        Write-Verbose "w32tm resync failed: $_"
        return $false
    }
}

function Repair-DiskSpace {
    param([int]$MinAgeDays)
    Write-DTCLog WARN "REPAIR: Cleaning Windows\Temp files older than $MinAgeDays days"
    $cutoff = (Get-Date).AddDays(-$MinAgeDays)
    $freed = 0
    $path = "$env:WinDir\Temp"
    if (-not (Test-Path $path)) { return $true }
    try {
        Get-ChildItem -Path $path -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object {
                $sz = $_.Length
                try {
                    Remove-Item $_.FullName -Force -ErrorAction Stop
                    $freed += $sz
                } catch {
                    Write-Verbose "Could not delete $($_.FullName): $_"
                }
            }
    } catch {
        Write-Verbose "Disk cleanup enumeration failed: $_"
    }
    Write-DTCLog INFO "Disk cleanup freed: $([math]::Round($freed/1MB,1)) MB"
    return $true
}

function Reset-VssStack {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Script runs unattended via NinjaOne; ShouldProcess support is dead code in this runtime.')]
    [CmdletBinding()]
    param()
    Write-DTCLog WARN "REPAIR: VSS stack reset"
    try {
        Stop-Service -Name 'VSS'   -Force -ErrorAction SilentlyContinue
        Stop-Service -Name 'swprv' -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        Start-Service -Name 'swprv' -ErrorAction Stop
        Start-Service -Name 'VSS'   -ErrorAction Stop
        Start-Sleep -Seconds 5
        return $true
    } catch {
        Write-DTCLog ERROR "VSS reset failed: $_"
        return $false
    }
}

function Reset-VssDllRegistration {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Script runs unattended via NinjaOne; ShouldProcess support is dead code in this runtime.')]
    [CmdletBinding()]
    param()
    # BookStack page 2976. Off-hours escalation when VSS stack reset alone doesn't recover.
    Write-DTCLog WARN "REPAIR (ESCALATION): Re-registering VSS DLLs"
    try {
        Stop-Service -Name 'VSS'   -Force -ErrorAction SilentlyContinue
        Stop-Service -Name 'swprv' -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $sys32 = "$env:WinDir\System32"
        foreach ($d in @('ole32.dll','oleaut32.dll','vss_ps.dll')) {
            $p = Join-Path $sys32 $d
            if (Test-Path $p) { & regsvr32.exe /s $p 2>$null }
        }
        $swprvDll = Join-Path $sys32 'swprv.dll'
        if (Test-Path $swprvDll) { & regsvr32.exe /s /i $swprvDll 2>$null }
        $vssvc = Join-Path $sys32 'vssvc.exe'
        if (Test-Path $vssvc) { & $vssvc /Register 2>$null }
        Start-Sleep -Seconds 3
        Start-Service -Name 'swprv' -ErrorAction SilentlyContinue
        Start-Service -Name 'VSS'   -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        return $true
    } catch {
        Write-DTCLog ERROR "VSS DLL re-registration failed: $_"
        return $false
    }
}

function Restart-ParentAgent {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Script runs unattended via NinjaOne; ShouldProcess support is dead code in this runtime.')]
    [CmdletBinding()]
    param()
    Write-DTCLog WARN "REPAIR (ESCALATION): Restarting $script:ParentAgentName parent agent"
    try {
        Restart-Service -Name $script:ParentAgentName -Force -ErrorAction Stop
        Start-Sleep -Seconds 15
        return ((Get-Service -Name $script:ParentAgentName).Status -eq 'Running')
    } catch {
        Write-DTCLog ERROR "Parent agent restart failed: $_"
        return $false
    }
}

function Invoke-CollectLogsArchive {
    Write-DTCLog INFO "FORENSIC: Running ninjarmmagent /collectlogs"
    $parentSvc = Get-ServiceState -Name $script:ParentAgentName
    $agentExe = Get-ExePathFromService -SvcInfo $parentSvc
    if (-not $agentExe -or -not (Test-Path $agentExe)) {
        Write-DTCLog WARN "Cannot locate ninjarmmagent.exe for /collectlogs"
        return $null
    }
    try {
        & $agentExe /collectlogs 2>&1 | Out-Null
        Start-Sleep -Seconds 8
        $cabSrc = 'C:\Windows\Temp\ninjalogs.cab'
        if (-not (Test-Path $cabSrc)) {
            Write-DTCLog WARN "/collectlogs ran but ninjalogs.cab not produced"
            return $null
        }
        if (-not (Test-Path $script:ForensicsDir)) { New-Item -Path $script:ForensicsDir -ItemType Directory -Force | Out-Null }
        $destFile = Join-Path $script:ForensicsDir "lockhart_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd_HHmmss').cab"
        Copy-Item $cabSrc $destFile -Force
        Write-DTCLog INFO "Forensic cab archived: $destFile"
        return $destFile
    } catch {
        Write-DTCLog ERROR "/collectlogs forensic capture failed: $_"
        return $null
    }
}

function Get-FullDiagnosis {
    $lh = Get-ServiceState -Name $script:ServiceName -Refresh
    $pa = Get-ServiceState -Name $script:ParentAgentName -Refresh
    $d = [ordered]@{
        Lockhart        = $lh
        ParentAgent     = $pa
        VssSvc          = Get-ServiceState -Name 'VSS' -Refresh
        SwprvSvc        = Get-ServiceState -Name 'swprv' -Refresh
        FreeSpacePct    = Get-SystemDriveFreePct
        FailedDns       = @()
        FailedTcp       = @()
        TimeSyncAgeMin  = Get-TimeSyncAge
        AvEvents        = Get-AvQuarantineEventsForLockhart
        BinaryExists    = $false
        LockhartVersion = $null
        AgentVersion    = $null
        AgentYaml       = $null
    }
    if ($lh.Exists) {
        $lockhartExe = Get-ExePathFromService -SvcInfo $lh
        $d.BinaryExists = if ($lockhartExe) { Test-Path $lockhartExe } else { $false }
        $d.LockhartVersion = Get-BinaryVersion -Path $lockhartExe
        $d.AgentYaml = Test-AgentYaml -LockhartSvcInfo $lh
    }
    if ($pa.Exists) {
        $d.AgentVersion = Get-BinaryVersion -Path (Get-ExePathFromService -SvcInfo $pa)
    }
    foreach ($ep in $script:CloudEndpoints) {
        if (-not (Test-DnsResolutionWithTimeout -TargetHost $ep.Host -TimeoutMs $DnsTimeoutMs)) {
            $d.FailedDns += $ep.Host
        }
    }
    foreach ($ep in $script:CloudEndpoints) {
        if ($d.FailedDns -contains $ep.Host) { continue }
        if (-not (Test-TcpEndpoint -TargetHost $ep.Host -Port $ep.Port -TimeoutMs $NetTestTimeoutMs)) {
            $d.FailedTcp += "$($ep.Host):$($ep.Port)"
        }
    }
    return [PSCustomObject]$d
}

# =================== completion (terminal helper) ===================
function Complete-Remediation {
    param($State, [string]$Result, [int]$Code, [PSCustomObject]$Entry)
    $State.LastRun = (Get-Date).ToString('o')
    $State.LastResult = $Result
    if ($Entry) {
        $State.History = @(@($Entry) + @($State.History))
    }
    Set-State $State
    Write-DTCLog INFO "=== EXIT: $Result ==="
    return $Code
}

# =================== main flow (function-wrapped for Pester testability) ===================
function Invoke-LockhartRemediation {
    [CmdletBinding()]
    param()

    $runTs = Get-Date
    Write-DTCLog INFO "=== NinjaOne Backup - Lockhart Remediation / Repair v8 ==="
    Write-DTCLog INFO "Host: $env:COMPUTERNAME | PS: $($PSVersionTable.PSVersion) | PID: $PID"

    # Defense-in-depth: entry point already checks ^HV0 before transcript;
    # this guards direct function invocation in future refactors.
    if ($env:COMPUTERNAME -match '^HV0') {
        Write-DTCLog INFO "Hyper-V host detected ($env:COMPUTERNAME matches ^HV0). Backup remediation does not apply to hypervisors. Skipping."
        Write-DTCLog INFO "=== EXIT: HypervisorSkip ==="
        return 0
    }

    # ============================================================
    # PHASE 1: CHECK
    # ============================================================
    $inBusinessHours = Test-WithinBusinessHours -StartHour $BusinessHoursStartHour -EndHour $BusinessHoursEndHour
    $disruptiveAllowed = (-not $inBusinessHours) -or $script:ForceDisruptiveResolved
    Write-DTCLog INFO "Time: $((Get-Date).ToString('HH:mm')) | BusinessHours($BusinessHoursStartHour-$BusinessHoursEndHour): $inBusinessHours | DisruptiveAllowed: $disruptiveAllowed"

    $deviceClass = Get-DeviceClass
    Initialize-Path -DeviceClass $deviceClass
    Move-LegacyStateFile
    Write-DTCLog INFO "DeviceClass: $deviceClass | StateFile: $($script:StateFile)"

    # ClearStateAndExit short-circuit (env var via NinjaOne checkbox, or CLI switch)
    if ($script:ClearStateResolved) {
        Write-DTCLog INFO "ClearStateAndExit requested (param=$($ClearStateAndExit.IsPresent), env='$($env:ClearStateAndExit)')"
        if (Test-Path $script:StateFile) {
            try {
                Remove-Item $script:StateFile -Force -ErrorAction Stop
                Write-DTCLog INFO "State file removed: $($script:StateFile)"
            } catch {
                Write-DTCLog ERROR "Failed to remove state file: $_"
                return 1
            }
        } else {
            Write-DTCLog INFO "No state file to clear"
        }
        Write-DTCLog INFO "=== EXIT: StateCleared ==="
        return 0
    }

    # Lockhart service must exist
    $svc = Get-ServiceState -Name $script:ServiceName
    if (-not $svc.Exists) {
        Write-DTCLog INFO "Service '$script:ServiceName' not installed. NinjaOne Backup not enabled on this device. Skipping."
        Write-DTCLog INFO "=== EXIT: NotApplicable ==="
        return 0
    }

    # Device-offline short-circuits (sole reason, no counter increment)
    $uptimeMin = Get-SystemUptime
    $publicInternet = Test-PublicInternet
    Write-DTCLog INFO "UptimeMin: $uptimeMin | PublicInternet: $publicInternet"

    $state = Get-State

    if (-not $publicInternet) {
        Write-DTCLog WARN "Device cannot reach public internet (1.1.1.1). Sole reason for backup failure: device offline. No remediation attempted."
        $entry = [PSCustomObject]@{
            Time=$runTs.ToString('o'); DeviceClass=$deviceClass; InBusinessHours=$inBusinessHours
            Result='DeviceOffline_NoInternet'; Actions=''; Deferred=''; Failures=''
            Reason='Device cannot reach public internet'
            UptimeMin=$uptimeMin; PublicInternetReachable=$false
        }
        return Complete-Remediation -State $state -Result 'DeviceOffline_NoInternet' -Code 0 -Entry $entry
    }

    if ($null -ne $uptimeMin -and $uptimeMin -lt $MinUptimeMinutes) {
        Write-DTCLog WARN "Device uptime is $uptimeMin minutes (< $MinUptimeMinutes). Likely missed scheduled backup window due to recent reboot. Sole reason: device offline."
        $entry = [PSCustomObject]@{
            Time=$runTs.ToString('o'); DeviceClass=$deviceClass; InBusinessHours=$inBusinessHours
            Result='DeviceOffline_RecentReboot'; Actions=''; Deferred=''; Failures=''
            Reason="Device uptime $uptimeMin min (< $MinUptimeMinutes); likely missed backup window"
            UptimeMin=$uptimeMin; PublicInternetReachable=$true
        }
        return Complete-Remediation -State $state -Result 'DeviceOffline_RecentReboot' -Code 0 -Entry $entry
    }

    # Counter auto-reset
    if ($state.LastRun) {
        $hoursSince = ((Get-Date) - [datetime]$state.LastRun).TotalHours
        if ($hoursSince -gt $CounterResetHours) {
            Write-DTCLog INFO "Last run $([math]::Round($hoursSince,1))h ago (> $CounterResetHours h) - resetting counter"
            $state.ConsecutiveAttempts = 0
        }
    }
    Write-DTCLog INFO "State: Attempts=$($state.ConsecutiveAttempts) | LastResult=$($state.LastResult) | LastRun=$($state.LastRun)"

    # Guardrail - counter tracks interventions (successful or not) within the window
    if ([int]$state.ConsecutiveAttempts -ge $MaxConsecutiveAttempts) {
        $reason = "$($state.ConsecutiveAttempts) consecutive remediation interventions within the ${CounterResetHours}h window. Last result: $($state.LastResult). Repeated intervention - even when each one succeeds - indicates an underlying issue the script cannot fix. NOC must investigate manually."
        Write-DTCLog ERROR $reason
        return Complete-Remediation -State $state -Result 'MaxAttemptsReached' -Code 2 -Entry $null
    }

    # ============================================================
    # PHASE 2: DIAGNOSE
    # ============================================================
    Write-DTCLog INFO "--- Phase 2: DIAGNOSE ---"
    $diag = Get-FullDiagnosis
    Write-DTCLog INFO "Lockhart: $($diag.Lockhart.State) PID=$($diag.Lockhart.ProcessId) BinaryExists=$($diag.BinaryExists) Ver=$($diag.LockhartVersion)"
    Write-DTCLog INFO "$script:ParentAgentName: $($diag.ParentAgent.State) Ver=$($diag.AgentVersion) | VSS: $($diag.VssSvc.State) | swprv: $($diag.SwprvSvc.State)"
    Write-DTCLog INFO "Free disk: $($diag.FreeSpacePct)% | TimeSyncAge: $($diag.TimeSyncAgeMin) min | AvEvents: $($diag.AvEvents.Count)"
    if ($diag.AgentYaml) {
        Write-DTCLog INFO "agent.yaml: Exists=$($diag.AgentYaml.Exists) Readable=$($diag.AgentYaml.Readable) Valid=$($diag.AgentYaml.Valid)"
    }
    Write-DTCLog INFO "DNS failed: $($diag.FailedDns.Count) [$($diag.FailedDns -join ',')] | TCP failed: $($diag.FailedTcp.Count) [$($diag.FailedTcp -join ',')]"

    # Hard blockers (no remediation possible from script)
    $hardBlocker = $null
    $blockerResult = $null
    if (-not $diag.BinaryExists -and $diag.Lockhart.PathName) {
        $hardBlocker = "BinaryMissing: Lockhart service exists but binary not found at $($diag.Lockhart.PathName). Agent reinstall required."
        $blockerResult = 'RemediationBlocked_BinaryMissing'
    } elseif ($diag.AgentYaml -and $diag.AgentYaml.Exists -and -not $diag.AgentYaml.Valid) {
        $hardBlocker = "agent.yaml at $($diag.AgentYaml.Path) is missing required sections. Agent reinstall required."
        $blockerResult = 'RemediationBlocked_ConfigCorrupt'
    } elseif ($diag.AgentYaml -and -not $diag.AgentYaml.Exists -and $diag.AgentYaml.Path) {
        $hardBlocker = "agent.yaml not found at $($diag.AgentYaml.Path). Lockhart install incomplete - reinstall required."
        $blockerResult = 'RemediationBlocked_ConfigMissing'
    } elseif ($diag.AvEvents.Count -gt 0) {
        $hardBlocker = "AV quarantined Lockhart in last 24h. AV exclusion required at vendor console. Events: $($diag.AvEvents -join ' || ')"
        $blockerResult = 'RemediationBlocked_AvQuarantine'
    }
    if ($hardBlocker) {
        Write-DTCLog ERROR $hardBlocker
        $netForensics = Get-NetworkForensics
        $cabPath = Invoke-CollectLogsArchive
        $state.ConsecutiveAttempts = [int]$state.ConsecutiveAttempts + 1
        $entry = [PSCustomObject]@{
            Time=$runTs.ToString('o'); DeviceClass=$deviceClass; InBusinessHours=$inBusinessHours
            Result=$blockerResult; Actions=''; Deferred=''
            Failures=$blockerResult.Replace('RemediationBlocked_',''); Reason=$hardBlocker
            Forensics=$netForensics; ForensicCab=$cabPath
            LockhartVersion=$diag.LockhartVersion; AgentVersion=$diag.AgentVersion
            AvEvents = if ($diag.AvEvents.Count -gt 0) { $diag.AvEvents } else { $null }
        }
        return Complete-Remediation -State $state -Result $blockerResult -Code 1 -Entry $entry
    }

    # Live backup detection
    $liveBackup = $null
    if ($diag.Lockhart.State -eq 'Running' -and $diag.Lockhart.ProcessId -gt 0 -and (Get-Process -Id $diag.Lockhart.ProcessId -ErrorAction SilentlyContinue)) {
        Write-DTCLog INFO "Sampling PID=$($diag.Lockhart.ProcessId) for $SampleSeconds seconds"
        $liveBackup = Measure-ProcessActivity -TargetPid $diag.Lockhart.ProcessId -Seconds $SampleSeconds
        Write-DTCLog INFO "Sample: IO=$($liveBackup.DeltaMB) MB | CPU=$($liveBackup.CpuDeltaSec)s | Alive=$($liveBackup.ProcessAlive)"
        if ($liveBackup.ProcessAlive -and ($liveBackup.DeltaMB -ge $ActiveIoThresholdMB -or $liveBackup.CpuDeltaSec -ge $ActiveCpuThresholdSec)) {
            Write-DTCLog INFO "LIVE BACKUP DETECTED - exiting without remediation"
            $entry = [PSCustomObject]@{
                Time=$runTs.ToString('o'); DeviceClass=$deviceClass; InBusinessHours=$inBusinessHours
                Result='LiveJobSkipped'; Actions=''; Deferred=''; Failures=''
                Reason='Live backup in progress'
            }
            return Complete-Remediation -State $state -Result 'LiveJobSkipped' -Code 0 -Entry $entry
        }
    }

    # ============================================================
    # PHASE 3: REPAIR
    # ============================================================
    Write-DTCLog INFO "--- Phase 3: REPAIR (DisruptiveAllowed=$disruptiveAllowed) ---"
    $repairActions = @()
    $deferredRepairs = @()

    # Anytime: DNS cache flush
    if ($diag.FailedDns.Count -gt 0 -or $diag.FailedTcp.Count -gt 0) {
        if (Repair-DnsCache) { $repairActions += 'DnsCacheFlushed' }
    }

    # Anytime: time resync
    if ($null -ne $diag.TimeSyncAgeMin -and $diag.TimeSyncAgeMin -gt $TimeSkewToleranceMinutes) {
        if (Repair-TimeSync) { $repairActions += 'TimeResynced' } else { $repairActions += 'Failed_TimeResync' }
    }

    # Anytime: disk cleanup
    if ($null -ne $diag.FreeSpacePct -and $diag.FreeSpacePct -lt $MinFreeSpacePercent) {
        if (Repair-DiskSpace -MinAgeDays $TempCleanupMinAgeDays) { $repairActions += 'DiskSpaceCleaned' }
    }

    # Gated: Dnscache restart
    if ($diag.FailedDns.Count -gt 0) {
        if ($disruptiveAllowed) {
            if (Repair-DnsService) { $repairActions += 'DnsServiceRestarted' } else { $repairActions += 'Failed_DnsServiceRestart' }
        } else {
            Write-DTCLog INFO "DEFER: Dnscache restart (business hours)"
            $deferredRepairs += 'DnsServiceRestart'
        }
    }

    # Gated: ARP clear
    if ($diag.FailedTcp.Count -gt 0) {
        if ($disruptiveAllowed) {
            if (Repair-ArpCache) { $repairActions += 'ArpCacheCleared' }
        } else {
            Write-DTCLog INFO "DEFER: ARP clear (business hours)"
            $deferredRepairs += 'ArpCacheClear'
        }
    }

    # Anytime: parent agent start (Lockhart depends on it)
    if ($diag.ParentAgent.Exists -and $diag.ParentAgent.State -ne 'Running') {
        Write-DTCLog WARN "REPAIR: Starting $script:ParentAgentName"
        if (Invoke-StartService -Name $script:ParentAgentName) { $repairActions += "Started_$script:ParentAgentName" }
        else { $repairActions += "Failed_Start_$script:ParentAgentName" }
        Start-Sleep -Seconds 3
    }

    # Anytime: VSS stack reset (if either service is non-normal)
    $vssOk   = $diag.VssSvc.State -in @('Running','Stopped')
    $swprvOk = $diag.SwprvSvc.State -in @('Running','Stopped')
    $vssWasBad = -not ($vssOk -and $swprvOk)
    if ($vssWasBad) {
        if (Reset-VssStack) { $repairActions += 'VssStackReset' } else { $repairActions += 'Failed_VssReset' }
    }

    # Anytime: Lockhart action based on observed state
    $currentSvc = Get-ServiceState -Name $script:ServiceName -Refresh
    if ($currentSvc.State -in @('Stop Pending','StopPending','StartPending','Start Pending')) {
        Write-DTCLog WARN "Lockhart wedged in $($currentSvc.State) - force-killing"
        if (Repair-StoppingService -Name $script:ServiceName) { $repairActions += 'LockhartForceKilled' }
        $currentSvc = Get-ServiceState -Name $script:ServiceName -Refresh
    }
    switch ($currentSvc.State) {
        'Stopped' {
            if (Invoke-StartService -Name $script:ServiceName) { $repairActions += 'LockhartStarted' }
            else { $repairActions += 'Failed_LockhartStart' }
        }
        'Paused' {
            if (Invoke-RestartService -Name $script:ServiceName) { $repairActions += 'LockhartRestarted' }
            else { $repairActions += 'Failed_LockhartRestart' }
        }
        'Running' {
            # Single restart for every Running sub-state that reaches this point:
            #  - zombie PID / process missing
            #  - process died during the sample window
            #  - process alive but idle below both thresholds with backups failing 25h+
            # A genuinely active backup already exited earlier via LiveJobSkipped.
            # Known accepted edge: a long-running backup sampled entirely within a
            # quiet phase (dedupe/catalog/network stall) gets restarted; NinjaOne
            # Backup resumes block-level on the next run (vendor-documented), so
            # the cost is bounded and preferable to leaving stuck processes
            # unremediated - the exact case the pilot validated.
            if (Invoke-RestartService -Name $script:ServiceName) { $repairActions += 'LockhartRestarted' }
            else { $repairActions += 'Failed_LockhartRestart' }
        }
        default {
            if (Invoke-RestartService -Name $script:ServiceName) { $repairActions += 'LockhartRestarted' }
            else { $repairActions += 'Failed_LockhartRestart' }
        }
    }

    # ============================================================
    # MID-CONFIRM (decide if escalation needed)
    # ============================================================
    Start-Sleep -Seconds 3
    $mid = Get-FullDiagnosis
    $vssStillBad      = -not (($mid.VssSvc.State -in @('Running','Stopped')) -and ($mid.SwprvSvc.State -in @('Running','Stopped')))
    $lockhartStillBad = $mid.Lockhart.State -ne 'Running'

    # ============================================================
    # ESCALATION REPAIRS (off-hours only)
    # ============================================================
    if ($vssWasBad -and $vssStillBad) {
        if ($disruptiveAllowed) {
            Write-DTCLog WARN "VSS still bad after stack reset - escalating to DLL re-registration"
            if (Reset-VssDllRegistration) { $repairActions += 'VssDllReRegistered' }
            else { $repairActions += 'Failed_VssDllReReg' }
        } else {
            Write-DTCLog INFO "DEFER: VSS DLL re-registration (escalation, business hours)"
            $deferredRepairs += 'VssDllReRegistration'
        }
    }
    if ($lockhartStillBad) {
        if ($disruptiveAllowed) {
            Write-DTCLog WARN "Lockhart still not Running after restart - escalating to parent agent restart"
            if (Restart-ParentAgent) {
                $repairActions += 'ParentAgentRestarted'
                Start-Sleep -Seconds 10
                $finalSvc = Get-ServiceState -Name $script:ServiceName -Refresh
                if ($finalSvc.State -ne 'Running') {
                    if (Invoke-StartService -Name $script:ServiceName) { $repairActions += 'LockhartStarted_PostAgentRestart' }
                }
            } else { $repairActions += 'Failed_ParentAgentRestart' }
        } else {
            Write-DTCLog INFO "DEFER: NinjaRMMAgent restart (escalation, business hours)"
            $deferredRepairs += 'ParentAgentRestart'
        }
    }

    # ============================================================
    # PHASE 4: FINAL CONFIRM
    # ============================================================
    Write-DTCLog INFO "--- Phase 4: CONFIRM ---"
    Start-Sleep -Seconds 3
    $post = Get-FullDiagnosis
    $confirmFailures = @()
    if ($post.Lockhart.State -ne 'Running') { $confirmFailures += "Lockhart_Not_Running($($post.Lockhart.State))" }
    if ($post.ParentAgent.Exists -and $post.ParentAgent.State -ne 'Running') { $confirmFailures += "ParentAgent_Not_Running($($post.ParentAgent.State))" }
    if ($post.FailedDns.Count -gt 0) { $confirmFailures += "DNS_Still_Failing($($post.FailedDns -join ','))" }
    if ($post.FailedTcp.Count -gt 0) { $confirmFailures += "Cloud_Still_Unreachable($($post.FailedTcp -join ','))" }
    if ($null -ne $post.FreeSpacePct -and $post.FreeSpacePct -lt $MinFreeSpacePercent) {
        $confirmFailures += "DiskSpace_Still_Low($($post.FreeSpacePct)%)"
    }
    Write-DTCLog INFO "Post-repair: Lockhart=$($post.Lockhart.State) | DNS-fail=$($post.FailedDns.Count) | TCP-fail=$($post.FailedTcp.Count) | Disk=$($post.FreeSpacePct)%"

    $forensics = $null
    $cabPath = $null
    if ($confirmFailures.Count -gt 0) {
        $forensics = Get-NetworkForensics
        Write-DTCLog INFO "Forensics: Gateway=$($forensics.DefaultGateway) reach=$($forensics.GatewayReachable) | DNS=$($forensics.DnsServers) reach=$($forensics.DnsServerReachable) | Proxy=$($forensics.WinHttpProxy) | Internet=$($forensics.PublicInternetReachable)"
    }

    # ============================================================
    # PHASE 5: STATE (record outcome)
    # ============================================================
    $deferredCouldFix = ($deferredRepairs.Count -gt 0) -and ($confirmFailures.Count -gt 0)
    $result = $null

    if ($confirmFailures.Count -eq 0) {
        if ($repairActions.Count -eq 0) {
            $result = 'AlreadyHealthy_CounterCleared'
            $state.ConsecutiveAttempts = 0
            Write-DTCLog INFO "Lockhart fully healthy, no repairs needed. Counter cleared."
        } else {
            # Intentional: successful interventions still count toward the
            # guardrail. Needing to repair Lockhart every cycle is a recurring
            # problem worth NOC eyes even when each individual repair works.
            # AlreadyHealthy_CounterCleared (above) is the recovery path once
            # the device holds healthy between runs.
            $result = 'RemediationSucceeded'
            $state.ConsecutiveAttempts = [int]$state.ConsecutiveAttempts + 1
            Write-DTCLog INFO "Repairs confirmed healthy. Actions: $($repairActions -join ', ')"
        }
    } elseif ($deferredCouldFix) {
        $result = 'RemediationDeferred'
        Write-DTCLog WARN "Confirm failed but disruptive repairs deferred. Counter NOT incremented. Deferred: $($deferredRepairs -join ', ') | Unresolved: $($confirmFailures -join ' | ')"
    } else {
        $result = 'RemediationFailed'
        $state.ConsecutiveAttempts = [int]$state.ConsecutiveAttempts + 1
        Write-DTCLog ERROR "Repair did not fully confirm. Unresolved: $($confirmFailures -join ' | ')"
        $cabPath = Invoke-CollectLogsArchive
    }

    $entry = [PSCustomObject]@{
        Time            = $runTs.ToString('o')
        DeviceClass     = $deviceClass
        InBusinessHours = $inBusinessHours
        Result          = $result
        Actions         = ($repairActions -join ',')
        Deferred        = ($deferredRepairs -join ',')
        Failures        = ($confirmFailures -join ',')
        Reason          = if ($confirmFailures.Count -gt 0) { $confirmFailures -join ' | ' } else { 'OK' }
        Forensics       = $forensics
        ForensicCab     = $cabPath
        LockhartVersion = $diag.LockhartVersion
        AgentVersion    = $diag.AgentVersion
    }

    Write-DTCLog INFO "Final: ConsecutiveAttempts=$($state.ConsecutiveAttempts) | Result=$result"

    $exitCode = switch ($result) {
        'AlreadyHealthy_CounterCleared' { 0 }
        'RemediationSucceeded'          { 0 }
        'RemediationDeferred'           { 0 }
        'RemediationFailed'             { 1 }
        default                         { 1 }
    }
    return Complete-Remediation -State $state -Result $result -Code $exitCode -Entry $entry
}

# ================================================================
# ENTRY POINT (SCRIPT LOGIC SECTION)
# ================================================================
# HV0 exclusion FIRST - before transcript, mutex, or any file writes.
# Hypervisors take zero side effects from this script.
if ($env:COMPUTERNAME -match '^HV0') {
    Write-DTCLog INFO "Hyper-V host detected ($env:COMPUTERNAME matches ^HV0). Backup remediation does not apply to hypervisors. Skipping."
    Write-DTCLog INFO "=== EXIT: HypervisorSkip ==="
    exit 0
}

$script:TranscriptActive = Start-RemediationTranscript
Write-DTCLog INFO "Description: $($script:Description) | RMM mode: $($script:IsRmmMode) | LogPath: $($script:LogPath)"
Write-DTCLog INFO "Flags: ForceDisruptiveRepairs param=$($ForceDisruptiveRepairs.IsPresent) env='$($env:ForceDisruptiveRepairs)' resolved=$($script:ForceDisruptiveResolved) | ClearStateAndExit param=$($ClearStateAndExit.IsPresent) env='$($env:ClearStateAndExit)' resolved=$($script:ClearStateResolved)"

$scriptPid = $PID
$scriptTimeout = $MaxRuntimeSeconds
$runtimeKiller = Start-Job -ScriptBlock {
    Start-Sleep -Seconds $using:scriptTimeout
    try { Stop-Process -Id $using:scriptPid -Force -ErrorAction SilentlyContinue } catch { Write-Verbose "Runtime killer Stop-Process failed: $_" }
}

$script:mutex = $null
$exitCode = 1
try {
    $script:mutex = New-Object System.Threading.Mutex($false, $script:MutexName)
    if (-not $script:mutex.WaitOne(0)) {
        Write-DTCLog WARN "Another instance already running. Exiting."
        $exitCode = 0
    } else {
        $exitCode = Invoke-LockhartRemediation
    }
} catch {
    Write-DTCLog ERROR "Unhandled exception: $_"
    Write-DTCLog ERROR $_.ScriptStackTrace
    $exitCode = 1
} finally {
    if ($script:mutex) {
        try { $script:mutex.ReleaseMutex() } catch { Write-Verbose "Mutex release failed: $_" }
        try { $script:mutex.Dispose() } catch { Write-Verbose "Mutex dispose failed: $_" }
    }
    Stop-Job $runtimeKiller -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $runtimeKiller -Force -ErrorAction SilentlyContinue | Out-Null
    if ($script:TranscriptActive) {
        try { Stop-Transcript | Out-Null } catch { Write-Verbose "Stop-Transcript failed: $_" }
    }
}

exit $exitCode