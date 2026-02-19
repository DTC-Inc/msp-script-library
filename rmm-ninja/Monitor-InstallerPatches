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
        - TotalFiles (int)
        - TotalSizeBytes (long)
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
    $errors = @()

    # --- STEP 1: Build the "referenced files" set ---
    # The Windows Installer stores product/patch cache file references in the registry.
    # Products: HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\{GUID}\InstallProperties
    #   → "LocalPackage" value = path to cached .msi file
    # Patches: HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Patches\{GUID}
    #   → "LocalPackage" value = path to cached .msp file
    #
    # NOTE: Registry GUIDs are in "compressed" format (no dashes, no braces, character reordering).
    # However, the LocalPackage values contain standard file paths — we do NOT need to decompress
    # GUIDs. We just collect the LocalPackage values directly.

    $referencedFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    # Collect referenced MSI files from Products
    $productsPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products"
    try {
        if (Test-Path $productsPath) {
            $productGuids = Get-ChildItem $productsPath -ErrorAction Stop
            foreach ($product in $productGuids) {
                try {
                    $installProps = Join-Path $product.PSPath "InstallProperties"
                    if (Test-Path $installProps) {
                        $localPackage = (Get-ItemProperty $installProps -Name "LocalPackage" -ErrorAction SilentlyContinue).LocalPackage
                        if ($localPackage -and (Test-Path $localPackage)) {
                            [void]$referencedFiles.Add($localPackage)
                        }
                    }
                } catch {
                    $errors += "Product $($product.PSChildName): $($_.Exception.Message)"
                }
            }
        }
    } catch {
        # If we can't read the Products key at all, this is a critical failure
        throw "Failed to read Products registry path: $($_.Exception.Message)"
    }

    # Collect referenced MSP files from Patches
    $patchesPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Patches"
    try {
        if (Test-Path $patchesPath) {
            $patchGuids = Get-ChildItem $patchesPath -ErrorAction Stop
            foreach ($patch in $patchGuids) {
                try {
                    $localPackage = (Get-ItemProperty $patch.PSPath -Name "LocalPackage" -ErrorAction SilentlyContinue).LocalPackage
                    if ($localPackage -and (Test-Path $localPackage)) {
                        [void]$referencedFiles.Add($localPackage)
                    }
                } catch {
                    $errors += "Patch $($patch.PSChildName): $($_.Exception.Message)"
                }
            }
        }
    } catch {
        throw "Failed to read Patches registry path: $($_.Exception.Message)"
    }

    # --- STEP 2: Enumerate actual files in C:\Windows\Installer ---
    # Top-level only — do NOT include $PatchCache$ subfolder contents
    $installerPath = "C:\Windows\Installer"
    $allFiles = Get-ChildItem $installerPath -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.msi', '.msp' }

    # --- STEP 3: Compare and classify ---
    $referenced = @()
    $orphaned = @()

    foreach ($file in $allFiles) {
        if ($referencedFiles.Contains($file.FullName)) {
            $referenced += [PSCustomObject]@{
                FullPath  = $file.FullName
                SizeBytes = $file.Length
            }
        } else {
            $orphaned += [PSCustomObject]@{
                FullPath      = $file.FullName
                SizeBytes     = $file.Length
                LastWriteTime = $file.LastWriteTime
            }
        }
    }

    # --- STEP 4: Measure $PatchCache$ separately ---
    $patchCachePath = Join-Path $installerPath '$PatchCache$'
    $patchCacheSize = 0
    if (Test-Path $patchCachePath) {
        $patchCacheSize = (Get-ChildItem $patchCachePath -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum
    }

    # --- STEP 5: Return results ---
    [PSCustomObject]@{
        TotalFiles          = ($allFiles | Measure-Object).Count
        TotalSizeBytes      = ($allFiles | Measure-Object Length -Sum).Sum
        ReferencedFiles     = $referenced
        ReferencedCount     = $referenced.Count
        ReferencedSizeBytes = ($referenced | Measure-Object SizeBytes -Sum).Sum
        OrphanedFiles       = $orphaned
        OrphanedCount       = $orphaned.Count
        OrphanedSizeBytes   = ($orphaned | Measure-Object SizeBytes -Sum).Sum
        PatchCacheSizeBytes = $patchCacheSize
        ScanDuration        = (Get-Date) - $startTime
        Errors              = $errors
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
Write-Output "DTC Installer Patch Monitor — Starting scan..."
Write-Output "Timestamp: $(Get-Date -Format 'o')"
Write-Output ""

$status = "Healthy"
$totalSizeGB = 0
$orphanedSizeGB = 0
$orphanedCount = 0
$referencedCount = 0
$referencedSizeGB = 0
$patchCacheSizeGB = 0
$winsxsSizeGB = 0
$scanErrors = @()

try {
    # --- Run orphan detection ---
    $results = Get-OrphanedInstallerFiles

    $totalSizeGB     = [math]::Round($results.TotalSizeBytes / 1GB, 2)
    $orphanedSizeGB  = [math]::Round($results.OrphanedSizeBytes / 1GB, 2)
    $orphanedCount   = $results.OrphanedCount
    $referencedCount = $results.ReferencedCount
    $referencedSizeGB = [math]::Round($results.ReferencedSizeBytes / 1GB, 2)
    $patchCacheSizeGB = [math]::Round($results.PatchCacheSizeBytes / 1GB, 2)
    $scanErrors      = $results.Errors

    # --- Measure WinSxS size (secondary indicator) ---
    $winsxsSize = (Get-ChildItem "C:\Windows\WinSxS" -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    $winsxsSizeGB = [math]::Round($winsxsSize / 1GB, 2)

    # --- Determine status based on total Installer folder size ---
    if ($totalSizeGB -gt $CriticalThresholdGB) {
        $status = "Critical"
    } elseif ($totalSizeGB -gt $WarningThresholdGB) {
        $status = "Warning"
    } else {
        $status = "Healthy"
    }
} catch {
    $status = "Error"
    $scanErrors += "Critical scan failure: $($_.Exception.Message)"
    Write-Error "Scan failed: $($_.Exception.Message)"
}

# ============================================================================
# WRITE NINJARMM CUSTOM FIELDS
# ============================================================================
try {
    Ninja-Property-Set installerFolderSizeGB ([math]::Round($totalSizeGB, 2))
    Ninja-Property-Set installerOrphanedSizeGB ([math]::Round($orphanedSizeGB, 2))
    Ninja-Property-Set installerOrphanedCount $orphanedCount
    Ninja-Property-Set installerWinSxSSizeGB ([math]::Round($winsxsSizeGB, 2))
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
if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
    try {
        [System.Diagnostics.EventLog]::CreateEventSource($source, $logName)
    } catch {
        # May fail without admin — continue anyway
    }
}

$eventId = switch ($status) {
    "Healthy"  { 1000 }
    "Warning"  { 2000 }
    "Critical" { 2000 }
    "Error"    { 3000 }
}
$message = @"
DTC Installer Patch Monitor — Scan Complete
Status: $status
Total Installer Folder: $totalSizeGB GB
Orphaned Files: $orphanedCount ($orphanedSizeGB GB)
Referenced Files: $referencedCount ($referencedSizeGB GB)
PatchCache: $patchCacheSizeGB GB
WinSxS: $winsxsSizeGB GB
Scan Duration: $($results.ScanDuration.TotalSeconds) seconds
"@
if ($scanErrors.Count -gt 0) {
    $message += "`nErrors:`n" + ($scanErrors -join "`n")
}
try {
    Write-EventLog -LogName $logName -Source $source -EventId $eventId -EntryType Information -Message $message
} catch {
    Write-Warning "Event log write failed: $($_.Exception.Message)"
}

# ============================================================================
# CONSOLE SUMMARY (appears in NinjaRMM script log)
# ============================================================================
Write-Output "=== SCAN RESULTS ==="
Write-Output "Status:             $status"
Write-Output "Installer Folder:   $totalSizeGB GB ($($results.TotalFiles) files)"
Write-Output "  Referenced:       $referencedSizeGB GB ($referencedCount files)"
Write-Output "  Orphaned:         $orphanedSizeGB GB ($orphanedCount files)"
Write-Output "  PatchCache:       $patchCacheSizeGB GB"
Write-Output "WinSxS:             $winsxsSizeGB GB"
Write-Output "Scan Duration:      $($results.ScanDuration.TotalSeconds) seconds"
if ($scanErrors.Count -gt 0) {
    Write-Output ""
    Write-Output "Non-critical errors ($($scanErrors.Count)):"
    $scanErrors | ForEach-Object { Write-Output "  - $_" }
}
Write-Output "===================="
