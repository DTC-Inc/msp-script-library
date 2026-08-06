## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Every input can be supplied EITHER as a -Parameter on the command line OR as an
## environment variable of the same name. NinjaRMM passes script preset variables as
## environment variables, so each parameter below defaults to its matching $env: value.
## $Description                       / $env:Description                       - Ticket # or initials for audit trail
## $RMMScriptPath                     / $env:RMMScriptPath                     - Optional log directory base provided by the RMM
## $CustomFieldIntelRaidUnhealthy     / $env:CustomFieldIntelRaidUnhealthy     - Checkbox field name (default: "intelRaidUnhealthy")
## $CustomFieldIntelRaidStatus        / $env:CustomFieldIntelRaidStatus        - Text field name (default: "intelRaidStatus"), 200 char cap
## $CustomFieldIntelRaidHealthDetails / $env:CustomFieldIntelRaidHealthDetails - WYSIWYG field name (default: "intelRaidHealthDetails")
## $IntelRaidToolPath                 / $env:IntelRaidToolPath                 - Optional explicit path to rstcli64.exe / IntelVROCCli.exe / storcli64.exe
## $CliTimeoutSeconds                 / $env:CliTimeoutSeconds                 - Per-CLI-invocation hard kill (default: 120)
## $MaxRuntimeSeconds                 / $env:MaxRuntimeSeconds                 - Overall script deadline (default: 300)
## $env:WriteCustomFields             - Set to "1" to write results to Ninja custom fields. Omit for report-only.
##
## NON-INTERACTIVE BY DESIGN. There is no Read-Host and no $env:RMM flag; the script can
## never block on input or spin on an unsatisfiable input-validation loop.
## Minimum PowerShell: 5.1. Exit codes: 0 = healthy / out of scope / no Intel RAID | 2 = WARNING | 1 = CRITICAL
##
## MUST RUN AS SYSTEM. Ninja-Property-Set shells out to ninjarmm-cli.exe in a SYSTEM-only path,
## and the DriverStore sweep plus WMI adapter queries require admin.
##
## SCOPE GATE: physical hardware only. Virtual guests exit 0 and write NOTHING. There is NO OS-type
## gate - workstation-SKU devices are evaluated normally. Deployment scope is the policy's job.
## HypervisorPresent is deliberately not used as a discriminator - it is $true on a Hyper-V host too.
##
## FAMILIES: Intel RAID only.
##   Family A - chipset/CPU RAID (RST / RSTe / VROC). CLI: rstcli64.exe or IntelVROCCli.exe. Text output.
##   Family B - Intel RS3-series add-in cards (LSI silicon, Intel PCI subsystem ID). CLI: storcli64.exe. JSON.
## Dell PERC is deliberately excluded (PCI SUBSYS vendor 1028) - covered by iDRAC, see KB 3019.
## PERC is Dell-rebranded LSI/Broadcom MegaRAID, NOT Intel: observed H730P = VEN_1000 DEV_005D
## (LSI SAS3108). Identical silicon to the Intel RS3DC080, so only the PCI SUBSYS vendor separates
## them - matching on VEN_1000 alone would pull in every PowerEdge and double-ticket against iDRAC.
##
## DETECTION NOTES (all three learned the hard way):
##  - Do NOT detect Family A on driver InfName or on driver presence. iaStorAC loads in plain AHCI
##    mode with no RAID configured (observed on an AHCI BDR), so driver presence would false-positive
##    nearly every modern Intel machine. Detect on an Intel RAID VOLUME device, or a staged CLI.
##  - Do NOT detect Family B on InfName either. Windows renames vendor driver packages to oemN.inf
##    when staging them (observed: PERC H730P reports inf=oem3.inf), so '^megasas' silently misses
##    vendor-supplied drivers. Detect on PCI VEN_1000 + SUBSYS vendor from PNPDeviceID instead.
##  - Controller NAME reveals BIOS SATA mode but NOT whether an array exists. Observed on the same
##    Intel silicon family: DEV_A352 "SATA AHCI Controller" (AHCI mode) vs DEV_2822 "Chipset
##    SATA/PCIe RST Premium Controller" (RAID mode). A Dell shipped with SATA Operation = "RAID On"
##    shows the RST Premium name with zero arrays configured, so RAID-mode is reported as context
##    only - it never by itself means Intel RAID is in use.
##
## Windows-native APIs cannot see member-disk state. Observed on a PERC host: a multi-disk array
## returns exactly one Win32_DiskDrive entry. The vendor CLI is the only source of truth.
## Therefore: Intel RAID present + no CLI = Unknown / exit 2, never healthy.

param(
    # Each parameter defaults to its $env: counterpart, so the script is driven equally well
    # by -Parameter (manual/command-line) or by $env: (RMM/unattended). There is no Read-Host
    # and no $env:RMM flag: the script is non-interactive by design and never blocks on input.
    [string]$Description                       = $env:Description,
    [string]$RMMScriptPath                     = $env:RMMScriptPath,
    [string]$CustomFieldIntelRaidUnhealthy     = $env:CustomFieldIntelRaidUnhealthy,
    [string]$CustomFieldIntelRaidStatus        = $env:CustomFieldIntelRaidStatus,
    [string]$CustomFieldIntelRaidHealthDetails = $env:CustomFieldIntelRaidHealthDetails,
    [string]$IntelRaidToolPath                 = $env:IntelRaidToolPath,
    [string]$CliTimeoutSeconds                 = $env:CliTimeoutSeconds,
    [string]$MaxRuntimeSeconds                 = $env:MaxRuntimeSeconds
)

