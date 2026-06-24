# --- Ensure 64-bit: NinjaRMM launches 32-bit PowerShell by default. Relaunch under
#     native sysnative host so behavior is identical interactive vs RMM. ---
if ($env:PROCESSOR_ARCHITEW6432 -eq "AMD64" -and -not [Environment]::Is64BitProcess) {
    $sysnative = "$env:WINDIR\sysnative\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path -LiteralPath $sysnative) {
        & $sysnative -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
        exit $LASTEXITCODE
    }
}

## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $env:RMM             - "1" when executed from the RMM (string). Anything else = interactive.
## $env:Description     - optional audit label for the transcript (default set below).
## $env:ThresholdMB     - size floor in MB for an output file to be a runaway (optional, default 500)
## $env:RuntimeCeilingMin - backstop: kill any NinjaRMM customscript process older than this many
##                          minutes regardless of file size (optional, default 30)
##
## Purpose: Reclaim disk consumed by runaway NinjaRMM custom-script output transcripts under the
##          agent scripting directory, and stop the processes producing them. A file is a runaway if
##          it is over ThresholdMB, OR actively growing while a NinjaRMM customscript process holds
##          it open, OR the holding process has run longer than RuntimeCeilingMin (backstop).
##          Excludes this run's own output file so the tool never false-flags what it is writing.
##          Uses the Windows Restart Manager to find the exact PIDs holding each file, terminates
##          them (never the NinjaRMM agent, never this run), then deletes the file.
##
## Exit codes: 0 = completed (zero or more cleaned, no failures)
##             1 = completed with one or more files that could not be freed/deleted
##             2 = scripting directory not found / nothing to scan

$ScriptLogName = "ninjarmm-purge-runaway-logs.log"

$ThresholdMB = 500
$parsedMB = 0
if ($env:ThresholdMB -and [int]::TryParse($env:ThresholdMB, [ref]$parsedMB) -and $parsedMB -ge 1) {
    $ThresholdMB = $parsedMB
}
$thresholdBytes = [int64]$ThresholdMB * 1MB

$RuntimeCeilingMin = 30
$parsedMin = 0
if ($env:RuntimeCeilingMin -and [int]::TryParse($env:RuntimeCeilingMin, [ref]$parsedMin) -and $parsedMin -ge 1) {
    $RuntimeCeilingMin = $parsedMin
}

if ([string]::IsNullOrEmpty($env:Description)) {
    $env:Description = "Automated runaway-log purge"
}

if ($env:RMM -eq "1") {
    if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
        $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$env:WINDIR\logs\$ScriptLogName"
    }
} else {
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"
}

Start-Transcript -Path $LogPath

Write-Host "============ Purge Runaway NinjaRMM Script Logs ============"
Write-Host "Description      : $env:Description"
Write-Host "Log path         : $LogPath"
Write-Host "RMM mode         : $env:RMM"
Write-Host "Threshold        : $ThresholdMB MB ($thresholdBytes bytes)"
Write-Host "Runtime ceiling  : $RuntimeCeilingMin min (backstop)"
Write-Host "==========================================================="

