# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType] 'Tls12'

<#
.SYNOPSIS
    Enforces DTC's Veeam scheduling policy on a BDR so local backups cannot
    hold a restore-point lock while the S3 copy is reading it.

      SERVER / IMAGE JOBS (periodic)  : window 06:00-20:59, Mon-Fri.
                                        Sat + Sun DENIED (cloud only).
      WORKSTATION JOBS (daily)        : start 21:00, Mon-Fri.
      S3 / CLOUD COPY JOBS            : window 22:00-04:59 Mon-Sat,
                                        plus ALL DAY Sunday from 00:00.

    Saturday 21:00 -> Monday 06:00 is 33 hours with no local job running,
    which is what lets a large VM's offsite copy catch up.

.DESCRIPTION
    THE FORMAT, proven by probe on DTCBSURE-GODWIN (VBR 12.3.1.1139):

      A PERIODIC job's permitted-hours window lives in
      OptionsPeriodically.Schedule as an XML string:
        <scheduler><Sunday>0,0,...</Sunday><Monday>...</Monday>...</scheduler>
      Seven day elements, 24 comma-separated values, hour 0-23.
      POLARITY IS INVERTED: 0 = PERMITTED, 1 = DENIED. Proven against live
      session data - hyper-v02 carried 1 at hours 0-4 and 20-23 and its
      actual start hours were 5 through 21; its Sunday row is all 1s and it
      has never run a Sunday.

      OptionsBackupWindow is NOT the control on this build (IsEnabled False,
      BackupWindow a zero-length string on every job). Do not use it.

      FullPeriod is SECONDS even though Kind reads "Hours" - hyper-v01 shows
      FullPeriod 3600 / Kind Hours / HourlyOffset 15 and runs at :15 hourly.

    COPY-JOB CONVERSION (new in v2.1):
      A Daily schedule has ONE start time, so it cannot express "22:00 Mon-Sat
      but 00:00 Sunday". Copy jobs are therefore converted from Daily to
      Periodic with a window. CONFIRMED ACCEPTED on a live
      SimpleBackupCopyPolicy (DTCBSURE-GODWIN, tested and reverted
      2026-08-12): Daily=False / Periodic=True/Hours/3600 was written and
      read back successfully.

      BEHAVIOURAL CHANGE: periodic means the copy is eligible to fire every
      copyIntervalSeconds within the window - up to 7 times Mon-Sat and 24 on
      Sunday - rather than once nightly at 22:00. Veeam will not start a
      second session while one is running. Raise copyIntervalSeconds if a
      less frequent cadence is wanted.

    WHAT THIS DOES NOT FIX:
      DTCBSURE-GODWIN / ORTHO1 (683 GB) failed its offsite copy eleven
      consecutive nights with "Source restore point is locked by another
      job". The 2026-08-11 session ran 22:00:18 -> 08:22:59 next morning -
      over ten hours - and was still working when the 08:15 backup took the
      lock. Every attempt logged Primary bottleneck: Target at 98-99%: the
      B2 upload is saturated. The weekend window gives that VM 33 hours to
      catch up, after which nightly increments should fit. If it still does
      not complete, the remaining levers are the "Network traffic throttling
      is enabled" setting in that session log, more upstream, or seeding -
      bandwidth decisions, not scheduling ones. A still-failing ORTHO1 after
      this is not this script failing.

    MODES (RMM variable "mode"):
      report    DEFAULT. Read-only. Every job, current schedule, what would
                change. Safe fleet-wide.
      apply     Writes. Also requires applyChanges=1. Captures full original
                state for rollback, skips running jobs, and reads every
                schedule back to confirm it persisted.
      rollback  Restores from a saved schedule-original_*.json.