$ScriptLogName = "intel-raid-health-monitor.log"

# Non-interactive hygiene. ProgressPreference matters for real: a progress stream with no
# console attached is a measurable slowdown on some hosts.
$ProgressPreference    = 'SilentlyContinue'
$ConfirmPreference     = 'None'
$ErrorActionPreference = 'Continue'

# --- Input handling ------------------------------------------------------

# Keep $env: in sync with the resolved parameter values so either $Name or $env:Name works
# from here down, regardless of whether the value arrived as a -Parameter or an env var.
if (-not [string]::IsNullOrEmpty($Description))                       { $env:Description                       = $Description }
if (-not [string]::IsNullOrEmpty($RMMScriptPath))                     { $env:RMMScriptPath                     = $RMMScriptPath }
if (-not [string]::IsNullOrEmpty($CustomFieldIntelRaidUnhealthy))     { $env:CustomFieldIntelRaidUnhealthy     = $CustomFieldIntelRaidUnhealthy }
if (-not [string]::IsNullOrEmpty($CustomFieldIntelRaidStatus))        { $env:CustomFieldIntelRaidStatus        = $CustomFieldIntelRaidStatus }
if (-not [string]::IsNullOrEmpty($CustomFieldIntelRaidHealthDetails)) { $env:CustomFieldIntelRaidHealthDetails = $CustomFieldIntelRaidHealthDetails }
if (-not [string]::IsNullOrEmpty($IntelRaidToolPath))                 { $env:IntelRaidToolPath                 = $IntelRaidToolPath }

if ([string]::IsNullOrEmpty($env:CustomFieldIntelRaidUnhealthy))     { $env:CustomFieldIntelRaidUnhealthy     = "intelRaidUnhealthy" }
if ([string]::IsNullOrEmpty($env:CustomFieldIntelRaidStatus))        { $env:CustomFieldIntelRaidStatus        = "intelRaidStatus" }
if ([string]::IsNullOrEmpty($env:CustomFieldIntelRaidHealthDetails)) { $env:CustomFieldIntelRaidHealthDetails = "intelRaidHealthDetails" }

# Timeouts arrive as strings from the RMM. Cast defensively and clamp to sane bounds so a
# fat-fingered preset value can never disable the runaway protection.
$cliTimeout = 120
if (-not [string]::IsNullOrEmpty($CliTimeoutSeconds)) {
    $parsed = 0
    if ([int]::TryParse($CliTimeoutSeconds, [ref]$parsed) -and $parsed -ge 10 -and $parsed -le 900) { $cliTimeout = $parsed }
}
$maxRuntime = 300
if (-not [string]::IsNullOrEmpty($MaxRuntimeSeconds)) {
    $parsed = 0
    if ([int]::TryParse($MaxRuntimeSeconds, [ref]$parsed) -and $parsed -ge 30 -and $parsed -le 1800) { $maxRuntime = $parsed }
}

if ([string]::IsNullOrEmpty($env:Description)) {
    Write-Host "Description was not provided. Defaulting (likely an automated RMM run with no value passed)."
    $env:Description = "No Description"
}

if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
    $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"
}

$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    Write-Host "Creating log directory: $logDir"
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# Transcript rotation - one previous generation, 2 MB cap
if (Test-Path -Path $LogPath) {
    try {
        if ((Get-Item -Path $LogPath).Length -gt 2MB) {
            $rotated = "$LogPath.1"
            if (Test-Path -Path $rotated) { Remove-Item -Path $rotated -Force -ErrorAction SilentlyContinue }
            Move-Item -Path $LogPath -Destination $rotated -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "WARNING: Log rotation failed - $($_.Exception.Message)"
    }
}

# --- Single-instance guard -----------------------------------------------
# The RMM can double-fire a scheduled monitor. An abandoned mutex (previous run killed by a
# timeout) throws AbandonedMutexException from WaitOne but DOES grant ownership, so that case
# must be treated as acquired, not as a concurrent run.

$mutexName = "Global\DTC-IntelRaidHealthMonitor"
$mutex     = $null
$mutexHeld = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    try {
        $mutexHeld = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        Write-Host "WARNING: Previous run terminated without releasing the mutex. Ownership acquired."
        $mutexHeld = $true
    }
} catch {
    Write-Host "WARNING: Could not create mutex, continuing without single-instance guard - $($_.Exception.Message)"
    $mutexHeld = $true
}
if (-not $mutexHeld) {
    Write-Host "Another instance of this monitor is already running. Exiting without alerting."
    exit 0
}

# --- Script logic --------------------------------------------------------

$transcriptStarted = $false
try {
    Start-Transcript -Path $LogPath -ErrorAction Stop | Out-Null
    $transcriptStarted = $true
} catch {
    Write-Host "WARNING: Start-Transcript failed, continuing without transcript - $($_.Exception.Message)"
}

