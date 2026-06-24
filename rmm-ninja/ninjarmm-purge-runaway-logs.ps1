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
## $env:RMM            - "1" when executed from the RMM (string). Anything else = interactive.
## $env:Description    - optional audit label for the transcript (default set below). Ninja
##                       already captures operator/ticket at the platform level, so no prompt.
## $env:ThresholdMB    - size floor in MB for a file to be considered runaway (optional, default 500)
##
## Purpose: Reclaim disk consumed by runaway NinjaRMM custom-script output transcripts under
##          the agent scripting directory. Uses the Windows Restart Manager to identify the
##          exact process(es) holding each oversized "*-output.txt" file open, terminates them
##          (never the NinjaRMM agent, never this run), then deletes the file.
##          Runs silently with no required input in either mode. Fleet-safe across workstations
##          and servers: fixed agent path, OS-level lock detection, no filename-pattern assumptions.
##
## Exit codes: 0 = completed (zero or more files cleaned, no failures)
##             1 = completed with one or more files that could not be freed/deleted
##             2 = scripting directory not found / nothing to scan

$ScriptLogName = "ninjarmm-purge-runaway-logs.log"

# --- Resolve ThresholdMB from RMM env var; default 500, floor of 1 ---
$ThresholdMB = 500
$parsedMB = 0
if ($env:ThresholdMB -and [int]::TryParse($env:ThresholdMB, [ref]$parsedMB) -and $parsedMB -ge 1) {
    $ThresholdMB = $parsedMB
}
$thresholdBytes = [int64]$ThresholdMB * 1MB

# --- Input handling: no required user input. Default Description, set log path by context. ---
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
Write-Host "Description : $env:Description"
Write-Host "Log path    : $LogPath"
Write-Host "RMM mode    : $env:RMM"
Write-Host "Threshold   : $ThresholdMB MB ($thresholdBytes bytes)"
Write-Host "==========================================================="

# --- Restart Manager interop: ask Windows which PIDs hold a file open. Dependency-free,
#     works on every Windows version (rstrtmgr.dll, XP+). Added once per session. ---
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

function Invoke-RunawayLogPurge {
    param([int64]$ThresholdBytes)

    $scriptingDir = "C:\ProgramData\NinjaRMMAgent\scripting"
    $myPid = $PID
    $protectedNames = @('NinjaRMMAgent', 'ninjarmm-agent', 'ninjarmm-cli')

    Write-Host "[1/4] Validating scripting directory: $scriptingDir"
    if (-not (Test-Path -LiteralPath $scriptingDir)) {
        Write-Host "RESULT: scripting directory not found -> nothing to do -> EXIT 2"
        return 2
    }

    Write-Host "[2/4] Scanning for *-output.txt over threshold ..."
    $candidates = Get-ChildItem -LiteralPath $scriptingDir -Filter *output.txt -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt $ThresholdBytes }

    if (-not $candidates) {
        Write-Host "RESULT: no files over $([math]::Round($ThresholdBytes/1MB)) MB -> nothing to clean -> EXIT 0"
        return 0
    }

    Write-Host "      Found $($candidates.Count) candidate file(s):"
    $candidates | ForEach-Object { Write-Host "        $($_.Name)  [$([math]::Round($_.Length/1GB,2)) GB]" }

    $failures = 0
    foreach ($f in $candidates) {
        Write-Host "[3/4] Processing $($f.Name) [$([math]::Round($f.Length/1GB,2)) GB]"

        # Ask Windows directly which PIDs hold this file open.
        $holders = @()
        try { $holders = [DtcFileLock]::WhoHas($f.FullName) } catch {
            Write-Host "      WARN: Restart Manager query failed: $($_.Exception.Message)"
        }

        if ($holders.Count -gt 0) {
            Write-Host "      Lock holders (PIDs): $($holders -join ', ')"
            foreach ($hpid in $holders) {
                if ($hpid -eq $myPid -or $hpid -le 4) {
                    Write-Host "      Skipping PID $hpid (self or system)"
                    continue
                }
                $proc = Get-Process -Id $hpid -ErrorAction SilentlyContinue
                if (-not $proc) { continue }
                if ($protectedNames -contains $proc.Name) {
                    Write-Host "      PROTECTED: PID $hpid is '$($proc.Name)' (NinjaRMM agent) - will NOT kill. File held by agent; stop the source automation in NinjaOne, then re-run."
                    continue
                }
                Write-Host "      Killing PID $hpid ($($proc.Name))"
                try { Stop-Process -Id $hpid -Force -ErrorAction Stop }
                catch { Write-Host "      WARN: could not kill PID ${hpid}: $($_.Exception.Message)" }
            }
        } else {
            Write-Host "      No lock holders reported (file may be unlocked, or held by a protected/system handle)."
        }

        # Delete with brief retry: handle release after a kill is not always instantaneous.
        Write-Host "[4/4] Deleting $($f.FullName)"
        $deleted = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
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
    Write-Host "RESULT: all candidates cleaned -> EXIT 0"
    return 0
}

$exitCode = Invoke-RunawayLogPurge -ThresholdBytes $thresholdBytes

Write-Host "Final exit code: $exitCode"
Stop-Transcript
exit $exitCode