if (-not ([System.Management.Automation.PSTypeName]'DtcFileLock').Type) {
    Add-Type -ErrorAction Stop -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class DtcFileLock {
    [StructLayout(LayoutKind.Sequential)]
    struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }
    const int CCH_RM_MAX_APP_NAME = 255;
    const int CCH_RM_MAX_SVC_NAME = 63;
    enum RM_APP_TYPE { RmUnknownApp=0, RmMainWindow=1, RmOtherWindow=2, RmService=3, RmExplorer=4, RmConsole=5, RmCritical=1000 }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=CCH_RM_MAX_APP_NAME+1)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=CCH_RM_MAX_SVC_NAME+1)] public string strServiceShortName;
        public RM_APP_TYPE ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }
    [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);
    [DllImport("rstrtmgr.dll", CharSet=CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames, uint nApplications, [In] RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebReasons);
    public static List<int> WhoHas(string path) {
        var pids = new List<int>();
        uint session; string key = Guid.NewGuid().ToString();
        if (RmStartSession(out session, 0, key) != 0) return pids;
        try {
            string[] resources = { path };
            if (RmRegisterResources(session, 1, resources, 0, null, 0, null) != 0) return pids;
            uint needed = 0, count = 0, reason = 0;
            int r = RmGetList(session, out needed, ref count, null, ref reason);
            if (r == 234 && needed > 0) {
                var info = new RM_PROCESS_INFO[needed];
                count = needed;
                if (RmGetList(session, out needed, ref count, info, ref reason) == 0) {
                    for (int i = 0; i < count; i++) pids.Add(info[i].Process.dwProcessId);
                }
            }
        } finally { RmEndSession(session); }
        return pids;
    }
}
"@
}

function Get-ScriptHolder {
    param([string]$Path, [string]$ScriptingDir)
    $result = @()
    try {
        $holders = [DtcFileLock]::WhoHas($Path)
        foreach ($hpid in $holders) {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$hpid" -ErrorAction SilentlyContinue
            if ($p -and $p.CommandLine -like "*$ScriptingDir*") {
                $result += $p
            }
        }
    } catch {
        Write-Host "      WARN: RM query failed during detection: $($_.Exception.Message)"
    }
    return $result
}