$deadline        = [System.Diagnostics.Stopwatch]::StartNew()
$exitCode        = 0
$overallSeverity = "OK"
$statusSummary   = ""
$findings        = @()
$detailRows      = @()
$adapterSummary  = @()
$diskSummary     = @()
$toolUsed        = "none"
$familyDetected  = "none"
$naDetailText    = ""

$programFilesNative = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$system32Native     = if (-not [Environment]::Is64BitProcess -and $env:PROCESSOR_ARCHITEW6432) {
                          Join-Path $env:WINDIR "SysNative"
                      } else {
                          Join-Path $env:WINDIR "System32"
                      }

function Test-Deadline {
    if ($script:deadline.Elapsed.TotalSeconds -gt $script:maxRuntime) {
        Write-Host "DEADLINE: exceeded $($script:maxRuntime)s budget, aborting remaining work."
        return $true
    }
    return $false
}

function Add-Finding {
    param([string]$Severity, [string]$Message)
    $script:findings += [pscustomobject]@{ Severity = $Severity; Message = $Message }
    if ($Severity -eq "CRITICAL") {
        $script:overallSeverity = "CRITICAL"
        $script:exitCode        = 1
    } elseif ($Severity -eq "WARNING" -and $script:overallSeverity -ne "CRITICAL") {
        $script:overallSeverity = "WARNING"
        $script:exitCode        = 2
    }
}

function Get-DeviceEligibility {
    # Physical hardware only. Virtual guests write nothing at all, leaving the fields genuinely
    # empty. OS type is recorded for context but does NOT gate execution.
    $r = @{ Eligible = $true; Kind = "Physical device"; Reason = "" }

    $cs = $null; $os = $null
    try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem  -OperationTimeoutSec 30 -ErrorAction Stop } catch {
        Write-Host "WARNING: Win32_ComputerSystem query failed - $($_.Exception.Message)"
    }
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 30 -ErrorAction Stop } catch {
        Write-Host "WARNING: Win32_OperatingSystem query failed - $($_.Exception.Message)"
    }

    $model = "$($cs.Model)"
    $manu  = "$($cs.Manufacturer)"
    Write-Host "  Manufacturer: $manu"
    Write-Host "  Model       : $model"
    Write-Host "  ProductType : $($os.ProductType)  (1=Workstation 2=DomainController 3=Server)"

    $virtualModel = 'Virtual Machine|VMware|VirtualBox|KVM|QEMU|Bochs|Parallels|Xen|Virtual Platform|OpenStack|Google Compute Engine|Standard PC \('
    $virtualManu  = 'VMware|innotek|QEMU|Xen|Parallels|Nutanix|Amazon EC2|Google'

    if (($model -and $model -match $virtualModel) -or ($manu -and $manu -match $virtualManu)) {
        $r.Eligible = $false
        $r.Kind     = "Virtual machine"
        $r.Reason   = "virtual guest ($manu / $model) - no physical RAID controller present"
        return $r
    }

    $productType = 0
    if ($os -and $os.ProductType) { $productType = [int]$os.ProductType }
    switch ($productType) {
        1       { $r.Kind = "Physical device (workstation OS)" }
        2       { $r.Kind = "Physical device (domain controller)" }
        3       { $r.Kind = "Physical device (server OS)" }
        default { $r.Kind = "Physical device (OS type unknown)" }
    }

    $vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if ($vmms) { $r.Kind = "$($r.Kind), Hyper-V host" }

    return $r
}

