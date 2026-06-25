## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $CUSTOM_FIELD_UNSUPPORTED_FOUND / $env:CUSTOM_FIELD_UNSUPPORTED_FOUND - NinjaRMM custom field name (checkbox) - set to 1 if unsupported software detected alongside OpenDental
## $CUSTOM_FIELD_APPS_FOUND / $env:CUSTOM_FIELD_APPS_FOUND - NinjaRMM custom field name (text) - comma-separated list of unsupported apps found
## $DESCRIPTION / $env:DESCRIPTION - Ticket # and/or initials for audit trail
## $RMM_SCRIPT_PATH / $env:RMM_SCRIPT_PATH - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-DESCRIPTION ...) or from an RMM that supplies values as env variables.
    [string]$DESCRIPTION                    = $env:DESCRIPTION,
    [string]$CUSTOM_FIELD_UNSUPPORTED_FOUND = $env:CUSTOM_FIELD_UNSUPPORTED_FOUND,
    [string]$CUSTOM_FIELD_APPS_FOUND        = $env:CUSTOM_FIELD_APPS_FOUND,
    [string]$RMM_SCRIPT_PATH                = $env:RMM_SCRIPT_PATH
)

$SCRIPT_LOG_NAME = "opendental-detect-integrations.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Mirror the resolved RMMScriptPath parameter into $env: so the log-path logic below
# can reference $env:RMM_SCRIPT_PATH whichever form the value arrived in.
if (-not [string]::IsNullOrEmpty($RMM_SCRIPT_PATH)) { $env:RMM_SCRIPT_PATH = $RMM_SCRIPT_PATH }

# Default the audit-trail description if it was not supplied.
if (-not $DESCRIPTION) {
    Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
    $DESCRIPTION = "No description"
}

if (-not $CUSTOM_FIELD_UNSUPPORTED_FOUND) {
    Write-Host "[WARNING] No CUSTOM_FIELD_UNSUPPORTED_FOUND value set. Custom field write-back will be skipped."
}

# Store logs under $env:RMM_SCRIPT_PATH if provided, otherwise the standard Windows logs directory.
if ($env:RMM_SCRIPT_PATH) {
    $LOG_PATH = "$env:RMM_SCRIPT_PATH\logs\$SCRIPT_LOG_NAME"
} else {
    $LOG_PATH = "$env:WINDIR\logs\$SCRIPT_LOG_NAME"
}

Start-Transcript -Path $LOG_PATH

Write-Host "Description: $DESCRIPTION"
Write-Host "Log path: $LOG_PATH"
Write-Host "Custom Field (Unsupported Found): $CUSTOM_FIELD_UNSUPPORTED_FOUND"
Write-Host "Custom Field (Apps Found): $CUSTOM_FIELD_APPS_FOUND"

# ── Configuration ────────────────────────────────────────────────────────────
# Each entry: friendly name + array of detection strings to match against
# registry DisplayName, folder names, process names, service names, etc.
# These are unsupported third-party apps that install locally rather than
# integrating through OpenDental's API.

$integrations = [ordered]@{
    "Adit / Pozative"    = @("Adit", "Pozative")
    "Clover Connect"     = @("Clover Connect", "CloverConnect", "Clover Connector")
    "Denti AI"           = @("Denti AI", "DentiAI", "Denti.AI")
    "Enlive Dental"      = @("Enlive", "EnliveDental")
    "Jarvis Analytics"   = @("Jarvis Analytics", "JarvisAnalytics")
    "Kolla"              = @("Kolla")
    "Lassie"             = @("Lassie")
    "Legwork"            = @("Legwork")
    "Lighthouse"         = @("Lighthouse", "Lighthouse 360", "Lighthouse360")
    "MConsent"           = @("MConsent")
    "Nadapayments"       = @("Nadapayments", "NadaPay", "Nada Payments")
    "NexHealth"          = @("NexHealth", "Nex Health")
    "Pay Proudly"        = @("Pay Proudly", "PayProudly")
    "PracticeDilly"      = @("PracticeDilly", "Practice Dilly")
    "Practice Mojo"      = @("Practice Mojo", "PracticeMojo")
    "ScribeHealth.ai"    = @("ScribeHealth", "Scribe Health")
    "Stratus AI"         = @("Stratus AI", "StratusAI", "Stratus Dental")
    "Teamio"             = @("Teamio")
    "TopCard"            = @("TopCard", "Top Card")
    "Treatment24Seven"   = @("Treatment24Seven", "Treatment 24 Seven", "Treatment24/7")
    "UseMyStats"         = @("UseMyStats", "Use My Stats")
    "Verrific"           = @("Verrific")
    "Wellfit"            = @("Wellfit", "WellFit Financial")
    "Yapi"               = @("Yapi")
}

