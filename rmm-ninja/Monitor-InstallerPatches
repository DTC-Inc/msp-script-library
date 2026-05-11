<#
.SYNOPSIS
    DTC Installer Patch Monitor — Weekly scan of C:\Windows\Installer for orphaned .msi/.msp files.
.DESCRIPTION
    Scans C:\Windows\Installer to identify orphaned installer cache files by querying the
    Windows Installer registry database. Reports results to NinjaRMM custom fields and
    Windows Event Log. Makes ZERO filesystem changes — read-only analysis only.

    Deployment: NinjaRMM scheduled script, run weekly (e.g., Sunday 2:00 AM).
    Runs as: SYSTEM

    Reference: HALO Ticket 1125653 — 128 GB orphaned patches, 96.1% disk utilization.
.NOTES
    Author:  DTC Engineering
    Version: 1.0.0
    Requires: PowerShell 5.1, Windows 10/11/Server 2019/2022
    Dependencies: None (self-contained)
#>

#Requires -Version 5.1

# ============================================================================
# CONFIGURATION — Adjust thresholds here
# ============================================================================
$WarningThresholdGB  = 20   # Total Installer folder size >= this = "Warning"
$CriticalThresholdGB = 50   # Total Installer folder size >= this = "Critical"

# ============================================================================
# SHARED FUNCTION: Get-OrphanedInstallerFiles
# ============================================================================
function Get-OrphanedInstallerFiles {
    <#
    .SYNOPSIS
        Identifies orphaned .msi and .msp files in C:\Windows\Installer by querying
        the Windows Installer registry database.
    .DESCRIPTION
        Enumerates the Windows Installer registry database to build a set of "referenced"
        installer files (files that belong to currently installed products/patches).
        Any .msi/.msp file in C:\Windows\Installer that is NOT in the referenced set
        is classified as orphaned.

        Does NOT use Win32_Product WMI class (triggers MSI reconfigure/consistency check).
        Uses registry queries only.
    .OUTPUTS
        PSCustomObject with properties:
        - InstallerFolderTotalBytes (long) — folder total incl. $PatchCache$ (matches Explorer)
        - TotalFiles (int) — MSI/MSP files only
        - TotalSizeBytes (long) — MSI/MSP files only
        - ReferencedFiles (array of PSCustomObject: FullPath, SizeBytes)
        - ReferencedCount (int)
        - ReferencedSizeBytes (long)
        - OrphanedFiles (array of PSCustomObject: FullPath, SizeBytes, LastWriteTime)
        - OrphanedCount (int)
        - OrphanedSizeBytes (long)
        - PatchCacheSizeBytes (long)
        - ScanDuration (timespan)
        - Errors (array of strings)
    #>
    [CmdletBinding()]
    param()

    $startTime = Get-Date
    $registryErrors = [System.Collections.Generic.List[string]]::new()

    # --- STEP 1: Build the "referenced files" set ---
    # The Windows Installer stores product/patch cache file references in the registry under
    # HKLM:\...\Installer\UserData\<SID>\Products and \Patches for each SID.
    # Enumerate ALL SIDs (not just S-1-5-18) to capture per-user installations that also
    # reference files in C:\Windows\Installer. Missing per-user SIDs inflates orphan counts.
    #
    # LocalPackage values contain standard file paths — no GUID decompression needed.
    # Test-Path is intentionally omitted: the HashSet is only compared against Get-ChildItem
    # output (guaranteed-existing files), so stale registry paths are harmless dead weight.

    $referencedFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    $userDataPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData"
    try {
        if (-not (Test-Path $userDataPath)) {
            throw "Installer UserData registry path not found"
        }
        $sidKeys = Get-ChildItem $userDataPath -ErrorAction Stop
    } catch {
        throw "Failed to read Installer UserData registry path: $($_.Exception.Message)"
    }

    foreach ($sidKey in $sidKeys) {
        # Collect referenced MSI files from Products
        $productsPath = Join-Path $sidKey.PSPath "Products"
        try {
            if (Test-Path $productsPath) {
                foreach ($product in (Get-ChildItem $productsPath -ErrorAction Stop)) {
                    try {
                        $installProps = Join-Path $product.PSPath "InstallProperties"
                        if (Test-Path $installProps) {
                            $localPackage = (Get-ItemProperty $installProps -Name "LocalPackage" -ErrorAction SilentlyContinue).LocalPackage
                            if ($localPackage) {
                                [void]$referencedFiles.Add($localPackage)
                            }
                        }
                    } catch {
                        $registryErrors.Add("Product $($product.PSChildName) (SID $($sidKey.PSChildName)): $($_.Exception.Message)")
                    }
                }
            }
        } catch {
            $registryErrors.Add("Products key for SID $($sidKey.PSChildName): $($_.Exception.Message)")
        }

        # Collect referenced MSP files from Patches
        $patchesPath = Join-Path $sidKey.PSPath "Patches"
        try {
            if (Test-Path $patchesPath) {
                foreach ($patch in (Get-ChildItem $patchesPath -ErrorAction Stop)) {
                    try {
                        $localPackage = (Get-ItemProperty $patch.PSPath -Name "LocalPackage" -ErrorAction SilentlyContinue).LocalPackage
                        if ($localPackage) {
                            [void]$referencedFiles.Add($localPackage)
                        }
                    } catch {
                        $registryErrors.Add("Patch $($patch.PSChildName) (SID $($sidKey.PSChildName)): $($_.Exception.Message)")
                    }
                }
            }
        } catch {
            $registryErrors.Add("Patches key for SID $($sidKey.PSChildName): $($_.Exception.Message)")
        }
    }

    # --- STEP 2: Enumerate actual files in C:\Windows\Installer ---
    # Top-level only — do NOT include $PatchCache$ subfolder contents
    $installerPath = Join-Path $env:SystemRoot "Installer"
    # Enumerate all files first (unfiltered) for accurate folder-total metric, then filter for orphan detection.
    # This avoids misleading operators when comparing script output against Explorer-reported folder sizes.
    $allInstallerFiles = Get-ChildItem $installerPath -File -Force -ErrorAction SilentlyContinue
    $allFiles = $allInstallerFiles | Where-Object { $_.Extension -in '.msi', '.msp' }

    # --- STEP 3: Compare and classify ---
    # Use List<T> instead of @() += to avoid O(n^2) array reallocation on machines with thousands of files
    $referenced = [System.Collections.Generic.List[PSCustomObject]]::new()
    $orphaned   = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($file in $allFiles) {
        if ($referencedFiles.Contains($file.FullName)) {
            $referenced.Add([PSCustomObject]@{
                FullPath  = $file.FullName
                SizeBytes = $file.Length
            })
        } else {
            $orphaned.Add([PSCustomObject]@{
                FullPath      = $file.FullName
                SizeBytes     = $file.Length
                LastWriteTime = $file.LastWriteTime
            })
        }
    }

    # --- STEP 4: Measure $PatchCache$ separately ---
    $patchCachePath = Join-Path $installerPath '$PatchCache$'
    $patchCacheSize = [long]0
    if (Test-Path $patchCachePath) {
        $patchCacheSize = (Get-ChildItem $patchCachePath -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum -as [long]
        if (-not $patchCacheSize) { $patchCacheSize = [long]0 }
    }

    # --- STEP 5: Return results ---
    # Null-coerce all Measure-Object .Sum results — .Sum returns $null on empty collections.
    # InstallerFolderTotalBytes = top-level files + $PatchCache$ (matches Explorer-reported size).
    # TotalFiles/TotalSizeBytes = MSI/MSP-only subset used for orphan detection.
    $topLevelTotal = ($allInstallerFiles | Measure-Object Length -Sum).Sum -as [long]
    [PSCustomObject]@{
        InstallerFolderTotalBytes = $topLevelTotal + $patchCacheSize
        TotalFiles                = ($allFiles | Measure-Object).Count -as [int]
        TotalSizeBytes            = ($allFiles | Measure-Object Length -Sum).Sum -as [long]
        ReferencedFiles           = $referenced
        ReferencedCount           = $referenced.Count
        ReferencedSizeBytes       = ($referenced | Measure-Object SizeBytes -Sum).Sum -as [long]
        OrphanedFiles             = $orphaned
        OrphanedCount             = $orphaned.Count
        OrphanedSizeBytes         = ($orphaned | Measure-Object SizeBytes -Sum).Sum -as [long]
        PatchCacheSizeBytes       = $patchCacheSize
        ScanDuration              = (Get-Date) - $startTime
        Errors                    = $registryErrors
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
Write-Output "DTC Installer Patch Monitor — Starting scan..."
Write-Output "Timestamp: $(Get-Date -Format 'o')"
Write-Output ""

$status = "Healthy"
$installerFolderSizeGB = 0
$totalSizeGB = 0
$orphanedSizeGB = 0
$orphanedCount = 0
$referencedCount = 0
$referencedSizeGB = 0
$patchCacheSizeGB = 0
$winsxsSizeGB = 0
$totalFiles = 0
$scanDurationSec = 0
$scanErrors = [System.Collections.Generic.List[string]]::new()

try {
    # --- Run orphan detection ---
    $results = Get-OrphanedInstallerFiles

    # InstallerFolderTotalBytes = unfiltered folder total (all file types, matches Explorer)
    # TotalSizeBytes = MSI/MSP-only subset (what orphan detection covers)
    $installerFolderSizeGB = [math]::Round($results.InstallerFolderTotalBytes / 1GB, 2)
    $totalSizeGB      = [math]::Round($results.TotalSizeBytes / 1GB, 2)
    $orphanedSizeGB   = [math]::Round($results.OrphanedSizeBytes / 1GB, 2)
    $orphanedCount    = $results.OrphanedCount
    $referencedCount  = $results.ReferencedCount
    $referencedSizeGB = [math]::Round($results.ReferencedSizeBytes / 1GB, 2)
    $patchCacheSizeGB = [math]::Round($results.PatchCacheSizeBytes / 1GB, 2)
    $totalFiles       = $results.TotalFiles
    $scanDurationSec  = $results.ScanDuration.TotalSeconds
    $scanErrors       = $results.Errors

    # --- Measure WinSxS size (secondary indicator) ---
    # NOTE: WinSxS uses hardlinks extensively — enumeration overcounts actual disk footprint
    # by 2-3x. This is a rough indicator only. Use DISM /AnalyzeComponentStore for precise sizing.
    # Uses .NET EnumerateFiles (lazy iterator) instead of Get-ChildItem -Recurse to avoid
    # blocking the script for 2-10+ minutes on HDD-backed or heavily-loaded servers.
    try {
        $winsxsSize = [long]0
        $winsxsPath = Join-Path $env:SystemRoot "WinSxS"
        foreach ($f in [System.IO.Directory]::EnumerateFiles($winsxsPath, "*", [System.IO.SearchOption]::AllDirectories)) {
            try { $winsxsSize += ([System.IO.FileInfo]::new($f)).Length } catch { }
        }
    } catch {
        # Preserve partial accumulation — $winsxsSize retains bytes counted before the
        # iterator error. The value is already documented as approximate (hardlink overcount).
        Write-Warning "WinSxS enumeration interrupted (partial result: $([math]::Round($winsxsSize/1GB,2)) GB): $($_.Exception.Message)"
    }
    $winsxsSizeGB = [math]::Round($winsxsSize / 1GB, 2)

    # --- Determine status based on total Installer folder size ---
    # Uses the unfiltered folder total (InstallerFolderTotalBytes) for threshold comparison
    # so status matches what operators see in Explorer
    if ($installerFolderSizeGB -ge $CriticalThresholdGB) {
        $status = "Critical"
    } elseif ($installerFolderSizeGB -ge $WarningThresholdGB) {
        $status = "Warning"
    } else {
        $status = "Healthy"
    }
} catch {
    $status = "Error"
    $scanErrors.Add("Critical scan failure: $($_.Exception.Message)")
    Write-Error "Scan failed: $($_.Exception.Message)"
}

# ============================================================================
# WRITE NINJARMM CUSTOM FIELDS
# ============================================================================
try {
    Ninja-Property-Set installerFolderSizeGB $installerFolderSizeGB
    Ninja-Property-Set installerOrphanedSizeGB $orphanedSizeGB
    Ninja-Property-Set installerOrphanedCount $orphanedCount
    Ninja-Property-Set installerWinSxSSizeGB $winsxsSizeGB
    Ninja-Property-Set installerStatus $status
    Ninja-Property-Set installerLastScan (Get-Date -Format "o")
} catch {
    # Ninja-Property-Set not available (running outside NinjaRMM) — log locally
    Write-Warning "NinjaRMM custom field write failed: $($_.Exception.Message)"
}

# ============================================================================
# WRITE WINDOWS EVENT LOG
# ============================================================================
$source = "DTC-InstallerMonitor"
$logName = "Application"
# SourceExists() throws SecurityException if caller lacks permission to enumerate sources —
# wrap in try/catch to prevent script termination
try {
    if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
        [System.Diagnostics.EventLog]::CreateEventSource($source, $logName)
    }
} catch {
    # SourceExists or CreateEventSource may fail without admin — continue anyway
    Write-Warning "Event source registration skipped: $($_.Exception.Message)"
}

# Distinct Event IDs per severity — intentionally separated so SIEM rules can
# target each level independently:
#   Healthy  = 1000 (Information)
#   Warning  = 2000 (Warning)
#   Critical = 2500 (Error)
#   Error    = 3000 (Error)
$eventId = switch ($status) {
    "Healthy"  { 1000 }
    "Warning"  { 2000 }
    "Critical" { 2500 }
    "Error"    { 3000 }
    default    { 3000 }
}
# Map EntryType to actual severity so SIEM/monitoring tools can filter
$entryType = switch ($status) {
    "Healthy"  { "Information" }
    "Warning"  { "Warning" }
    "Critical" { "Error" }
    "Error"    { "Error" }
    default    { "Error" }
}
$message = @"
DTC Installer Patch Monitor — Scan Complete
Status: $status
Installer Folder Total: $installerFolderSizeGB GB
MSI/MSP Files: $totalFiles ($totalSizeGB GB)
Orphaned Files: $orphanedCount ($orphanedSizeGB GB)
Referenced Files: $referencedCount ($referencedSizeGB GB)
PatchCache: $patchCacheSizeGB GB
WinSxS: $winsxsSizeGB GB (approximate — hardlink overcount)
Scan Duration: $scanDurationSec seconds
"@
if ($scanErrors.Count -gt 0) {
    $message += "`nErrors:`n" + ($scanErrors -join "`n")
}
try {
    Write-EventLog -LogName $logName -Source $source -EventId $eventId -EntryType $entryType -Message $message
} catch {
    Write-Warning "Event log write failed: $($_.Exception.Message)"
}

# ============================================================================
# CONSOLE SUMMARY (appears in NinjaRMM script log)
# ============================================================================
Write-Output "=== SCAN RESULTS ==="
Write-Output "Status:             $status"
Write-Output "Installer Folder:   $installerFolderSizeGB GB"
Write-Output "  MSI/MSP Files:    $totalSizeGB GB ($totalFiles files)"
Write-Output "    Referenced:     $referencedSizeGB GB ($referencedCount files)"
Write-Output "    Orphaned:       $orphanedSizeGB GB ($orphanedCount files)"
Write-Output "  PatchCache:       $patchCacheSizeGB GB"
Write-Output "WinSxS:             $winsxsSizeGB GB (approximate — hardlink overcount)"
Write-Output "Scan Duration:      $scanDurationSec seconds"
if ($scanErrors.Count -gt 0) {
    Write-Output ""
    Write-Output "Non-critical errors ($($scanErrors.Count)):"
    $scanErrors | ForEach-Object { Write-Output "  - $_" }
}
Write-Output "===================="