function Invoke-CliWithTimeout {
    # Vendor RAID CLIs block on controller I/O. A wedged controller is exactly the condition this
    # monitor exists to detect, so an unbounded call would hang precisely when it matters most.
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$TimeoutSeconds
    )

    $guid    = [guid]::NewGuid().ToString('N')
    $outFile = Join-Path $env:TEMP "dtc-raid-out-$guid.tmp"
    $errFile = Join-Path $env:TEMP "dtc-raid-err-$guid.tmp"

    $result = [pscustomobject]@{
        Launched = $false; TimedOut = $false; ExitCode = $null
        StdOut   = @();    StdErr   = ""
    }

    $proc = $null
    try {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru `
                    -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ErrorAction Stop
        $result.Launched = $true
    } catch {
        $result.StdErr = "Launch failed: $($_.Exception.Message)"
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
        return $result
    }

    try {
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            $result.TimedOut = $true
            Write-Host "  TIMEOUT: '$FilePath' exceeded $($TimeoutSeconds)s. Killing PID $($proc.Id)."
            try { $proc.Kill() } catch { Write-Host "  WARNING: Kill failed - $($_.Exception.Message)" }
            $null = $proc.WaitForExit(5000)
        } else {
            $result.ExitCode = $proc.ExitCode
        }
    } catch {
        Write-Host "  WARNING: Process wait failed - $($_.Exception.Message)"
    }

    # Handles may linger briefly after a kill. Output-file read failures are non-fatal: the caller
    # already treats an empty StdOut as a WARNING, so swallowing here cannot mask a bad result.
    Start-Sleep -Milliseconds 300
    try {
        if (Test-Path $outFile) { $result.StdOut = @(Get-Content -Path $outFile -ErrorAction Stop) }
    } catch {
        Write-Verbose "Could not read CLI stdout temp file (treated as no output): $($_.Exception.Message)"
    }
    try {
        if (Test-Path $errFile) { $result.StdErr = (Get-Content -Path $errFile -Raw -ErrorAction Stop) }
    } catch {
        Write-Verbose "Could not read CLI stderr temp file: $($_.Exception.Message)"
    }
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    try {
        if ($proc) { $proc.Dispose() }
    } catch {
        Write-Verbose "Process handle dispose failed (non-fatal, process already exited): $($_.Exception.Message)"
    }

    return $result
}

function Find-IntelRaidCli {
    param([string]$Family)

    if (-not [string]::IsNullOrEmpty($env:IntelRaidToolPath)) {
        if (Test-Path -Path $env:IntelRaidToolPath) { return $env:IntelRaidToolPath }
        Write-Host "  WARNING: IntelRaidToolPath set but not found: $env:IntelRaidToolPath"
    }

    if ($Family -eq "A") {
        $candidates = @(
            (Join-Path $programFilesNative "Intel\Intel(R) Virtual RAID on CPU\IntelVROCCli.exe"),
            (Join-Path $programFilesNative "Intel\Intel(R) Rapid Storage Technology\IntelVROCCli.exe"),
            (Join-Path $programFilesNative "Intel\Intel(R) Rapid Storage Technology enterprise\rstcli64.exe"),
            (Join-Path $programFilesNative "Intel\RAID\rstcli64.exe"),
            (Join-Path $programFilesNative "Intel\RSTCLI\rstcli64.exe"),
            (Join-Path $env:ProgramData    "DTC\tools\IntelVROCCli.exe"),
            (Join-Path $env:ProgramData    "DTC\tools\rstcli64.exe")
        )
    } else {
        $candidates = @(
            (Join-Path $programFilesNative "Intel\Intel RAID Web Console 3\storcli64.exe"),
            (Join-Path $programFilesNative "StorCLI\storcli64.exe"),
            (Join-Path $programFilesNative "MegaRAID Storage Manager\storcli64.exe"),
            (Join-Path $env:ProgramData    "DTC\tools\storcli64.exe")
        )
    }

    foreach ($c in $candidates) {
        if (Test-Path -Path $c) { return $c }
    }

    # Bounded DriverStore sweep for Family A. Depth-limited on purpose - a monitor must never
    # recursively crawl a volume.
    if ($Family -eq "A") {
        $repo = Join-Path $system32Native "DriverStore\FileRepository"
        if (Test-Path -Path $repo) {
            try {
                $hit = Get-ChildItem -Path $repo -Filter "iastor*" -Directory -ErrorAction SilentlyContinue |
                       Select-Object -First 40 |
                       ForEach-Object { Get-ChildItem -Path $_.FullName -Filter "*VROCCli*.exe" -File -ErrorAction SilentlyContinue } |
                       Select-Object -First 1
                if ($hit) { return $hit.FullName }
            } catch {
                Write-Host "  WARNING: DriverStore sweep failed - $($_.Exception.Message)"
            }
        }
    }

    return $null
}

function Get-IntelRaidScope {
    $result = @{
        FamilyA = $false; FamilyB = $false; Esrt2 = $false
        RaidModeController = $false
        Adapters = @(); Disks = @()
    }

    $adapters = @()
    try {
        $adapters = Get-CimInstance -ClassName Win32_PnPEntity `
                        -Filter "PNPClass='SCSIAdapter' OR PNPClass='HDC'" `
                        -OperationTimeoutSec 45 -ErrorAction Stop
    } catch {
        Write-Host "WARNING: Win32_PnPEntity adapter query failed or timed out - $($_.Exception.Message)"
    }

    foreach ($a in $adapters) {
        $pnp  = "$($a.PNPDeviceID)"
        $name = "$($a.Name)"
        $svc  = "$($a.Service)"

        # VEN/DEV identify the silicon; SUBSYS identifies the board vendor that branded it.
        $venDev = if ($pnp -match 'VEN_(\w{4})&DEV_(\w{4})') { "$($Matches[1].ToUpper()):$($Matches[2].ToUpper())" } else { "" }
        $subsysVendor = if ($pnp -match 'SUBSYS_(\w{4})(\w{4})') { $Matches[2].ToUpper() } else { "" }
        $brand = switch ($subsysVendor) {
            '8086'  { "board:Intel" }
            '1028'  { "board:Dell" }
            '1000'  { "board:LSI" }
            '15D9'  { "board:Supermicro" }
            default { if ($subsysVendor) { "board:$subsysVendor" } else { "board:unknown" } }
        }
        $tag = if ($venDev) { "$name [$venDev, $brand]" } else { "$name [$brand]" }
        $result.Adapters += $tag
        Write-Host "  Adapter: $name | svc=$svc | $venDev | $brand | $pnp"

        # Intel controller reporting a RAID-mode device name means BIOS SATA Operation is set to
        # RAID. It does NOT mean an array exists - Dell ships many models with "RAID On" by default
        # and no volume configured. Context only; never sets FamilyA.
        if ($pnp -match 'VEN_8086' -and $name -match 'RST|RAID') {
            $result.RaidModeController = $true
            Write-Host "    -> Intel controller in RAID mode (array presence still determined by volume check)"
        }

        if ($pnp -match 'VEN_1000') {
            if ($subsysVendor -eq '8086') {
                $result.FamilyB = $true
                Write-Host "    -> Intel-branded LSI adapter, Family B in scope"
            } elseif ($subsysVendor -eq '1028') {
                Write-Host "    -> Dell PERC (LSI silicon, Dell branded), out of scope - iDRAC covers it, KB 3019"
            } else {
                Write-Host "    -> LSI silicon, non-Intel subsystem, out of scope"
            }
        }

        if ($svc -match '^megasr') { $result.Esrt2 = $true }
    }

    # Family A signal 1: an Intel RAID volume presented to Windows as a disk device.
    # All disks are enumerated and recorded so the negative case is self-diagnosing - without this,
    # a "no Intel RAID" result gives no way to tell a correct negative from a missed array.
    try {
        $allDisks = @(Get-CimInstance -ClassName Win32_DiskDrive -OperationTimeoutSec 45 -ErrorAction Stop)
        foreach ($d in $allDisks) {
            $gb = if ($d.Size) { [math]::Round($d.Size/1GB,0) } else { 0 }
            $result.Disks += "$($d.Model) ($gb GB, $($d.InterfaceType))"
            Write-Host "  Disk: $($d.Model) | $gb GB | $($d.InterfaceType) | $($d.PNPDeviceID)"
            if ($d.Model -match 'Intel.*(Raid|Volume)' -or $d.PNPDeviceID -match 'VEN_INTEL.*RAID') {
                Write-Host "    -> Intel RAID volume device, Family A in scope"
                $result.FamilyA = $true
            }
        }
    } catch {
        Write-Host "WARNING: Win32_DiskDrive query failed or timed out - $($_.Exception.Message)"
    }

    # Family A signal 2: an Intel RAID CLI deliberately staged on disk. Covers the case where the
    # volume model string does not match the regex above (unvalidated against VROC NVMe arrays).
    if (-not $result.FamilyA) {
        if (Find-IntelRaidCli -Family "A") {
            Write-Host "  Intel RAID CLI staged on disk with no matching volume device - probing anyway"
            $result.FamilyA = $true
        }
    }

    return $result
}

function ConvertFrom-RstCliOutput {
    # rstcli/IntelVROCCli --information emits blank-line-separated "Key: Value" blocks.
    # "State:" appears at BOTH volume and disk level, so parsing must be block-scoped.
    # A line-level match on "State: Normal" passes while a member disk is Failed.
    param([string[]]$OutputLines)

    $blocks  = @()
    $current = @{}
    $hasAny  = $false

    foreach ($line in $OutputLines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($hasAny) { $blocks += ,$current; $current = @{}; $hasAny = $false }
            continue
        }
        if ($line -match '^\s*([^:]+?)\s*:\s*(.*?)\s*$') {
            $k = $Matches[1].Trim()
            $v = $Matches[2].Trim()
            if (-not $current.ContainsKey($k)) { $current[$k] = $v }
            $hasAny = $true
        }
    }
    if ($hasAny) { $blocks += ,$current }

    $volumes = @()
    $disks   = @()

    foreach ($b in $blocks) {
        $type = "$($b['Type'])"
        if ($b.ContainsKey('Name') -and $b.ContainsKey('Raid Level')) {
            $volumes += [pscustomobject]@{
                Name = $b['Name']; RaidLevel = $b['Raid Level']; Size = $b['Size']
                NumDisks = $b['Num Disks']; State = $b['State']
            }
        } elseif ($type -eq 'Disk' -or ($b.ContainsKey('ID') -and $b.ContainsKey('Serial Number'))) {
            $disks += [pscustomobject]@{
                Id = $b['ID']; Model = $b['Model']; Serial = $b['Serial Number']
                Usage = $b['Usage']; Size = $b['Size']; State = $b['State']
            }
        }
    }

    return [pscustomobject]@{ Volumes = $volumes; Disks = $disks }
}

function Test-FamilyA {
    param([string]$Cli)

    $run = Invoke-CliWithTimeout -FilePath $Cli -Arguments @('--information') -TimeoutSeconds $script:cliTimeout

    if (-not $run.Launched) {
        Add-Finding -Severity "WARNING" -Message "RST CLI failed to launch: $($run.StdErr)"
        return
    }
    if ($run.TimedOut) {
        Add-Finding -Severity "WARNING" -Message "RST CLI timed out after $($script:cliTimeout)s and was killed - controller may be unresponsive"
        return
    }
    if ($run.StdOut.Count -eq 0) {
        Add-Finding -Severity "WARNING" -Message "RST CLI returned no output (exit $($run.ExitCode)): $($run.StdErr)"
        return
    }

    Write-Host "  CLI returned $($run.StdOut.Count) lines (exit $($run.ExitCode))."
    $run.StdOut | ForEach-Object { Write-Host "    | $_" }

    $parsed = ConvertFrom-RstCliOutput -OutputLines $run.StdOut

    if ($parsed.Volumes.Count -eq 0 -and $parsed.Disks.Count -eq 0) {
        Add-Finding -Severity "WARNING" -Message "RST CLI output unparseable - no volume or disk blocks recognised"
        return
    }

    # State vocabulary from Intel support articles 000100550/000100554/000100555
    # plus Intel staff enumeration in the RST community forum.
    $volCritical = @('failed','missing','incompatible')
    $volWarning  = @('degraded','rebuilding','verifying','verify','initializing','initialize','unknown','offline','locked')
    $volHealthy  = @('normal','online')

    $dskCritical = @('failed','offline')
    $dskWarning  = @('at risk','atrisk','missing','incompatible','unknown','smart event')
    $dskHealthy  = @('normal','online','spare','passthrough','available')

    foreach ($v in $parsed.Volumes) {
        $s = "$($v.State)".ToLower().Trim()
        $script:detailRows += [pscustomobject]@{
            Kind = "Volume"; Ref = $v.Name
            Info = "RAID$($v.RaidLevel), $($v.Size), $($v.NumDisks) disks"; State = $v.State
        }
        if     ($volCritical -contains $s) { Add-Finding -Severity "CRITICAL" -Message "Volume $($v.Name) $($v.State)" }
        elseif ($volWarning  -contains $s) { Add-Finding -Severity "WARNING"  -Message "Volume $($v.Name) $($v.State)" }
        elseif ($volHealthy  -contains $s) { }
        else   { Add-Finding -Severity "WARNING" -Message "Volume $($v.Name) unrecognised state '$($v.State)'" }
    }

    foreach ($d in $parsed.Disks) {
        $s = "$($d.State)".ToLower().Trim()
        $script:detailRows += [pscustomobject]@{
            Kind = "Disk"; Ref = $d.Id
            Info = "$($d.Model), SN $($d.Serial), $($d.Size), $($d.Usage)"; State = $d.State
        }
        if     ($dskCritical -contains $s) { Add-Finding -Severity "CRITICAL" -Message "Disk $($d.Id) $($d.State)" }
        elseif ($dskWarning  -contains $s) { Add-Finding -Severity "WARNING"  -Message "Disk $($d.Id) $($d.State)" }
        elseif ($dskHealthy  -contains $s) { }
        else   { Add-Finding -Severity "WARNING" -Message "Disk $($d.Id) unrecognised state '$($d.State)'" }
    }
}

function Test-FamilyB {
    param([string]$Cli)

    $run = Invoke-CliWithTimeout -FilePath $Cli -Arguments @('/call','show','all','J') -TimeoutSeconds $script:cliTimeout

    if (-not $run.Launched) {
        Add-Finding -Severity "WARNING" -Message "storcli failed to launch: $($run.StdErr)"
        return
    }
    if ($run.TimedOut) {
        Add-Finding -Severity "WARNING" -Message "storcli timed out after $($script:cliTimeout)s and was killed - controller may be unresponsive"
        return
    }
    if ($run.StdOut.Count -eq 0) {
        Add-Finding -Severity "WARNING" -Message "storcli returned no output (exit $($run.ExitCode)): $($run.StdErr)"
        return
    }

    Write-Host "  storcli returned $($run.StdOut.Count) lines (exit $($run.ExitCode))."

    $obj = $null
    try {
        $obj = ($run.StdOut -join "`n") | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Add-Finding -Severity "WARNING" -Message "storcli JSON parse failed - $($_.Exception.Message)"
        return
    }

    if (-not $obj.Controllers) {
        Add-Finding -Severity "WARNING" -Message "storcli returned no controllers"
        return
    }

    $vdHealthy = @('Optl')
    $vdWarning = @('Dgrd','Pdgd','Rec')
    $vdCrit    = @('OfLn','Offln')

    $pdHealthy = @('Onln','UGood','GHS','DHS','JBOD')
    $pdWarning = @('Rbld','Msng','UBad','UBUnsp','Cpybck')
    $pdCrit    = @('Offln','Failed')

    foreach ($ctrl in $obj.Controllers) {
        # storcli exits 0 even on internal failure. Command Status is authoritative.
        $cs = $ctrl.'Command Status'
        if ($cs -and "$($cs.Status)" -ne "Success") {
            Add-Finding -Severity "WARNING" -Message "storcli c$($cs.Controller) status $($cs.Status): $($cs.Description)"
            continue
        }

        $rd = $ctrl.'Response Data'
        if (-not $rd) { continue }

        foreach ($vd in @($rd.'VD LIST')) {
            if (-not $vd) { continue }
            $st  = "$($vd.State)".Trim()
            $ref = "$($vd.'DG/VD')"
            $script:detailRows += [pscustomobject]@{
                Kind = "VirtualDrive"; Ref = $ref
                Info = "$($vd.TYPE), $($vd.Size), $($vd.Name)"; State = $st
            }
            if     ($vdCrit    -contains $st) { Add-Finding -Severity "CRITICAL" -Message "VD $ref $st" }
            elseif ($vdWarning -contains $st) { Add-Finding -Severity "WARNING"  -Message "VD $ref $st" }
            elseif ($vdHealthy -contains $st) { }
            else   { Add-Finding -Severity "WARNING" -Message "VD $ref unrecognised state '$st'" }
        }

        foreach ($pd in @($rd.'PD LIST')) {
            if (-not $pd) { continue }
            $st  = "$($pd.State)".Trim()
            $ref = "E$($pd.EID):S$($pd.Slt)"
            $script:detailRows += [pscustomobject]@{
                Kind = "PhysicalDisk"; Ref = $ref
                Info = "$($pd.Model), SN $("$($pd.SN)".Trim()), $($pd.Size), $($pd.Intf) $($pd.Med)"; State = $st
            }
            if     ($pdCrit    -contains $st) { Add-Finding -Severity "CRITICAL" -Message "PD $ref $st" }
            elseif ($pdWarning -contains $st) { Add-Finding -Severity "WARNING"  -Message "PD $ref $st" }
            elseif ($pdHealthy -contains $st) { }
            else   { Add-Finding -Severity "WARNING" -Message "PD $ref unrecognised state '$st'" }
        }
    }
}

