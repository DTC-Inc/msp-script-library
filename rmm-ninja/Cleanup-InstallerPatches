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
$DismTimeoutMinutes     = 60    # Max minutes to wait for DISM before continuing

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
                            if ($localPackage -and (Test-Path $localPackage)) {
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
                        if ($localPackage -and (Test-Path $localPackage)) {
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
Write-Output "DTC Installer Patch Cleanup — Starting..."
Write-Output "Timestamp: $(Get-Date -Format 'o')"
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

# Print mode AFTER auto-Force decision so the log reflects the actual execution mode
Write-Output "Mode: $(if ($WhatIf) {'WhatIf (dry run)'} elseif ($Force) {'Force (direct delete)'} else {'Quarantine'})"

# Record baseline
$installerBasePath = Join-Path $env:SystemRoot "Installer"
$baselineSize = (Get-ChildItem $installerBasePath -Recurse -Force -ErrorAction SilentlyContinue |
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
        Write-Output "[PHASE 1] Running DISM Component Cleanup (timeout: $DismTimeoutMinutes min)..."
        # Do NOT use /ResetBase — prevents future update uninstalls, too destructive for automation.
        # Run as background job with timeout — synchronous DISM can take 30-90+ minutes on
        # heavily-loaded systems, which may exceed the NinjaRMM execution window.
        $dismJob = Start-Job -ScriptBlock {
            $output = & DISM /Online /Cleanup-Image /StartComponentCleanup 2>&1
            [PSCustomObject]@{ Output = $output; ExitCode = $LASTEXITCODE }
        }
        $completed = $dismJob | Wait-Job -Timeout ($DismTimeoutMinutes * 60)
        if ($completed) {
            try {
                $dismData = $dismJob | Receive-Job
                $dismData.Output | ForEach-Object { Write-Output "[DISM] $_" }
                if ($dismData.ExitCode -ne 0) {
                    Write-Warning "[PHASE 1] DISM exited with code $($dismData.ExitCode) — component cleanup may be incomplete."
                }
            } catch {
                Write-Warning "[PHASE 1] DISM job failed: $($_.Exception.Message)"
            }
        } else {
            $dismJob | Stop-Job
            Write-Warning "[PHASE 1] DISM timed out after $DismTimeoutMinutes minutes — component cleanup may be incomplete. Continuing with remaining phases."
        }
        $dismJob | Remove-Job -Force
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
Write-Output "  MSI/MSP files: $($results.TotalFiles) ($([math]::Round($results.TotalSizeBytes / 1GB, 2)) GB)"
Write-Output "  Referenced:    $($results.ReferencedCount) ($([math]::Round($results.ReferencedSizeBytes / 1GB, 2)) GB)"
Write-Output "  Orphaned:      $($results.OrphanedCount) ($([math]::Round($results.OrphanedSizeBytes / 1GB, 2)) GB)"
Write-Output ""

# Include time in quarantine folder name to prevent same-day collision (Move-Item -Force
# would silently overwrite a previously quarantined file with the same name)
$quarantinePath = "C:\DTC\InstallerCleanup\Quarantine\$(Get-Date -Format 'yyyy-MM-dd_HHmmss')"
$logPath = "C:\DTC\InstallerCleanup\Logs"
$logFile = Join-Path $logPath "cleanup_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').log"

# Create directories — abort on failure so we don't silently lose files
if (-not $WhatIf) {
    try {
        New-Item -Path $logPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "Failed to create log directory '$logPath': $($_.Exception.Message) — ABORTING cleanup."
        try { Ninja-Property-Set installerStatus "Error" } catch {}
        exit 1
    }
    if (-not $Force) {
        try {
            New-Item -Path $quarantinePath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        } catch {
            Write-Error "Failed to create quarantine directory '$quarantinePath': $($_.Exception.Message) — ABORTING cleanup."
            try { Ninja-Property-Set installerStatus "Error" } catch {}
            exit 1
        }
    }
}

# Track two separate metrics:
# - $installerFolderFreedBytes: bytes removed from C:\Windows\Installer (Move or Delete — what shrinks the folder)
# - $diskSpaceRecoveredBytes: bytes actually freed from disk (Delete only — quarantine stays on same volume)
$installerFolderFreedBytes = [long]0
$diskSpaceRecoveredBytes   = [long]0

foreach ($file in $results.OrphanedFiles) {
    $logEntry = "[$(Get-Date -Format 'o')] [PHASE2]"

    if ($WhatIf) {
        $logEntry += " [WOULD REMOVE] $($file.FullPath) ($([math]::Round($file.SizeBytes/1MB,1)) MB)"
        Write-Output $logEntry
    }
    elseif ($Force) {
        try {
            Remove-Item $file.FullPath -Force -ErrorAction Stop
            $installerFolderFreedBytes += $file.SizeBytes
            $diskSpaceRecoveredBytes   += $file.SizeBytes
            $logEntry += " [DELETED] $($file.FullPath) ($($file.SizeBytes) bytes) [OK]"
        } catch {
            $logEntry += " [DELETE-FAILED] $($file.FullPath) ($($file.SizeBytes) bytes) [$($_.Exception.Message)]"
        }
        Write-Output $logEntry
    }
    else {
        try {
            Move-Item $file.FullPath $quarantinePath -Force -ErrorAction Stop
            $installerFolderFreedBytes += $file.SizeBytes
            # NOTE: quarantine moves files on the same volume — no disk space is freed until quarantine expires
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
$patchCachePath = Join-Path $installerBasePath "`$PatchCache`$"
if (Test-Path $patchCachePath) {
    $patchCacheSize = (Get-ChildItem $patchCachePath -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum -as [long]
    if (-not $patchCacheSize) { $patchCacheSize = [long]0 }
    $patchCacheSizeGB = [math]::Round($patchCacheSize / 1GB, 2)

    if ($patchCacheSizeGB -ge $PatchCacheThresholdGB) {
        if ($WhatIf) {
            Write-Output "[WHATIF] [PHASE3] Would delete $patchCacheSizeGB GB from `$PatchCache`$"
        } else {
            Write-Output "[PHASE 3] Cleaning `$PatchCache`$ ($patchCacheSizeGB GB)..."
            # Delete contents, not the folder itself. Some files may be locked by msiexec.
            Get-ChildItem $patchCachePath -Recurse -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            # Re-measure after deletion to compute actual recovery (locked files may remain)
            $postCacheSize = (Get-ChildItem $patchCachePath -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum).Sum -as [long]
            if (-not $postCacheSize) { $postCacheSize = [long]0 }
            $actualCacheRecovered = $patchCacheSize - $postCacheSize
            $installerFolderFreedBytes += $actualCacheRecovered
            $diskSpaceRecoveredBytes   += $actualCacheRecovered
            "[$(Get-Date -Format 'o')] [PHASE3] [DELETED] `$PatchCache`$ contents ($actualCacheRecovered of $patchCacheSize bytes)" |
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
    # Parse creation timestamp from folder name (yyyy-MM-dd_HHmmss) instead of relying on
    # filesystem CreationTime, which resets on copy/restore and is unreliable for expiration.
    # Unknown-format folders are skipped — never deleted without a parseable timestamp.
    $expiredFolders = Get-ChildItem $quarantineRoot -Directory | Where-Object {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($_.Name, 'yyyy-MM-dd_HHmmss',
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            $parsed -lt $cutoffDate
        } else {
            $false
        }
    }

    if ($expiredFolders) {
        Write-Output "[PHASE 4] Purging expired quarantine folders (older than $QuarantineDays days)..."
        foreach ($folder in $expiredFolders) {
            if ($WhatIf) {
                Write-Output "[WHATIF] [PHASE4] Would purge expired quarantine: $($folder.Name)"
            } else {
                $folderSize = (Get-ChildItem $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum -as [long]
                if (-not $folderSize) { $folderSize = [long]0 }
                Remove-Item $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue
                # Verify deletion before counting recovery — partial failures are possible
                if (-not (Test-Path $folder.FullName)) {
                    $diskSpaceRecoveredBytes += $folderSize
                } else {
                    $remainingSize = (Get-ChildItem $folder.FullName -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum -as [long]
                    if (-not $remainingSize) { $remainingSize = [long]0 }
                    $diskSpaceRecoveredBytes += ($folderSize - $remainingSize)
                }
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
$installerFolderFreedGB  = [math]::Round($installerFolderFreedBytes / 1GB, 2)
$diskSpaceRecoveredGB   = [math]::Round($diskSpaceRecoveredBytes / 1GB, 2)

if (-not $WhatIf) {
    # Update NinjaRMM custom fields — cleanup-specific
    # Report actual disk space recovered (only actual deletions, not quarantine moves)
    try {
        Ninja-Property-Set installerLastCleanup (Get-Date -Format "o")
        Ninja-Property-Set installerCleanupRecoveredGB $diskSpaceRecoveredGB
    } catch {
        Write-Warning "NinjaRMM cleanup field write failed: $($_.Exception.Message)"
    }

    # Re-run monitor logic to update current state
    # Use InstallerFolderTotalBytes (unfiltered) for threshold so status matches Explorer
    try {
        $postResults = Get-OrphanedInstallerFiles
        $postFolderGB = [math]::Round($postResults.InstallerFolderTotalBytes / 1GB, 2)
        $postOrphanedGB = [math]::Round($postResults.OrphanedSizeBytes / 1GB, 2)
        $postStatus = if ($postFolderGB -ge $CriticalThresholdGB) { "Critical" }
                      elseif ($postFolderGB -ge $WarningThresholdGB) { "Warning" }
                      else { "Healthy" }

        try {
            Ninja-Property-Set installerFolderSizeGB $postFolderGB
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
Installer Folder Freed: $installerFolderFreedGB GB
Disk Space Recovered: $diskSpaceRecoveredGB GB
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
Write-Output "Installer folder freed: $installerFolderFreedGB GB"
if (-not $Force -and -not $WhatIf) {
    Write-Output "  (files quarantined to C:\DTC — disk space freed when quarantine expires in $QuarantineDays days)"
}
Write-Output "Disk space recovered: $diskSpaceRecoveredGB GB"
if (-not $WhatIf) {
    Write-Output "Log file: $logFile"
}
Write-Output "======================"
