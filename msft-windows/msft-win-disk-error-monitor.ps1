# Keeps output simple for NinjaOne to parse (ErrorDetected=0/1), with optional counts per Event ID and SMART status.

# Expands coverage to catch driver-specific resets/timeouts that don’t always appear under Source=Disk.

# Safe to run on endpoints without SMART WMI class; it just skips that check.



param(
    [int]$Minutes = 30
)

$start = (Get-Date).AddMinutes(-$Minutes)

# Common disk / storage error IDs
# 7,11,29,51,153 (Disk) plus 129 (reset), 157 (surprise removal), 140 (flush failure)
$eventIds   = 7,11,29,51,129,140,153,157

# Providers that commonly log disk I/O issues on different chipsets/drivers
$providers  = @(
    'Disk',      # classic disk errors incl. 7/11/29/51/153
    'Ntfs',      # filesystem-level I/O issues (e.g., 140)
    'storahci',  # MS AHCI
    'iaStorA',   # Intel RST
    'iaStorV',   # older Intel
    'stornvme',  # Microsoft NVMe
    'nvme',      # vendor NVMe providers sometimes use this name
    'StorPort',  # storport miniport layer (resets/timeouts)
    'partmgr'    # partition manager (removals/changes)
)

$allEvents = @()

foreach ($p in $providers) {
    try {
        $ev = Get-WinEvent -FilterHashtable @{
            LogName      = 'System'
            ProviderName = $p
            Id           = $eventIds
            StartTime    = $start
        } -ErrorAction SilentlyContinue
        if ($ev) { $allEvents += $ev }
    } catch {
        # ignore provider-specific lookup failures
    }
}

# SMART: Predictive failure (true means the drive thinks it's failing)
$smartFailure = $false
try {
    # MS storage driver SMART (WMI)
    $smart = Get-WmiObject -Namespace root\wmi -Class MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue
    if ($smart) {
        $smartFailure = ($smart | Where-Object { $_.PredictFailure -eq $true }).Count -gt 0
    }
} catch {
    # ignore if class not available
}

$hasEvents = ($allEvents.Count -gt 0)

if ($hasEvents -or $smartFailure) {
    $summary = @()
    if ($hasEvents) {
        $byId = $allEvents | Group-Object Id | Sort-Object Name
        $summary += ($byId | ForEach-Object { "ID$($_.Name)=$($_.Count)" })
    }
    if ($smartFailure) { $summary += "SMART=PredictedFailure" }

    Write-Output ("ErrorDetected=1; " + ($summary -join '; '))
    exit 1
} else {
    Write-Output "ErrorDetected=0"
    exit 0
}