# --- Main ----------------------------------------------------------------

Write-Host "Description: $env:Description"
Write-Host "Log path: $LogPath"
Write-Host "PowerShell: $($PSVersionTable.PSVersion) | 64-bit process: $([Environment]::Is64BitProcess)"
Write-Host "Budgets: CLI timeout $($cliTimeout)s | overall deadline $($maxRuntime)s"
Write-Host ""

Write-Host "Evaluating device eligibility (physical hardware only)..."
$eligibility = Get-DeviceEligibility
Write-Host "  Classified as: $($eligibility.Kind)"
Write-Host ""

if (-not $eligibility.Eligible) {
    Write-Host "OUT OF SCOPE: $($eligibility.Reason)"
    Write-Host "No custom fields will be written. Fields remain empty on this device by design."
    Write-Host ""
    Write-Host "Exiting with code 0 (out of scope)"
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { Write-Verbose "Stop-Transcript failed on out-of-scope exit: $($_.Exception.Message)" }
    }
    try {
        if ($mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
    } catch {
        Write-Verbose "Mutex release failed on out-of-scope exit (abandoned mutex is recovered by the next run): $($_.Exception.Message)"
    }
    exit 0
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "PowerShell 5.1 or later required. Detected $($PSVersionTable.PSVersion)."
    $overallSeverity = "WARNING"
    $exitCode        = 2
    $statusSummary   = "UNKNOWN | PowerShell $($PSVersionTable.PSVersion) below minimum 5.1 - cannot evaluate"
} else {
    Write-Host "Scanning storage adapters and disk devices..."
    $scope          = Get-IntelRaidScope
    $adapterSummary = $scope.Adapters
    $diskSummary    = $scope.Disks
    Write-Host ""

    if ($scope.Esrt2) {
        Add-Finding -Severity "WARNING" -Message "Intel ESRT2 (megasr) present - not supported by this monitor, check manually"
    }

    $familiesToCheck = @()
    if ($scope.FamilyA) { $familiesToCheck += "A" }
    if ($scope.FamilyB) { $familiesToCheck += "B" }
    $familyDetected = if ($familiesToCheck.Count -eq 0) { "none" } else { ($familiesToCheck -join "+") }

    Write-Host "Intel RAID family detected: $familyDetected"
    Write-Host ""

    if ($familiesToCheck.Count -eq 0) {
        Write-Host "No Intel RAID array present. Nothing to evaluate."
        if ($findings.Count -eq 0) {
            if ($scope.RaidModeController) {
                $statusSummary = "Not Available | Intel RST controller in RAID mode, no array configured"
                $naDetailText  = "Intel RST controller is present and the BIOS is in RAID mode, but no RAID array is configured on this host (N/A)."
            } else {
                $statusSummary = "Not Available | no Intel RAID controller or array on this host"
                $naDetailText  = "No Intel RAID controller or array on this host (N/A)."
            }
        }
    } else {
        foreach ($fam in $familiesToCheck) {
            if (Test-Deadline) {
                Add-Finding -Severity "WARNING" -Message "Script deadline reached before family $fam was evaluated"
                break
            }

            $label = if ($fam -eq "A") { "RST/RSTe/VROC" } else { "Intel RS3/MegaRAID" }
            Write-Host "Evaluating family $fam ($label)..."

            $cli = Find-IntelRaidCli -Family $fam
            if (-not $cli) {
                # No CLI means no truth. Deliberately loud - it is not good news.
                Add-Finding -Severity "WARNING" -Message "$label present but no management CLI found - status undetermined"
                Write-Host "  No CLI located. Reporting Unknown."
                continue
            }

            Write-Host "  Using CLI: $cli"
            $leaf     = Split-Path -Leaf $cli
            $toolUsed = if ($toolUsed -eq "none") { $leaf } else { "$toolUsed + $leaf" }

            if ($fam -eq "A") { Test-FamilyA -Cli $cli } else { Test-FamilyB -Cli $cli }
            Write-Host ""
        }
    }

    if ([string]::IsNullOrEmpty($statusSummary)) {
        if ($findings.Count -eq 0) {
            $vols = @($detailRows | Where-Object { $_.Kind -in @("Volume","VirtualDrive") }).Count
            $dsks = @($detailRows | Where-Object { $_.Kind -in @("Disk","PhysicalDisk") }).Count
            $statusSummary = "OK | $familyDetected | $vols volume(s), $dsks disk(s) healthy | tool=$toolUsed"
        } else {
            $crit  = @($findings | Where-Object { $_.Severity -eq "CRITICAL" })
            $warn  = @($findings | Where-Object { $_.Severity -eq "WARNING" })
            $parts = @()
            foreach ($f in ($crit + $warn)) { $parts += $f.Message }
            $statusSummary = "$overallSeverity | $familyDetected | " + ($parts -join "; ")
        }
    }
}

