<#
.SYNOPSIS
    DTC Installer Patch Cleanup — On-demand removal of orphaned .msi/.msp files
    from C:\Windows\Installer with safety quarantine.
.DESCRIPTION
    Detects and removes orphaned installer cache files from C:\Windows\Installer.
    Supports quarantine mode (default), direct deletion (-Force), and dry-run (-WhatIf).
    Includes DISM component cleanup, $PatchCache$ cleanup, and quarantine expiry management.

    Safety: If orphan detection fails for ANY reason, the entire cleanup is aborted.

    Deployment: NinjaRMM on-demand script (tech triggers manually) or condition-triggered.
    Runs as: SYSTEM

    Reference: HALO Ticket 1125653 — 128 GB orphaned patches, 96.1% disk utilization.
.PARAMETER WhatIf
    Report what WOULD be cleaned — make ZERO filesystem changes.
.PARAMETER SkipDISM
    Skip the DISM component cleanup phase.
.PARAMETER Force
    Delete orphaned files directly instead of quarantining. Auto-enabled when disk < 10% free.
.PARAMETER QuarantineDays
    Number of days to keep quarantined files before auto-purge. Default: 30.
.NOTES
    Author:  DTC Engineering
    Version: 1.0.0
    Requires: PowerShell 5.1, Windows 10/11/Server 2019/2022
    Dependencies: None (self-contained)
#>

#Requires -Version 5.1

param(
    [switch]$WhatIf,
    [switch]$SkipDISM,
    [switch]$Force,
    [ValidateRange(1, 365)]
    [int]$QuarantineDays = 30
)