function Invoke-RunawayLogPurge {
    param([int64]$ThresholdBytes, [int]$RuntimeCeilingMin)

    $scriptingDir = "C:\ProgramData\NinjaRMMAgent\scripting"
    $myPid = $PID
    $protectedNames = @('NinjaRMMAgent', 'ninjarmm-agent', 'ninjarmm-cli')
    $growthSampleSec = 3

    Write-Host "[1/5] Validating scripting directory: $scriptingDir"
    if (-not (Test-Path -LiteralPath $scriptingDir)) {
        Write-Host "RESULT: scripting directory not found -> nothing to do -> EXIT 2"
        return 2
    }

    $ownPids = @($myPid)
    try {
        $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$myPid" -ErrorAction SilentlyContinue).ParentProcessId
        if ($parent) { $ownPids += [int]$parent }
    } catch {
        Write-Host "      WARN: could not resolve parent PID: $($_.Exception.Message)"
    }

    $selfFiles = @()
    Get-ChildItem -LiteralPath $scriptingDir -Filter *output.txt -File -ErrorAction SilentlyContinue | ForEach-Object {
        $fp = $_.FullName
        try {
            $h = [DtcFileLock]::WhoHas($fp)
            if ($h | Where-Object { $ownPids -contains $_ }) { $selfFiles += $fp }
        } catch {
            Write-Host "      WARN: self-file check failed on $fp : $($_.Exception.Message)"
        }
    }
    if ($selfFiles.Count -gt 0) {
        Write-Host "      Excluding this run's own output file(s): $($selfFiles -join ', ')"
    }

    Write-Host "[2/5] First pass: snapshot all *output.txt sizes ..."
    $first = @{}
    Get-ChildItem -LiteralPath $scriptingDir -Filter *output.txt -File -ErrorAction SilentlyContinue |
        Where-Object { $selfFiles -notcontains $_.FullName } |
        ForEach-Object { $first[$_.FullName] = $_.Length }

    if ($first.Count -eq 0) {
        Write-Host "RESULT: no eligible output files present -> nothing to clean -> EXIT 0"
        return 0
    }

    Write-Host "[3/5] Sampling growth over $growthSampleSec sec ..."
    Start-Sleep -Seconds $growthSampleSec
    $now = Get-Date

    $targets = @()
    foreach ($path in $first.Keys) {
        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        $sizeNow = $item.Length
        $sizeWas = $first[$path]
        $reason  = $null

        if ($sizeNow -gt $ThresholdBytes) {
            $reason = "over threshold ($([math]::Round($sizeNow/1GB,2)) GB)"
        }
        elseif ($sizeNow -gt $sizeWas) {
            $scriptHolders = Get-ScriptHolder -Path $path -ScriptingDir $scriptingDir
            if ($scriptHolders.Count -gt 0) {
                $reason = "actively growing (+$([math]::Round(($sizeNow-$sizeWas)/1KB,1)) KB in ${growthSampleSec}s) and held by a script process"
            }
        }

        if (-not $reason) {
            $scriptHolders = Get-ScriptHolder -Path $path -ScriptingDir $scriptingDir
            foreach ($p in $scriptHolders) {
                $started = $null
                if ($p.CreationDate) {
                    try { $started = [Management.ManagementDateTimeConverter]::ToDateTime($p.CreationDate) } catch { $started = $null }
                }
                if ($started -and ($now - $started).TotalMinutes -gt $RuntimeCeilingMin) {
                    $reason = "backstop: holder PID $($p.ProcessId) running $([math]::Round(($now-$started).TotalMinutes)) min (> $RuntimeCeilingMin)"
                    break
                }
            }
        }

        if ($reason) {
            $targets += [pscustomobject]@{ Path = $path; Reason = $reason }
        }
    }

    if ($targets.Count -eq 0) {
        Write-Host "RESULT: no runaways (none over threshold, growing, or past runtime ceiling) -> EXIT 0"
        return 0
    }

    Write-Host "[4/5] Identified $($targets.Count) runaway file(s):"
    $targets | ForEach-Object { Write-Host "        $([System.IO.Path]::GetFileName($_.Path)) -- $($_.Reason)" }

    $failures = 0
    foreach ($t in $targets) {
        $path = $t.Path
        Write-Host "[5/5] Processing $([System.IO.Path]::GetFileName($path)) -- $($t.Reason)"

        $holders = @()
        try { $holders = [DtcFileLock]::WhoHas($path) }
        catch { Write-Host "      WARN: Restart Manager query failed: $($_.Exception.Message)" }

        if ($holders.Count -gt 0) {
            Write-Host "      Lock holders (PIDs): $($holders -join ', ')"
            foreach ($hpid in $holders) {
                if ($ownPids -contains $hpid -or $hpid -le 4) {
                    Write-Host "      Skipping PID $hpid (self/parent or system)"
                    continue
                }
                $proc = Get-Process -Id $hpid -ErrorAction SilentlyContinue
                if (-not $proc) { continue }
                if ($protectedNames -contains $proc.Name) {
                    Write-Host "      PROTECTED: PID $hpid is '$($proc.Name)' (NinjaRMM agent) - will NOT kill."
                    continue
                }
                Write-Host "      Killing PID $hpid ($($proc.Name))"
                try { Stop-Process -Id $hpid -Force -ErrorAction Stop }
                catch { Write-Host "      WARN: could not kill PID ${hpid}: $($_.Exception.Message)" }
            }
        } else {
            Write-Host "      No lock holders reported."
        }

        $deleted = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                $deleted = $true
                Write-Host "      Deleted on attempt $attempt."
                break
            } catch {
                Write-Host "      Attempt $attempt failed: $($_.Exception.Message)"
                Start-Sleep -Seconds 2
            }
        }
        if (-not $deleted) {
            Write-Host "      ERROR: could not delete after 3 attempts (still locked). Counted as failure."
            $failures++
        }
    }

    if ($failures -gt 0) {
        Write-Host "RESULT: completed with $failures file(s) not freed -> EXIT 1"
        return 1
    }
    Write-Host "RESULT: all runaways cleaned -> EXIT 0"
    return 0
}

$exitCode = Invoke-RunawayLogPurge -ThresholdBytes $thresholdBytes -RuntimeCeilingMin $RuntimeCeilingMin

Write-Host "Final exit code: $exitCode"
Stop-Transcript
exit $exitCode