if ($statusSummary.Length -gt 197) { $statusSummary = $statusSummary.Substring(0,197) + "..." }
$unhealthyFlag = if ($exitCode -eq 0) { 0 } else { 1 }

Write-Host "===================================================================="
Write-Host "RESULT: $statusSummary"
Write-Host "Elapsed: $([math]::Round($deadline.Elapsed.TotalSeconds,1))s"
Write-Host "===================================================================="

# --- Build WYSIWYG detail field -----------------------------------------

$sb = New-Object System.Text.StringBuilder

if ($naDetailText) {
    [void]$sb.Append("<p>$naDetailText</p>")
} else {
    $colour = switch ($overallSeverity) { "CRITICAL" { "#b22222" } "WARNING" { "#c77800" } default { "#228b22" } }
    [void]$sb.Append("<p><strong>Intel RAID Health:</strong> <span style=""color:$colour;"">$overallSeverity</span></p>")
    [void]$sb.Append("<p>Family: $familyDetected &nbsp;|&nbsp; Tool: $toolUsed</p>")
}

[void]$sb.Append("<p>Device: $($eligibility.Kind) &nbsp;|&nbsp; Checked: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))</p>")

if ($findings.Count -gt 0) {
    [void]$sb.Append("<p><strong>Findings</strong></p><ul>")
    foreach ($f in $findings) {
        $fc = if ($f.Severity -eq "CRITICAL") { "#b22222" } else { "#c77800" }
        [void]$sb.Append("<li><span style=""color:$fc;""><strong>$($f.Severity)</strong></span> - $($f.Message)</li>")
    }
    [void]$sb.Append("</ul>")
}