.NOTES
    Author  : Z. Boogher
    Ticket  : HALO 1146283 (schedule-collision workstream)
    Version : 2.1
              - copy jobs converted Daily -> Periodic with a window
                (22:00-04:59 Mon-Sat, all day Sunday)
              - workstation daily jobs moved to 21:00, Mon-Fri
              - rollback now captures Daily AND Periodic state
              - (2.0) real <scheduler> XML format, inverted polarity,
                Sat+Sun off for local backups
    Exit    : 0 = clean   2 = changes pending / skipped / partial   1 = failure

    NinjaOne renders exit 2 as FAILURE. A report run on a device that needs
    changes shows red - expected. Read the log, not the badge.

    DEPLOYMENT: Run As = SYSTEM. VBR 12.x and 13.x - the Veeam PowerShell
    runtime is chosen per call from the installed build, because v13 needs
    PowerShell 7 and the v12 module throws
    "The type initializer for 'Veeam.Backup.Common.SSslOptions'" under it.

    DO NOT run this concurrently with the v13 upgrade script (203). Different
    mutex, so both can fire on one box; changing job schedules while services
    are stopping mid-install is avoidable risk. Sequence them.

    RMM variables (all String, all optional, defaults shown):
      mode                  report | apply | rollback   (default report)
      applyChanges          0/1 second gate on apply    (default 0)
      serverWindowStart     6     first permitted hour, periodic backups
      serverWindowEnd       21    first DENIED hour (6-21 = 06:00-20:59)
      serverDays            Mon,Tue,Wed,Thu,Fri
      workstationHour       21    daily backup start hour
      workstationDays       Mon,Tue,Wed,Thu,Fri
      copyWindowStart       22    copy window opens, Mon-Sat
      copyWindowEnd         5     copy window closes (wraps midnight)
      copySundayAllDay      1     Sunday fully open from 00:00
      copyIntervalSeconds   3600  how often the copy may fire in-window
      convertCopyToPeriodic 1     0 = leave copy jobs alone entirely
      rollbackFile          path to a saved schedule-original_*.json
#>

#Requires -Version 5.1

# --- 64-bit relaunch: NinjaOne runs 32-bit; HKLM\SOFTWARE\Veeam is hidden
# --- under WOW64 redirection.
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
$Ps7RequiredBuild = [version]'13.0.0.0'
$LogFolder        = 'C:\ProgramData\DTC\Logs\VeeamSchedule'
$LogRetention     = 10
$MutexName        = 'Global\DTC-VeeamSchedule'
$DayNames         = @('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')

# --- RMM inputs ---------------------------------------------------------------
function Get-IntVar { param([string]$Name, [int]$Default)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($v -and [int]::TryParse($v, [ref]$null)) { return [int]$v }
    return $Default
}
function Get-DayIdx { param([string]$Raw, [int[]]$Default)
    $idx = @()
    foreach ($d in ($Raw -split ',')) {
        $t = $d.Trim(); if (-not $t) { continue }
        for ($i = 0; $i -lt 7; $i++) { if ($DayNames[$i] -like "$t*") { $idx += $i; break } }
    }
    $idx = @($idx | Sort-Object -Unique)
    if ($idx.Count -eq 0) { return $Default }
    return $idx
}

$Mode = if ($env:mode) { ([string]$env:mode).Trim().ToLower() } else { 'report' }
if ($Mode -notin @('report','apply','rollback')) { $Mode = 'report' }
$ApplyConfirmed = ($env:applyChanges -eq '1')

$ServerStart     = Get-IntVar 'serverWindowStart' 6
$ServerEnd       = Get-IntVar 'serverWindowEnd'   21
$WorkstationHour = Get-IntVar 'workstationHour'   21
$CopyStart       = Get-IntVar 'copyWindowStart'   22
$CopyEnd         = Get-IntVar 'copyWindowEnd'     5
$CopyInterval    = Get-IntVar 'copyIntervalSeconds' 3600
$CopySundayAll   = -not ($env:copySundayAllDay -eq '0')
$ConvertCopy     = -not ($env:convertCopyToPeriodic -eq '0')
$ServerDaysRaw      = if ($env:serverDays)      { [string]$env:serverDays }      else { 'Mon,Tue,Wed,Thu,Fri' }
$WorkstationDaysRaw = if ($env:workstationDays) { [string]$env:workstationDays } else { 'Mon,Tue,Wed,Thu,Fri' }
$ServerDays      = Get-DayIdx -Raw $ServerDaysRaw      -Default @(1,2,3,4,5)
$WorkstationDays = Get-DayIdx -Raw $WorkstationDaysRaw -Default @(1,2,3,4,5)
$RollbackFile    = $env:rollbackFile