# ============================================================================
# CONFIGURATION — Adjust thresholds here
# ============================================================================
$WarningThresholdGB     = 20    # Total Installer folder size >= this = "Warning"
$CriticalThresholdGB    = 50    # Total Installer folder size >= this = "Critical"
$AutoForceThresholdPct  = 10    # Free disk % below which Force mode auto-enables
$PatchCacheThresholdGB  = 1     # $PatchCache$ size above which cleanup is triggered

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
    $patchCacheSize = [long]0
    if (Test-Path $patchCachePath) {
        $patchCacheSize = (Get-ChildItem $patchCachePath -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum -as [long]
        if (-not $patchCacheSize) { $patchCacheSize = [long]0 }
    }

    # --- STEP 5: Return results ---
    # Null-coerce all Measure-Object .Sum results — .Sum returns $null on empty collections
    [PSCustomObject]@{
        TotalFiles          = ($allFiles | Measure-Object).Count -as [int]
        TotalSizeBytes      = ($allFiles | Measure-Object Length -Sum).Sum -as [long]
        ReferencedFiles     = $referenced
        ReferencedCount     = $referenced.Count
        ReferencedSizeBytes = ($referenced | Measure-Object SizeBytes -Sum).Sum -as [long]
        OrphanedFiles       = $orphaned
        OrphanedCount       = $orphaned.Count
        OrphanedSizeBytes   = ($orphaned | Measure-Object SizeBytes -Sum).Sum -as [long]
        PatchCacheSizeBytes = $patchCacheSize
        ScanDuration        = (Get-Date) - $startTime
        Errors              = $errors
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
Write-Output "DTC Installer Patch Cleanup — Starting..."
Write-Output "Timestamp: $(Get-Date -Format 'o')"
Write-Output "Mode: $(if ($WhatIf) {'WhatIf (dry run)'} elseif ($Force) {'Force (direct delete)'} else {'Quarantine'})"
Write-Output ""

# ============================================================================
# PHASE 0: Pre-flight checks
# ============================================================================
Write-Output "[PHASE 0] Pre-flight checks..."

$cDrive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'"
if (-not $cDrive) {
    Write-Warning "Could not query C: drive info via CIM — skipping free-space check / auto-Force logic."
    $freePercent = 100
    $freeSizeGB  = -1
} else {
    $freePercent = [math]::Round(($cDrive.FreeSpace / $cDrive.Size) * 100, 1)
    $freeSizeGB  = [math]::Round($cDrive.FreeSpace / 1GB, 2)
}

Write-Output "  C: drive free space: $freeSizeGB GB ($freePercent%)"

# If disk is critically full and -Force not explicitly set, auto-enable Force mode
if ($freePercent -lt $AutoForceThresholdPct -and -not $Force) {
    Write-Warning "Disk is $freePercent% free — auto-enabling direct deletion mode (quarantine would consume additional space)"
    $Force = $true
}

# Record baseline
$baselineSize = (Get-ChildItem "C:\Windows\Installer" -Recurse -Force -ErrorAction SilentlyContinue |
    Measure-Object Length -Sum).Sum -as [long]
if (-not $baselineSize) { $baselineSize = [long]0 }
$baselineSizeGB = [math]::Round($baselineSize / 1GB, 2)
Write-Output "  Installer folder baseline: $baselineSizeGB GB"
Write-Output ""

# ============================================================================
# PHASE 1: DISM Component Cleanup
# ============================================================================
if (-not $SkipDISM) {
    if ($WhatIf) {
        Write-Output "[WHATIF] Would run: DISM /Online /Cleanup-Image /StartComponentCleanup"
        Write-Output ""
    } else {
        Write-Output "[PHASE 1] Running DISM Component Cleanup..."
        # Do NOT use /ResetBase — prevents future update uninstalls, too destructive for automation
        $dismResult = & DISM /Online /Cleanup-Image /StartComponentCleanup 2>&1
        $dismResult | ForEach-Object { Write-Output "[DISM] $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "[PHASE 1] DISM exited with code $LASTEXITCODE — component cleanup may be incomplete."
        }
        Write-Output ""
    }
} else {
    Write-Output "[PHASE 1] DISM cleanup skipped (-SkipDISM)."
    Write-Output ""
}

# ============================================================================
# PHASE 2: Orphaned Installer Cleanup
# ============================================================================
Write-Output "[PHASE 2] Running orphan detection..."
try {
    $results = Get-OrphanedInstallerFiles
} catch {
    # CRITICAL: If orphan detection fails, ABORT ENTIRE CLEANUP
    Write-Error "Orphan detection failed — ABORTING cleanup. Error: $($_.Exception.Message)"
    try { Ninja-Property-Set installerStatus "Error" } catch {}
    exit 1
}

Write-Output "  Scan complete in $($results.ScanDuration.TotalSeconds) seconds"
Write-Output "  Total files: $($results.TotalFiles) ($([math]::Round($results.TotalSizeBytes / 1GB, 2)) GB)"
Write-Output "  Referenced:  $($results.ReferencedCount) ($([math]::Round($results.ReferencedSizeBytes / 1GB, 2)) GB)"
Write-Output "  Orphaned:    $($results.OrphanedCount) ($([math]::Round($results.OrphanedSizeBytes / 1GB, 2)) GB)"
Write-Output ""

# Include time in quarantine folder name to prevent same-day collision (Move-Item -Force
# would silently overwrite a previously quarantined file with the same name)
$quarantinePath = "C:\DTC\InstallerCleanup\Quarantine\$(Get-Date -Format 'yyyy-MM-dd_HHmmss')"
$logPath = "C:\DTC\InstallerCleanup\Logs"
$logFile = Join-Path $logPath "cleanup_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"

# Create directories
if (-not $WhatIf) {
    New-Item -Path $logPath -ItemType Directory -Force | Out-Null
    if (-not $Force) {
        New-Item -Path $quarantinePath -ItemType Directory -Force | Out-Null
    }
}

$totalRecoveredBytes = 0

foreach ($file in $results.OrphanedFiles) {
    $logEntry = "[$(Get-Date -Format 'o')] [PHASE2]"

    if ($WhatIf) {
        $logEntry += " [WOULD REMOVE] $($file.FullPath) ($([math]::Round($file.SizeBytes/1MB,1)) MB)"
        Write-Output $logEntry
    }
    elseif ($Force) {
        try {
            Remove-Item $file.FullPath -Force -ErrorAction Stop
            $totalRecoveredBytes += $file.SizeBytes
            $logEntry += " [DELETED] $($file.FullPath) ($($file.SizeBytes) bytes) [OK]"
        } catch {
            $logEntry += " [DELETE-FAILED] $($file.FullPath) ($($file.SizeBytes) bytes) [$($_.Exception.Message)]"
        }
        Write-Output $logEntry
    }
    else {
        try {
            Move-Item $file.FullPath $quarantinePath -Force -ErrorAction Stop
            $totalRecoveredBytes += $file.SizeBytes
            $logEntry += " [QUARANTINED] $($file.FullPath) ($($file.SizeBytes) bytes) [OK]"
        } catch {
            $logEntry += " [QUARANTINE-FAILED] $($file.FullPath) ($($file.SizeBytes) bytes) [$($_.Exception.Message)]"
        }
        Write-Output $logEntry
    }

    # Append to log file
    if (-not $WhatIf) {
        $logEntry | Out-File -FilePath $logFile -Append -Encoding UTF8
    }
}

Write-Output ""

# ============================================================================
# PHASE 3: $PatchCache$ Cleanup
# ============================================================================
$patchCachePath = "C:\Windows\Installer\`$PatchCache`$"
if (Test-Path $patchCachePath) {
    $patchCacheSize = (Get-ChildItem $patchCachePath -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum -as [long]
    if (-not $patchCacheSize) { $patchCacheSize = [long]0 }
    $patchCacheSizeGB = [math]::Round($patchCacheSize / 1GB, 2)

    if ($patchCacheSizeGB -gt $PatchCacheThresholdGB) {
        if ($WhatIf) {
            Write-Output "[WHATIF] [PHASE3] Would delete $patchCacheSizeGB GB from `$PatchCache`$"
        } else {
            Write-Output "[PHASE 3] Cleaning `$PatchCache`$ ($patchCacheSizeGB GB)..."
            # Delete contents, not the folder itself
            Get-ChildItem $patchCachePath -Recurse -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            $totalRecoveredBytes += $patchCacheSize
            "[$(Get-Date -Format 'o')] [PHASE3] [DELETED] `$PatchCache`$ contents ($patchCacheSize bytes)" |
                Out-File -FilePath $logFile -Append -Encoding UTF8
        }
    } else {
        Write-Output "[PHASE 3] `$PatchCache`$ is $patchCacheSizeGB GB (below $PatchCacheThresholdGB GB threshold) — skipping."
    }
} else {
    Write-Output "[PHASE 3] `$PatchCache`$ folder not found — skipping."
}

Write-Output ""

# ============================================================================
# PHASE 4: Quarantine Maintenance
# ============================================================================
$quarantineRoot = "C:\DTC\InstallerCleanup\Quarantine"
if (Test-Path $quarantineRoot) {
    $cutoffDate = (Get-Date).AddDays(-$QuarantineDays)
    $expiredFolders = Get-ChildItem $quarantineRoot -Directory |
        Where-Object { $_.CreationTime -lt $cutoffDate }

    if ($expiredFolders) {
        Write-Output "[PHASE 4] Purging expired quarantine folders (older than $QuarantineDays days)..."
        foreach ($folder in $expiredFolders) {
            if ($WhatIf) {
                Write-Output "[WHATIF] [PHASE4] Would purge expired quarantine: $($folder.Name)"
            } else {
                $folderSize = (Get-ChildItem $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum -as [long]
                if (-not $folderSize) { $folderSize = [long]0 }
                Remove-Item $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
                Write-Output "[PHASE 4] Purged expired quarantine: $($folder.Name) ($([math]::Round($folderSize/1MB,1)) MB)"
                "[$(Get-Date -Format 'o')] [PHASE4] [PURGED] $($folder.FullName) ($folderSize bytes)" |
                    Out-File -FilePath $logFile -Append -Encoding UTF8
            }
        }
    } else {
        Write-Output "[PHASE 4] No expired quarantine folders found."
    }
} else {
    Write-Output "[PHASE 4] No quarantine folder exists — skipping."
}

Write-Output ""

# ============================================================================
# PHASE 5: Report
# ============================================================================
$totalRecoveredGB = [math]::Round($totalRecoveredBytes / 1GB, 2)

if (-not $WhatIf) {
    # Update NinjaRMM custom fields — cleanup-specific
    try {
        Ninja-Property-Set installerLastCleanup (Get-Date -Format "o")
        Ninja-Property-Set installerCleanupRecoveredGB $totalRecoveredGB
    } catch {
        Write-Warning "NinjaRMM cleanup field write failed: $($_.Exception.Message)"
    }

    # Re-run monitor logic to update current state
    try {
        $postResults = Get-OrphanedInstallerFiles
        $postTotalGB = [math]::Round($postResults.TotalSizeBytes / 1GB, 2)
        $postOrphanedGB = [math]::Round($postResults.OrphanedSizeBytes / 1GB, 2)
        $postStatus = if ($postTotalGB -ge $CriticalThresholdGB) { "Critical" }
                      elseif ($postTotalGB -ge $WarningThresholdGB) { "Warning" }
                      else { "Healthy" }

        try {
            Ninja-Property-Set installerFolderSizeGB $postTotalGB
            Ninja-Property-Set installerOrphanedSizeGB $postOrphanedGB
            Ninja-Property-Set installerOrphanedCount $postResults.OrphanedCount
            Ninja-Property-Set installerStatus $postStatus
            Ninja-Property-Set installerLastScan (Get-Date -Format "o")
        } catch {
            Write-Warning "NinjaRMM post-scan field write failed: $($_.Exception.Message)"
        }
    } catch {
        Write-Warning "Post-cleanup scan failed: $($_.Exception.Message)"
    }

    # Write Event Log
    $source = "DTC-InstallerMonitor"
    $logName = "Application"
    # SourceExists() throws SecurityException if caller lacks permission to enumerate sources
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
            [System.Diagnostics.EventLog]::CreateEventSource($source, $logName)
        }
    } catch {
        Write-Warning "Event source registration skipped: $($_.Exception.Message)"
    }

    # Inside if (-not $WhatIf) block, so mode is only Direct Delete or Quarantine
    $eventMessage = @"
DTC Installer Patch Cleanup — Complete
Mode: $(if ($Force) {"Direct Delete"} else {"Quarantine"})
Total Recovered: $totalRecoveredGB GB
Orphaned Files Processed: $($results.OrphanedCount)
"@
    try {
        Write-EventLog -LogName $logName -Source $source -EventId 1001 -EntryType Information -Message $eventMessage
    } catch {
        Write-Warning "Event log write failed: $($_.Exception.Message)"
    }
}

# Console summary
Write-Output "=== CLEANUP SUMMARY ==="
Write-Output "Mode: $(if ($WhatIf) {'WhatIf (no changes made)'} elseif ($Force) {'Direct Delete'} else {'Quarantine'})"
Write-Output "Orphaned files found: $($results.OrphanedCount)"
Write-Output "Space recovered: $totalRecoveredGB GB"
if (-not $WhatIf) {
    Write-Output "Log file: $logFile"
}
Write-Output "======================"