if ($detailRows.Count -gt 0) {
    [void]$sb.Append("<p><strong>RAID Inventory</strong></p>")
    [void]$sb.Append("<table><thead><tr><th>Type</th><th>Ref</th><th>Detail</th><th>State</th></tr></thead><tbody>")
    foreach ($r in $detailRows) {
        [void]$sb.Append("<tr><td>$($r.Kind)</td><td>$($r.Ref)</td><td>$($r.Info)</td><td>$($r.State)</td></tr>")
    }
    [void]$sb.Append("</tbody></table>")
}

if ($adapterSummary.Count -gt 0) {
    [void]$sb.Append("<p><strong>Storage Adapters Inspected</strong></p><ul>")
    foreach ($a in $adapterSummary) { [void]$sb.Append("<li>$a</li>") }
    [void]$sb.Append("</ul>")
}

if ($diskSummary.Count -gt 0) {
    [void]$sb.Append("<p><strong>Disks Inspected</strong></p><ul>")
    foreach ($d in $diskSummary) { [void]$sb.Append("<li>$d</li>") }
    [void]$sb.Append("</ul>")
}

$detailsHtml = $sb.ToString()

# --- Emit results --------------------------------------------------------

Write-Host ""
Write-Host "---------- intelRaidUnhealthy (checkbox payload) ----------"
Write-Host $unhealthyFlag
Write-Host ""
Write-Host "---------- intelRaidStatus (text payload, $($statusSummary.Length)/200 chars) ----------"
Write-Host $statusSummary
Write-Host ""
Write-Host "---------- intelRaidHealthDetails (WYSIWYG payload) ----------"
Write-Host $detailsHtml
Write-Host "--------------------------------------------------------------"
Write-Host ""

