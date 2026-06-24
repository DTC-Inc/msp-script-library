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
## Purpose: Reclaim disk consumed by runaway NinjaRMM custom-script output transcripts
##          under the agent scripting directory. Kills the writing process (if any) then
##          hard-deletes the oversized "*-output.txt" file. Self-protecting: never matches,
##          kills, or deletes the process or files belonging to THIS cleanup run.
##          Runs silently with no required input in either mode.
##
## Exit codes: 0 = completed (zero or more files cleaned, no failures)
##             1 = completed with one or more deletion failures (see transcript)
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

function Invoke-RunawayLogPurge {
    param([int64]$ThresholdBytes)

    $scriptingDir = "C:\ProgramData\NinjaRMMAgent\scripting"
    $myPid = $PID

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
        $genId = ($f.Name -split '\.ps1')[0]
        Write-Host "[3/4] Processing $($f.Name) (gen id: $genId)"

        # Kill the writing process if one is still spinning. Anchor on the scripting
        # path AND the gen id, and NEVER match our own PID.
        $writers = Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='cmd.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessId -ne $myPid -and
                $_.CommandLine -like "*$scriptingDir*" -and
                $_.CommandLine -like "*$genId*"
            }
        foreach ($w in $writers) {
            Write-Host "      Killing writer PID $($w.ProcessId)"
            try { Stop-Process -Id $w.ProcessId -Force -ErrorAction Stop }
            catch { Write-Host "      WARN: could not kill PID $($w.ProcessId): $($_.Exception.Message)" }
        }

        Write-Host "[4/4] Deleting $($f.FullName) [$([math]::Round($f.Length/1GB,2)) GB]"
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            Write-Host "      Deleted."
        } catch {
            Write-Host "      ERROR: could not delete (file locked or in use by this run): $($_.Exception.Message)"
            $failures++
        }
    }

    if ($failures -gt 0) {
        Write-Host "RESULT: completed with $failures deletion failure(s) -> EXIT 1"
        return 1
    }
    Write-Host "RESULT: all candidates cleaned -> EXIT 0"
    return 0
}

$exitCode = Invoke-RunawayLogPurge -ThresholdBytes $thresholdBytes

Write-Host "Final exit code: $exitCode"
Stop-Transcript
exit $exitCode