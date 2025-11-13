# One-paste remover for GoTo Resolve Unattended (no helper functions)
# Run as Administrator. Designed for RMM/Ninja script runner.
# Silently uninstalls if present, kills processes, disables related services, removes folders & tasks.

$ErrorActionPreference = 'SilentlyContinue'
$hadError = $false

Write-Output "[INFO] Starting GoTo Resolve Unattended cleanup"

# --- Indicators ---
$procNames = @('GoToResolveTerminal','GoTo.Resolve.Antivirus.App','GoTo.Resolve.PatchManagement.Client')
$rootFolders = @(
    Join-Path $env:ProgramFiles 'GoTo Resolve Unattended',
    Join-Path ${env:ProgramFiles(x86)} 'GoTo Resolve Unattended'
) | Where-Object { $_ -and (Test-Path (Split-Path $_ -Parent)) }

# --- 1) Kill known processes ---
foreach ($n in $procNames) {
  Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Output "[INFO] Stopping process $($_.ProcessName) (PID $($_.Id))"
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
  }
}

# --- 2) Disable services whose ImagePath points into known folders ---
try {
  $svcs = Get-CimInstance Win32_Service | Where-Object {
    $pn = [string]$_.PathName
    $pn -and ($rootFolders | Where-Object { $pn -like ("*" + $_ + "*") }).Count -gt 0
  }
  foreach ($s in $svcs) {
    Write-Output "[INFO] Disabling service $($s.Name) ($($s.DisplayName))"
    if ($s.State -eq 'Running') { Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue }
    Set-Service -Name $s.Name -StartupType Disabled -ErrorAction SilentlyContinue
  }
} catch { $hadError = $true; Write-Output "[WARN] Service enumeration error: $($_.Exception.Message)" }

# --- 3) Uninstall via registry uninstall keys (DisplayName like 'GoTo Resolve') ---
$uninstallRoots = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
$targets = @()
foreach ($r in $uninstallRoots) {
  if (Test-Path $r) {
    Get-ChildItem $r | ForEach-Object {
      $p = Get-ItemProperty -Path $_.PsPath -ErrorAction SilentlyContinue
      if ($p) {
        $name = [string]$p.DisplayName
        $loc  = [string]$p.InstallLocation
        $uni  = [string]$p.UninstallString
        if ($name -match '(?i)GoTo\s*Resolve') { $targets += [PSCustomObject]@{DisplayName=$name; InstallLocation=$loc; UninstallString=$uni} }
      }
    }
  }
}

foreach ($t in $targets) {
  if (-not $t.UninstallString) { continue }
  $cmd = $t.UninstallString.Trim()
  Write-Output "[INFO] Attempting uninstall: $($t.DisplayName)"

  # Normalize into exe + args
  $exe=''; $args=''
  if ($cmd.StartsWith('"')) { $exe = $cmd -replace '^"([^"]+)".*$','$1'; $args = $cmd.Substring($exe.Length + 2).Trim() }
  else { $parts = $cmd.Split(' ',2); $exe = $parts[0]; if ($parts.Count -gt 1) { $args = $parts[1] } }

  if ($exe -match '(?i)msiexec\.exe') {
    if ($args -match '(?i)\{[0-9A-F-]{36}\}') { $product = $Matches[0]; $final = "/x $product /qn /norestart" }
    else { $final = ($args -replace '(?i)\s?/i\b',' /x') + ' /qn /norestart' }
    Write-Output "[INFO] msiexec.exe $final"
    try { $p = Start-Process msiexec.exe -ArgumentList $final -PassThru -Wait -WindowStyle Hidden; if ($p.ExitCode -ne 0){$hadError=$true;Write-Output "[WARN] MSI uninstall exit code $($p.ExitCode)"} } catch { $hadError=$true; Write-Output "[WARN] MSI uninstall failed: $($_.Exception.Message)" }
  } else {
    $silentFlags = @('/S','/quiet','/qn','/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
    if (-not ($silentFlags | ForEach-Object { if ($args -match [regex]::Escape($_)) { $true } })) { $args = ($args + ' /S /VERYSILENT /SUPPRESSMSGBOXES /NORESTART').Trim() }
    Write-Output "[INFO] $exe $args"
    try { $p = Start-Process -FilePath $exe -ArgumentList $args -PassThru -Wait -WindowStyle Hidden; if ($p.ExitCode -ne 0){$hadError=$true;Write-Output "[WARN] EXE uninstall exit code $($p.ExitCode)"} } catch { $hadError=$true; Write-Output "[WARN] EXE uninstall failed: $($_.Exception.Message)" }
  }
}

# --- 4) Remove scheduled tasks that point to our folders ---
try {
  $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue
  foreach ($t in $tasks) {
    $hit = $false
    foreach ($a in $t.Actions) { if ($a.Execute -and ($rootFolders | Where-Object { ($a.Execute + ' ' + $a.Arguments) -like ("*" + $_ + "*") }).Count -gt 0) { $hit = $true; break } }
    if ($hit) { Write-Output "[INFO] Deleting scheduled task: $($t.TaskName)"; Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction SilentlyContinue }
  }
} catch { $hadError = $true; Write-Output "[WARN] Scheduled task cleanup error: $($_.Exception.Message)" }

# --- 5) Delete known install folders ---
foreach ($f in $rootFolders) {
  if (Test-Path $f) {
    Write-Output "[INFO] Removing folder $f"
    for ($i=0; $i -lt 3; $i++) { try { Remove-Item -LiteralPath $f -Recurse -Force -ErrorAction Stop; break } catch { Start-Sleep -Seconds (2+$i) } }
  }
}

Write-Output "[INFO] GoTo Resolve Unattended cleanup complete"
if ($hadError) { exit 1 } else { exit 0 }