# ── Helper Functions ─────────────────────────────────────────────────────────

function Get-InstalledSoftware {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $entries = foreach ($path in $paths) {
        try {
            Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName } |
                Select-Object DisplayName, DisplayVersion, InstallLocation, Publisher
        } catch { }
    }
    $entries
}

function Test-PatternMatch {
    param(
        [string]$target,
        [string[]]$patterns
    )
    foreach ($p in $patterns) {
        if ($target -match [regex]::Escape($p)) { return $true }
    }
    return $false
}

function Find-InProgramFiles {
    param([string[]]$patterns)

    $roots = @(
        $env:ProgramFiles
        ${env:ProgramFiles(x86)}
        "$env:ProgramData"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    foreach ($root in $roots) {
        $dirs = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue
        foreach ($dir in $dirs) {
            foreach ($p in $patterns) {
                if ($dir.Name -match [regex]::Escape($p)) {
                    return @{ Path = $dir.FullName; Match = $p }
                }
            }
        }
    }
    return $null
}

function Find-InProcesses {
    param([string[]]$patterns)

    $procs = Get-Process -ErrorAction SilentlyContinue |
        Select-Object ProcessName, @{N='Path';E={try{$_.Path}catch{$null}}} -Unique

    foreach ($proc in $procs) {
        foreach ($p in $patterns) {
            $escaped = [regex]::Escape($p)
            if ($proc.ProcessName -match $escaped -or ($proc.Path -and $proc.Path -match $escaped)) {
                return @{ Process = $proc.ProcessName; Match = $p }
            }
        }
    }
    return $null
}

function Find-InServices {
    param([string[]]$patterns)

    $services = Get-Service -ErrorAction SilentlyContinue

    foreach ($svc in $services) {
        foreach ($p in $patterns) {
            $escaped = [regex]::Escape($p)
            if ($svc.Name -match $escaped -or $svc.DisplayName -match $escaped) {
                return @{ Service = $svc.DisplayName; Status = $svc.Status; Match = $p }
            }
        }
    }
    return $null
}

function Find-InScheduledTasks {
    param([string[]]$patterns)

    try {
        $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue
        foreach ($task in $tasks) {
            foreach ($p in $patterns) {
                if ($task.TaskName -match [regex]::Escape($p)) {
                    return @{ Task = $task.TaskName; Match = $p }
                }
            }
        }
    } catch { }
    return $null
}

# ── Main Detection ───────────────────────────────────────────────────────────

Write-Host "============================================"
Write-Host " OpenDental Integration Detection Script"
Write-Host " $(Get-Date -Format 'yyyy-MM-dd hh:mm tt')"
Write-Host "============================================"
Write-Host ""

# Step 1: Detect OpenDental
$installedSoftware = Get-InstalledSoftware
$openDentalPatterns = @("Open Dental", "OpenDental")

$odRegistry = $installedSoftware | Where-Object {
    Test-PatternMatch -Target $_.DisplayName -Patterns $openDentalPatterns
}

$odFolder = Find-InProgramFiles -Patterns $openDentalPatterns
$odProcess = Find-InProcesses -Patterns (@("OpenDental") + $openDentalPatterns)
$odService = Find-InServices -Patterns $openDentalPatterns

$openDentalFound = $false
$odDetails = @()

if ($odRegistry) {
    $openDentalFound = $true
    foreach ($entry in $odRegistry) {
        $odDetails += "  Registry: $($entry.DisplayName) v$($entry.DisplayVersion)"
        if ($entry.InstallLocation) { $odDetails += "  Install Path: $($entry.InstallLocation)" }
    }
}
if ($odFolder) {
    $openDentalFound = $true
    $odDetails += "  Folder: $($odFolder.Path)"
}
if ($odProcess) {
    $openDentalFound = $true
    $odDetails += "  Process: $($odProcess.Process) (running)"
}
if ($odService) {
    $openDentalFound = $true
    $odDetails += "  Service: $($odService.Service) ($($odService.Status))"
}

if (-not $openDentalFound) {
    Write-Host "[NOT FOUND] OpenDental is not installed on this machine."
    Write-Host ""
    Write-Host "No integration scan performed."

    # Write false to custom fields if configured
    if ($CUSTOM_FIELD_UNSUPPORTED_FOUND) {
        Ninja-Property-Set $CUSTOM_FIELD_UNSUPPORTED_FOUND 0
        Write-Host "Custom field '$CUSTOM_FIELD_UNSUPPORTED_FOUND' set to: 0 (OpenDental not found)"
    }
    if ($CUSTOM_FIELD_APPS_FOUND) {
        Ninja-Property-Set $CUSTOM_FIELD_APPS_FOUND ""
        Write-Host "Custom field '$CUSTOM_FIELD_APPS_FOUND' cleared."
    }

    Stop-Transcript
    exit 0
}

Write-Host "[FOUND] OpenDental detected:"
foreach ($d in $odDetails) { Write-Host $d }
Write-Host ""

# Step 2: Scan for unsupported third-party integrations
Write-Host "Scanning for unsupported third-party integrations..."
Write-Host "--------------------------------------------"

$detected = @()
$notFound = @()

foreach ($name in $integrations.Keys) {
    $patterns = $integrations[$name]
    $sources = @()

    # Registry check
    $regMatch = $installedSoftware | Where-Object {
        Test-PatternMatch -Target $_.DisplayName -Patterns $patterns
    }
    if ($regMatch) {
        foreach ($r in $regMatch) {
            $sources += "Registry ($($r.DisplayName) v$($r.DisplayVersion))"
        }
    }

    # Program Files check
    $folderMatch = Find-InProgramFiles -Patterns $patterns
    if ($folderMatch) {
        $sources += "Folder ($($folderMatch.Path))"
    }

    # Process check
    $procMatch = Find-InProcesses -Patterns $patterns
    if ($procMatch) {
        $sources += "Process ($($procMatch.Process))"
    }

    # Service check
    $svcMatch = Find-InServices -Patterns $patterns
    if ($svcMatch) {
        $sources += "Service ($($svcMatch.Service) - $($svcMatch.Status))"
    }

    # Scheduled Task check
    $taskMatch = Find-InScheduledTasks -Patterns $patterns
    if ($taskMatch) {
        $sources += "Scheduled Task ($($taskMatch.Task))"
    }

    if ($sources.Count -gt 0) {
        $detected += [PSCustomObject]@{
            Name    = $name
            Sources = $sources -join "; "
        }
        Write-Host "[FOUND] $name"
        foreach ($s in $sources) {
            Write-Host "        $s"
        }
    } else {
        $notFound += $name
    }
}

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "============================================"
Write-Host " Summary"
Write-Host "============================================"
Write-Host "OpenDental: INSTALLED"
Write-Host "Integrations Found: $($detected.Count) of $($integrations.Count)"
Write-Host ""

if ($detected.Count -gt 0) {
    Write-Host "Detected integrations:"
    foreach ($d in $detected) {
        Write-Host "  + $($d.Name)"
    }
} else {
    Write-Host "No unsupported third-party integrations detected."
}

Write-Host ""
Write-Host "Not detected:"
foreach ($n in $notFound) {
    Write-Host "  - $n"
}

# ── Write Results to NinjaRMM Custom Fields ──────────────────────────────────

if ($CUSTOM_FIELD_UNSUPPORTED_FOUND) {
    if ($detected.Count -gt 0) {
        Ninja-Property-Set $CUSTOM_FIELD_UNSUPPORTED_FOUND 1
        Write-Host "Custom field '$CUSTOM_FIELD_UNSUPPORTED_FOUND' set to: 1 (unsupported apps found)"
    } else {
        Ninja-Property-Set $CUSTOM_FIELD_UNSUPPORTED_FOUND 0
        Write-Host "Custom field '$CUSTOM_FIELD_UNSUPPORTED_FOUND' set to: 0 (no unsupported apps)"
    }
}

if ($CUSTOM_FIELD_APPS_FOUND) {
    if ($detected.Count -gt 0) {
        $APPS_LIST = ($detected.Name -join ", ")
        if ($APPS_LIST.Length -gt 190) {
            $APPS_LIST = $APPS_LIST.Substring(0, 190) + "..."
        }
        Ninja-Property-Set $CUSTOM_FIELD_APPS_FOUND $APPS_LIST
        Write-Host "Custom field '$CUSTOM_FIELD_APPS_FOUND' set to: $APPS_LIST"
    } else {
        Ninja-Property-Set $CUSTOM_FIELD_APPS_FOUND ""
        Write-Host "Custom field '$CUSTOM_FIELD_APPS_FOUND' cleared."
    }
}

Stop-Transcript