# --- State --------------------------------------------------------------------
$exitCode  = 0
$mutex     = $null
$haveMutex = $false
$script:PwshPath = $null

function Write-Log {
    # MUST be Write-Host - Write-Output would put log text on the pipeline and
    # corrupt any function whose return value is assigned.
    param([string]$Message, [string]$Level = 'INFO')
    Write-Host ("[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
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

function Get-InstalledVbrBuild {
    $keyPath = 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication'
    if (-not (Test-Path -LiteralPath $keyPath)) { throw 'Veeam Backup & Replication is not installed (no registry key).' }
    $k = Get-ItemProperty -LiteralPath $keyPath
    if ($k.PSObject.Properties.Name -notcontains 'CorePath') { throw 'Veeam registry key has no CorePath.' }
    $exe = Join-Path ([string]$k.CorePath) 'Veeam.Backup.Service.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw 'Veeam.Backup.Service.exe not found.' }
    $raw = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion.Trim()
    $v = $null
    if (-not [version]::TryParse(($raw -split '\s')[0], [ref]$v)) { throw "Could not parse build string '$raw'." }
    return $v
}

function Get-PermittedHourSet {
    param([int]$Start, [int]$End)
    $h = @()
    if ($Start -le $End) { for ($i = $Start; $i -lt $End; $i++) { $h += $i } }
    else { for ($i = $Start; $i -lt 24; $i++) { $h += $i }; for ($i = 0; $i -lt $End; $i++) { $h += $i } }
    return ,$h
}

function New-SchedulerXml {
    # 0 = PERMITTED, 1 = DENIED. Inverted - confirmed against hyper-v02's live
    # run hours on DTCBSURE-GODWIN.
    # $FullDays are days permitted for all 24 hours regardless of $PermittedHours
    # (used for the copy job's Sunday).
    param([int[]]$PermittedHours, [int[]]$PermittedDays, [int[]]$FullDays = @())
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<scheduler>')
    for ($d = 0; $d -lt 7; $d++) {
        $vals = @()
        for ($h = 0; $h -lt 24; $h++) {
            $allowed = $false
            if ($FullDays -contains $d) { $allowed = $true }
            elseif (($PermittedDays -contains $d) -and ($PermittedHours -contains $h)) { $allowed = $true }
            $vals += $(if ($allowed) { '0' } else { '1' })
        }
        [void]$sb.Append("<$($DayNames[$d])>")
        [void]$sb.Append(($vals -join ','))
        [void]$sb.Append("</$($DayNames[$d])>")
    }
    [void]$sb.Append('</scheduler>')
    return $sb.ToString()
}

function Invoke-VeeamQuery {
    param([Parameter(Mandatory)][string]$Script, [string]$Prefix = '')
    $build = $null
    try { $build = Get-InstalledVbrBuild } catch { }
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
        if (-not $pw) { throw "PowerShell 7 not found; VBR $build requires it for the Veeam module." }
        $tmp = Join-Path $LogFolder ("vsched_{0}.ps1" -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $tmp -Value $body -Encoding UTF8 -Force
        try {
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $raw = & $pw -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $tmp 2>&1
            $rc  = $LASTEXITCODE
            $ErrorActionPreference = $prevEap
            $good = @($raw) | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }
            $bad  = @($raw) | Where-Object { $_ -is  [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }
            $txt = ($good -join "`n")
            if ([string]::IsNullOrWhiteSpace($txt)) { throw "pwsh Veeam query returned no output (exit $rc). $($bad -join '; ')" }
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
    $i = $txt.IndexOfAny([char[]]@('{', '['))
    if ($i -lt 0) { throw "Veeam query returned no JSON. Output: $txt" }
    return ($txt.Substring($i) | ConvertFrom-Json)
}

function Invoke-ScheduleWork {
    param([bool]$Apply, [string]$ServerXml, [string]$CopyXml, [string]$RestoreJson)

    $wsDayNames = (@($WorkstationDays | ForEach-Object { $DayNames[$_] }) -join ',')

    $prefix = @"
`$ServerXml   = '$($ServerXml -replace "'","''")'
`$CopyXml     = '$($CopyXml   -replace "'","''")'
`$DoApply     = `$$($Apply.ToString().ToLower())
`$WsHour      = $WorkstationHour
`$WsDays      = '$wsDayNames'
`$CopyInterval = $CopyInterval
`$ConvertCopy = `$$($ConvertCopy.ToString().ToLower())
`$RestoreJson = '$(($RestoreJson -replace "'","''"))'
"@

    $code = @'
$log = New-Object System.Collections.Generic.List[string]
$rows = @(); $changed = @(); $skipped = @(); $failed = @(); $originals = @()

function Test-IsCopyJob { param($Job) return ([string]$Job.JobType -match 'Copy|Sync') }

function Get-StateSnapshot {
  param($So)
  return [ordered]@{
    dailyEnabled  = $(try { [bool]$So.OptionsDaily.Enabled } catch { $null })
    dailyKind     = $(try { [string]$So.OptionsDaily.Kind } catch { $null })
    dailyTime     = $(try { ([datetime]$So.OptionsDaily.TimeLocal).ToString('o') } catch { $null })
    perEnabled    = $(try { [bool]$So.OptionsPeriodically.Enabled } catch { $null })
    perKind       = $(try { [string]$So.OptionsPeriodically.Kind } catch { $null })
    perFullPeriod = $(try { [string]$So.OptionsPeriodically.FullPeriod } catch { $null })
    perOffset     = $(try { [string]$So.OptionsPeriodically.HourlyOffset } catch { $null })
    perSchedule   = $(try { [string]$So.OptionsPeriodically.Schedule } catch { $null })
  }
}

try {
  if (Get-Command Connect-VBRServer -ErrorAction SilentlyContinue) {
    try { Connect-VBRServer -Server localhost -ErrorAction Stop } catch { }
  }

  $restoreMap = @{}
  if ($RestoreJson) {
    try { foreach ($e in (ConvertFrom-Json $RestoreJson)) { $restoreMap[[string]$e.name] = $e } } catch { }
  }

  $running = @()
  try {
    $running = @(Get-VBRBackupSession -ErrorAction SilentlyContinue |
                 Where-Object { $_.State -eq 'Working' } | ForEach-Object { [string]$_.JobName })
  } catch { }
  if ($running.Count -gt 0) { $log.Add("Running now, will be skipped: $($running -join ', ')") }

  foreach ($j in @(Get-VBRJob -ErrorAction Stop -WarningAction SilentlyContinue)) {
    $name = [string]$j.Name
    $isCopy = Test-IsCopyJob -Job $j
    $row = [ordered]@{ name = $name; jobType = [string]$j.JobType; isCopy = $isCopy }

    try { $so = Get-VBRJobScheduleOptions -Job $j -ErrorAction Stop }
    catch { $row.error = "schedule read failed: $($_.Exception.Message)"; $rows += $row; continue }

    $snap = Get-StateSnapshot -So $so
    $row.scheduleKind = $(if ($snap.perEnabled) { 'Periodic' } elseif ($snap.dailyEnabled) { 'Daily' } else { 'Other' })
    if ($snap.perEnabled) {
      $row.intervalEvery = $snap.perFullPeriod; $row.intervalUnit = $snap.perKind; $row.hourlyOffset = $snap.perOffset
    }
    if ($snap.dailyEnabled) {
      $row.dailyKind = $snap.dailyKind
      $row.dailyTime = $(try { ([datetime]$snap.dailyTime).ToString('HH:mm') } catch { $snap.dailyTime })
      $row.dailyDays = $(try { ($so.OptionsDaily.GetDays()) -join ',' } catch { '' })
    }

    # ----------------------------------------------------- decide the target
    $action = 'none'; $note = ''
    $rb = $restoreMap[$name]

    if ($rb) { $action = 'restore' }
    elseif ($isCopy) {
      if (-not $ConvertCopy) { $note = 'copy job - convertCopyToPeriodic=0, left alone'; $action = 'none' }
      elseif ($snap.perEnabled -and [string]$snap.perSchedule -eq $CopyXml) { $note = 'copy window already correct'; $action = 'none' }
      else { $action = 'copy-window'; $note = 'WOULD convert to periodic + set copy window' }
    }
    elseif ($snap.perEnabled) {
      if ([string]$snap.perSchedule -eq $ServerXml) { $note = 'server window already correct'; $action = 'none' }
      else { $action = 'server-window'; $note = 'WOULD SET server window' }
    }
    elseif ($snap.dailyEnabled) {
      $curHour = -1
      try { $curHour = ([datetime]$snap.dailyTime).Hour } catch { }
      $curDays = $(try { ($so.OptionsDaily.GetDays()) -join ',' } catch { '' })
      if ($curHour -eq $WsHour -and $curDays -eq $WsDays) { $note = "workstation daily already $($WsHour):00 on $WsDays"; $action = 'none' }
      else { $action = 'workstation-daily'; $note = "WOULD SET daily start to $($WsHour):00 on $WsDays (now $($curHour):00 on $curDays)" }
    }
    else { $note = "schedule kind '$($row.scheduleKind)' - nothing to set" }

    $row.note = $note
    if ($action -eq 'none' -or -not $DoApply) { $rows += $row; continue }

    if ($running -contains $name) {
      $log.Add("  SKIP '$name' - running right now.")
      $skipped += $name; $row.result = 'skipped-running'; $rows += $row; continue
    }

    $snap.name = $name
    $snap.capturedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $originals += $snap

    # ------------------------------------------------------------- apply
    try {
      switch ($action) {
        'server-window' {
          $so.OptionsPeriodically.Schedule = $ServerXml
          Set-VBRJobScheduleOptions -Job $j -Options $so -ErrorAction Stop | Out-Null
          $a = Get-VBRJobScheduleOptions -Job $j -ErrorAction Stop
          if ([string]$a.OptionsPeriodically.Schedule -ne $ServerXml) { throw 'server window did not persist' }
          if ([string]$a.OptionsPeriodically.FullPeriod -ne $snap.perFullPeriod -or
              [string]$a.OptionsPeriodically.HourlyOffset -ne $snap.perOffset) {
            throw "INTERVAL CHANGED: was $($snap.perFullPeriod)/offset $($snap.perOffset), now $([string]$a.OptionsPeriodically.FullPeriod)/offset $([string]$a.OptionsPeriodically.HourlyOffset)"
          }
          $row.result = 'applied'
          $row.verify = "interval $([string]$a.OptionsPeriodically.Kind)/$([string]$a.OptionsPeriodically.FullPeriod) offset $([string]$a.OptionsPeriodically.HourlyOffset) (unchanged)"
        }
        'copy-window' {
          # Daily -> Periodic. Confirmed accepted on SimpleBackupCopyPolicy.
          $so.OptionsDaily.Enabled = $false
          $so.OptionsPeriodically.Enabled = $true
          $so.OptionsPeriodically.Kind = 'Hours'
          $so.OptionsPeriodically.FullPeriod = $CopyInterval
          $so.OptionsPeriodically.Schedule = $CopyXml
          Set-VBRJobScheduleOptions -Job $j -Options $so -ErrorAction Stop | Out-Null
          $a = Get-VBRJobScheduleOptions -Job $j -ErrorAction Stop
          if (-not [bool]$a.OptionsPeriodically.Enabled) { throw 'periodic did not enable on the copy job' }
          if ([string]$a.OptionsPeriodically.Schedule -ne $CopyXml) { throw 'copy window did not persist' }
          $row.result = 'applied'
          $row.verify = "periodic every $([string]$a.OptionsPeriodically.FullPeriod)s, daily disabled"
        }
        'workstation-daily' {
          $t = (Get-Date -Hour $WsHour -Minute 0 -Second 0)
          $so.OptionsDaily.Enabled = $true
          $so.OptionsDaily.TimeLocal = $t
          $dayWarn = ''
          try {
            $so.OptionsDaily.Kind = 'SelectedDays'
            $so.OptionsDaily.DaysSrv = [System.DayOfWeek[]]@($WsDays -split ',' | ForEach-Object { [System.DayOfWeek]$_ })
          } catch { $dayWarn = "day-set not applied ($($_.Exception.Message))" }
          Set-VBRJobScheduleOptions -Job $j -Options $so -ErrorAction Stop | Out-Null
          $a = Get-VBRJobScheduleOptions -Job $j -ErrorAction Stop
          $newHour = $(try { ([datetime]$a.OptionsDaily.TimeLocal).Hour } catch { -1 })
          if ($newHour -ne $WsHour) { throw "daily start did not persist (now $($newHour):00)" }
          $newDays = $(try { ($a.OptionsDaily.GetDays()) -join ',' } catch { '' })
          $row.result = 'applied'
          $row.verify = "daily $($newHour):00 on $newDays$(if ($dayWarn) { " - $dayWarn" })"
          if ($dayWarn) { $log.Add("  '$name': $dayWarn - the START TIME was set, the DAY SET was not.") }
        }
        'restore' {
          if ($null -ne $rb.perEnabled)  { $so.OptionsPeriodically.Enabled = [bool]$rb.perEnabled }
          if ($rb.perKind)               { $so.OptionsPeriodically.Kind = $rb.perKind }
          if ($rb.perFullPeriod)         { $so.OptionsPeriodically.FullPeriod = $rb.perFullPeriod }
          if ($rb.perOffset)             { $so.OptionsPeriodically.HourlyOffset = $rb.perOffset }
          if ($rb.perSchedule)           { $so.OptionsPeriodically.Schedule = [string]$rb.perSchedule }
          if ($null -ne $rb.dailyEnabled){ $so.OptionsDaily.Enabled = [bool]$rb.dailyEnabled }
          if ($rb.dailyKind)             { try { $so.OptionsDaily.Kind = $rb.dailyKind } catch { } }
          if ($rb.dailyTime)             { try { $so.OptionsDaily.TimeLocal = [datetime]$rb.dailyTime } catch { } }
          Set-VBRJobScheduleOptions -Job $j -Options $so -ErrorAction Stop | Out-Null
          $row.result = 'restored'
          $row.verify = 'original schedule written back'
        }
      }
      $changed += $name
      $log.Add("  APPLIED '$name' [$action] - $($row.verify)")
    } catch {
      $row.result = "failed: $($_.Exception.Message)"
      $failed += "$name ($($_.Exception.Message))"
      $log.Add("  FAILED '$name' [$action]: $($_.Exception.Message)")
    }
    $rows += $row
  }

  @{ ok=$true; log=@($log); rows=@($rows); changed=@($changed); skipped=@($skipped);
     failed=@($failed); originals=@($originals) } | ConvertTo-Json -Depth 6 -Compress
}
catch {
  @{ ok=$false; error=[string]$_.Exception.Message; log=@($log) } | ConvertTo-Json -Depth 6 -Compress
}
'@
    return Invoke-VeeamQuery -Script $code -Prefix $prefix
}

# --- Single instance ----------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, $MutexName)
try   { $haveMutex = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $haveMutex = $true }
if (-not $haveMutex) { Write-Host 'HALTED: another instance is already running.'; exit 2 }

if (-not (Test-Path -LiteralPath $LogFolder)) { New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null }
Get-ChildItem -LiteralPath $LogFolder -Filter 'veeam-schedule_*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip $LogRetention |
    Remove-Item -Force -ErrorAction SilentlyContinue
$transcript = Join-Path $LogFolder ("veeam-schedule_{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $transcript -Force | Out-Null

try {
    Write-Log "=== DTC Veeam Schedule Windows v2.1 - $env:COMPUTERNAME - mode=$Mode ==="
    Write-Log "Installed build: $(Get-InstalledVbrBuild)"

    $serverHours = Get-PermittedHourSet -Start $ServerStart -End $ServerEnd
    $copyHours   = Get-PermittedHourSet -Start $CopyStart   -End $CopyEnd
    $serverDayNames = (@($ServerDays | ForEach-Object { $DayNames[$_] }) -join ',')
    $wsDayNames     = (@($WorkstationDays | ForEach-Object { $DayNames[$_] }) -join ',')

    # copy: window Mon-Sat, Sunday fully open
    $copyDays = @(1,2,3,4,5,6)
    $copyFull = if ($CopySundayAll) { @(0) } else { @() }

    $serverXml = New-SchedulerXml -PermittedHours $serverHours -PermittedDays $ServerDays
    $copyXml   = New-SchedulerXml -PermittedHours $copyHours   -PermittedDays $copyDays -FullDays $copyFull

    Write-Log ("POLICY servers (periodic) : {0:00}:00-{1:00}:59 on {2}. All other hours/days denied." -f $ServerStart, ($ServerEnd - 1), $serverDayNames)
    Write-Log ("POLICY workstations (daily): start {0:00}:00 on {1}." -f $WorkstationHour, $wsDayNames)
    Write-Log ("POLICY cloud copy          : {0:00}:00-{1:00}:59 Mon-Sat{2}; periodic every {3}s in-window." -f $CopyStart, ($CopyEnd - 1), $(if ($CopySundayAll) { ', ALL DAY Sunday' }), $CopyInterval)
    Write-Log 'Scheduler XML polarity: 0 = permitted, 1 = denied.'

    $restoreJson = ''
    if ($Mode -eq 'rollback') {
        if (-not $RollbackFile) { throw 'mode=rollback requires rollbackFile.' }
        if (-not (Test-Path -LiteralPath $RollbackFile)) { throw "Rollback file not found: $RollbackFile" }
        $restoreJson = (Get-Content -LiteralPath $RollbackFile -Raw)
        Write-Log "ROLLBACK from $RollbackFile" 'WARN'
        if (-not $ApplyConfirmed) { Write-Log 'Rollback also requires applyChanges=1. Nothing changed.' 'WARN'; exit 2 }
    }

    $doApply = ($Mode -eq 'apply' -or $Mode -eq 'rollback')
    if ($doApply -and -not $ApplyConfirmed) {
        Write-Log 'mode=apply requires applyChanges=1 as a second confirmation. Running as REPORT - nothing changed.' 'WARN'
        $doApply = $false
    }

    $r = Invoke-ScheduleWork -Apply $doApply -ServerXml $serverXml -CopyXml $copyXml -RestoreJson $restoreJson
    if ($null -eq $r -or -not $r.ok) { throw "Schedule query failed: $(if($r){$r.error}else{'no output'})" }
    foreach ($l in @($r.log)) { if ($l) { Write-Log $l } }

    Write-Log '--- Jobs ---'
    foreach ($row in @($r.rows)) {
        $kind = if ($row.isCopy) { 'COPY  ' } else { 'BACKUP' }
        $line = "{0} {1,-34} {2}" -f $kind, $row.name, $row.scheduleKind
        if ($row.intervalEvery) { $line += " every $($row.intervalEvery)s offset $($row.hourlyOffset)" }
        if ($row.dailyTime)     { $line += " at $($row.dailyTime) [$($row.dailyDays)]" }
        if ($row.result)        { $line += "  RESULT: $($row.result)" }
        if ($row.verify)        { $line += "  -> $($row.verify)" }
        if ($row.note)          { $line += "  [$($row.note)]" }
        if ($row.error)         { $line += "  ERROR: $($row.error)" }
        Write-Log $line
    }

    if ($doApply) {
        if (@($r.originals).Count -gt 0 -and $Mode -ne 'rollback') {
            $bak = Join-Path $LogFolder ("schedule-original_{0:yyyyMMdd-HHmmss}.json" -f (Get-Date))
            $r.originals | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $bak -Encoding UTF8 -Force
            Write-Log "Original schedules saved -> $bak" 'WARN'
            Write-Log "To undo: mode=rollback, applyChanges=1, rollbackFile=$bak" 'WARN'
        }
        Write-Log ("APPLIED to {0} job(s); {1} skipped (running); {2} failed." -f @($r.changed).Count, @($r.skipped).Count, @($r.failed).Count)
        foreach ($f in @($r.failed)) { Write-Log "  FAILED: $f" 'ERROR' }
        if (@($r.failed).Count -gt 0 -or @($r.skipped).Count -gt 0) { $exitCode = 2 }
    } else {
        $needing = @($r.rows | Where-Object { $_.note -match '^WOULD' }).Count
        Write-Log "REPORT ONLY - $needing job(s) would change. Nothing was written."
        Write-Log 'To apply: mode=apply AND applyChanges=1.'
        if ($needing -gt 0) { $exitCode = 2 }
    }
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    $exitCode = 1
}
finally {
    Get-ChildItem -LiteralPath $LogFolder -Filter 'vsched_*.ps1' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    try { Stop-Transcript | Out-Null } catch { }
    if ($haveMutex) { try { $mutex.ReleaseMutex() } catch { } }
}

exit $exitCode