# --- Write custom fields (opt-in) ----------------------------------------

if ($env:WriteCustomFields -eq "1") {
    $ninjaSet = Get-Command -Name Ninja-Property-Set -ErrorAction SilentlyContinue
    if ($ninjaSet) {
        $writes = @(
            @{ Name = $env:CustomFieldIntelRaidUnhealthy;     Value = $unhealthyFlag },
            @{ Name = $env:CustomFieldIntelRaidStatus;        Value = $statusSummary },
            @{ Name = $env:CustomFieldIntelRaidHealthDetails; Value = $detailsHtml }
        )
        foreach ($w in $writes) {
            try {
                Ninja-Property-Set -Name $w.Name -Value $w.Value
                Write-Host "Wrote '$($w.Name)'"
            } catch {
                Write-Host "ERROR: Failed to write '$($w.Name)' - $_"
            }
        }
    } else {
        Write-Host "WriteCustomFields=1 but Ninja-Property-Set is unavailable - skipped."
    }
} else {
    Write-Host "Report-only mode (WriteCustomFields not set to 1). No custom field writes attempted."
}

Write-Host ""
Write-Host "Exiting with code $exitCode (0=OK, 2=WARNING, 1=CRITICAL)"

if ($transcriptStarted) {
    try { Stop-Transcript | Out-Null } catch { Write-Verbose "Stop-Transcript failed on normal exit: $($_.Exception.Message)" }
}

try {
    if ($mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
} catch {
    Write-Verbose "Mutex release failed on normal exit (abandoned mutex is recovered by the next run): $($_.Exception.Message)"
}

exit $exitCode