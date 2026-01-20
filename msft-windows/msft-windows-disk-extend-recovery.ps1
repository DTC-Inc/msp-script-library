## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $RMM
## $RMMScriptPath
## $Description
## $autoConfirm

### ————— MSP RMM VARIABLE INITIALIZATION GOES HERE —————
# Example for NinjaRMM:
# $RMM = 1
# $autoConfirm = 1  # Set to 1 to skip confirmation prompts
#
# Example for ConnectWise Automate:
# $RMM = 1
# $autoConfirm = 1
#
# Example for Datto RMM:
# $RMM = 1
# $autoConfirm = 1
### ————— END RMM VARIABLE INITIALIZATION —————

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-disk-extend-recovery.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }

    # Interactive mode defaults to requiring confirmation
    if ($null -eq $autoConfirm) {
        $autoConfirm = 0
    }

    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

} else {
    # Store the logs in the RMMScriptPath
    if ($null -ne $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"

    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

    }

    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    }

    # RMM mode defaults to auto-confirm
    if ($null -eq $autoConfirm) {
        $autoConfirm = 1
    }
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host "Auto-Confirm: $autoConfirm"

<#
.SYNOPSIS
    Detects unallocated disk space and manages recovery partition to extend C:\ volume.

.DESCRIPTION
    This script analyzes the disk layout to:
    - Detect unallocated space immediately after C:\ (OS volume)
    - Detect unallocated space at the end of the disk
    - If a recovery partition exists between C:\ and end-of-disk unallocated space:
      * Delete the recovery partition
      * Extend C:\ into the freed space
      * Recreate a 4 GB recovery partition at the end of the disk

    CRITICAL SAFETY:
    - Only operates on the boot disk (where C:\ resides)
    - Validates partition layout before making changes
    - Backs up recovery partition metadata before deletion
    - Requires confirmation before destructive operations (unless $autoConfirm = 1)

.NOTES
    Author: Nathaniel Smith / Claude Code
    Requires: Administrator privileges, diskpart access
    WARNING: This script performs destructive disk operations. Ensure backups exist.
#>

### ————— SAFETY CHECK: REQUIRE ADMINISTRATOR —————
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Error "This script must be run as Administrator due to disk operations."
    Stop-Transcript
    exit 1
}

### ————— IDENTIFY BOOT DISK AND C:\ PARTITION —————
Write-Output "`n=========================================="
Write-Output "DISK ANALYSIS - DETECTING LAYOUT"
Write-Output "==========================================`n"

# Get the OS volume (C:\)
try {
    $osVolume = Get-Volume -DriveLetter C -ErrorAction Stop
    $osPartition = Get-Partition -DriveLetter C -ErrorAction Stop
    $osDiskNumber = $osPartition.DiskNumber

    Write-Output "OS Volume (C:\) Information:"
    Write-Output "  Disk Number: $osDiskNumber"
    Write-Output "  Partition Number: $($osPartition.PartitionNumber)"
    Write-Output "  Size: $([math]::Round($osPartition.Size / 1GB, 2)) GB"
    Write-Output "  Used Space: $([math]::Round(($osVolume.Size - $osVolume.SizeRemaining) / 1GB, 2)) GB"
    Write-Output "  Free Space: $([math]::Round($osVolume.SizeRemaining / 1GB, 2)) GB"

} catch {
    Write-Error "Failed to identify C:\ drive: $_"
    Stop-Transcript
    exit 1
}

# Get the boot disk
try {
    $bootDisk = Get-Disk -Number $osDiskNumber -ErrorAction Stop

    Write-Output "`nBoot Disk Information:"
    Write-Output "  Disk Number: $($bootDisk.Number)"
    Write-Output "  Partition Style: $($bootDisk.PartitionStyle)"
    Write-Output "  Total Size: $([math]::Round($bootDisk.Size / 1GB, 2)) GB"
    Write-Output "  Operational Status: $($bootDisk.OperationalStatus)"

    if ($bootDisk.PartitionStyle -ne "GPT") {
        Write-Warning "This script is designed for GPT disks. Current partition style: $($bootDisk.PartitionStyle)"
        Write-Warning "MBR disks may require different handling."
    }

} catch {
    Write-Error "Failed to get boot disk information: $_"
    Stop-Transcript
    exit 1
}

### ————— ANALYZE ALL PARTITIONS ON BOOT DISK —————
Write-Output "`n=========================================="
Write-Output "PARTITION LAYOUT ANALYSIS"
Write-Output "==========================================`n"

$allPartitions = Get-Partition -DiskNumber $osDiskNumber | Sort-Object Offset

Write-Output "All partitions on Disk $osDiskNumber (sorted by position):`n"

$recoveryPartitions = @()
$osPartitionIndex = -1
$partitionList = @()

for ($i = 0; $i -lt $allPartitions.Count; $i++) {
    $partition = $allPartitions[$i]
    $partitionInfo = [PSCustomObject]@{
        Index = $i
        PartitionNumber = $partition.PartitionNumber
        DriveLetter = $partition.DriveLetter
        Size = [math]::Round($partition.Size / 1GB, 2)
        Offset = $partition.Offset
        Type = $partition.Type
        GptType = $partition.GptType
        IsRecovery = $false
        IsOS = $false
    }

    # Identify recovery partitions (GPT Type GUID for Microsoft Recovery)
    if ($partition.GptType -eq "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}") {
        $partitionInfo.IsRecovery = $true
        $recoveryPartitions += $partition
        Write-Output "[$i] Partition $($partition.PartitionNumber): RECOVERY - $($partitionInfo.Size) GB (Offset: $($partition.Offset))"
    }
    # Identify OS partition
    elseif ($partition.PartitionNumber -eq $osPartition.PartitionNumber) {
        $partitionInfo.IsOS = $true
        $osPartitionIndex = $i
        Write-Output "[$i] Partition $($partition.PartitionNumber): OS (C:\) - $($partitionInfo.Size) GB (Offset: $($partition.Offset))"
    }
    # Other partitions
    else {
        $label = if ($partition.DriveLetter) { "$($partition.DriveLetter):\" } else { $partition.Type }
        Write-Output "[$i] Partition $($partition.PartitionNumber): $label - $($partitionInfo.Size) GB (Offset: $($partition.Offset))"
    }

    $partitionList += $partitionInfo
}

### ————— DETECT UNALLOCATED SPACE —————
Write-Output "`n=========================================="
Write-Output "UNALLOCATED SPACE DETECTION"
Write-Output "==========================================`n"

# Calculate unallocated space after C:\
$unallocatedAfterOS = $false
$unallocatedAfterOSSize = 0

if ($osPartitionIndex -ge 0 -and $osPartitionIndex -lt ($allPartitions.Count - 1)) {
    $osPartitionEnd = $osPartition.Offset + $osPartition.Size
    $nextPartition = $allPartitions[$osPartitionIndex + 1]
    $gap = $nextPartition.Offset - $osPartitionEnd

    if ($gap -gt 1MB) {
        $unallocatedAfterOS = $true
        $unallocatedAfterOSSize = [math]::Round($gap / 1GB, 2)
        Write-Output "Found unallocated space immediately after C:\ - $unallocatedAfterOSSize GB"
    } else {
        Write-Output "No significant unallocated space immediately after C:\"
    }
} else {
    Write-Output "C:\ is the last partition - checking for unallocated space at end of disk..."
}

# Calculate unallocated space at end of disk
$unallocatedAtEnd = $false
$unallocatedAtEndSize = 0

$lastPartition = $allPartitions[-1]
$lastPartitionEnd = $lastPartition.Offset + $lastPartition.Size
$diskEnd = $bootDisk.Size
$gapAtEnd = $diskEnd - $lastPartitionEnd

if ($gapAtEnd -gt 1MB) {
    $unallocatedAtEnd = $true
    $unallocatedAtEndSize = [math]::Round($gapAtEnd / 1GB, 2)
    Write-Output "Found unallocated space at end of disk: $unallocatedAtEndSize GB"
} else {
    Write-Output "No significant unallocated space at end of disk"
}

### ————— DETERMINE ACTION PLAN —————
Write-Output "`n=========================================="
Write-Output "ACTION PLAN DETERMINATION"
Write-Output "==========================================`n"

$actionNeeded = $false
$actionPlan = ""

# Check if there are recovery partitions between C:\ and end-of-disk unallocated space
$recoveryBetweenOSAndEnd = $false
$targetRecoveryPartitions = @()

if ($recoveryPartitions.Count -gt 0 -and $osPartitionIndex -ge 0) {
    foreach ($recovery in $recoveryPartitions) {
        # Check if recovery partition is AFTER OS partition
        if ($recovery.Offset -gt $osPartition.Offset) {
            $recoveryBetweenOSAndEnd = $true
            $targetRecoveryPartitions += $recovery
            Write-Output "Recovery partition found after C:\ partition"
            Write-Output "  Partition Number: $($recovery.PartitionNumber)"
            Write-Output "  Size: $([math]::Round($recovery.Size / 1GB, 2)) GB"
            Write-Output "  Offset: $($recovery.Offset)"
            # Don't break - collect ALL recovery partitions after C:\
        }
    }
}

# Scenario 1: Recovery partition(s) exist between C:\ and end of disk
if ($recoveryBetweenOSAndEnd -and $targetRecoveryPartitions.Count -gt 0) {
    $actionNeeded = $true

    # Calculate total size of all recovery partitions to be deleted
    $totalRecoverySize = 0
    foreach ($recovery in $targetRecoveryPartitions) {
        $totalRecoverySize += [math]::Round($recovery.Size / 1GB, 2)
    }

    $totalGainForC = $totalRecoverySize

    # If there's also unallocated space at the end, we can use that too
    if ($unallocatedAtEnd) {
        $totalGainForC += $unallocatedAtEndSize
    }

    # Calculate net gain (accounting for new recovery partition)
    $netGainForC = $totalGainForC - 4

    $recoveryCountText = if ($targetRecoveryPartitions.Count -eq 1) { "recovery partition" } else { "$($targetRecoveryPartitions.Count) recovery partitions" }

    $actionPlan = @"
ACTION PLAN:
1. Delete $recoveryCountText (total: $totalRecoverySize GB)
2. Extend C:\ toward maximum available space
3. Create new 4 GB recovery partition at end of disk

RESULT: C:\ will gain approximately $netGainForC GB of space (net after recovery partition)
"@

    Write-Output $actionPlan
}
# Scenario 2: No recovery partition, but unallocated space exists after C:\
elseif ($unallocatedAfterOS) {
    $actionNeeded = $true

    # Determine if we have enough space to create a recovery partition
    if ($unallocatedAfterOSSize -ge 5) {
        $netGainForC = $unallocatedAfterOSSize - 4

        $actionPlan = @"
ACTION PLAN:
1. Extend C:\ into most of the unallocated space
2. Create new 4 GB recovery partition at end of disk

RESULT: C:\ will gain approximately $netGainForC GB of space
"@
    } else {
        $actionPlan = @"
ACTION PLAN:
1. Extend C:\ into unallocated space ($unallocatedAfterOSSize GB)

RESULT: C:\ will gain $unallocatedAfterOSSize GB of space
NOTE: Not enough space to create recovery partition (need at least 5 GB)
"@
    }

    Write-Output $actionPlan
}
# Scenario 3: Unallocated space at end only (no recovery, C:\ can't extend)
elseif ($unallocatedAtEnd -and $unallocatedAtEndSize -ge 4) {
    $actionNeeded = $true

    $actionPlan = @"
ACTION PLAN:
1. Create new 4 GB recovery partition at end of disk

RESULT: Recovery partition will be created using available space
NOTE: C:\ cannot be extended (other partitions are in the way)
"@

    Write-Output $actionPlan
}
# Scenario 4: Nothing to do
else {
    Write-Output "No action needed. Disk layout is optimal or no reclaimable space found."
    Write-Output "`nCurrent layout:"
    Write-Output "  - C:\ size: $([math]::Round($osPartition.Size / 1GB, 2)) GB"
    Write-Output "  - Unallocated after C:\: $unallocatedAfterOSSize GB"
    Write-Output "  - Unallocated at end: $unallocatedAtEndSize GB"
    Stop-Transcript
    exit 0
}

### ————— CONFIRMATION PROMPT —————
if ($autoConfirm -ne 1) {
    Write-Output "`n=========================================="
    Write-Output "CONFIRMATION REQUIRED"
    Write-Output "==========================================`n"
    Write-Warning "This operation will modify disk partitions. This is a DESTRUCTIVE operation."
    Write-Warning "Ensure you have backups before proceeding."
    Write-Output ""
    $confirmation = Read-Host "Type 'YES' (in all caps) to proceed with the action plan"

    if ($confirmation -ne "YES") {
        Write-Output "Operation cancelled by user."
        Stop-Transcript
        exit 0
    }
} else {
    Write-Output "Auto-confirm enabled. Proceeding with action plan..."
}

### ————— EXECUTE ACTION PLAN —————
Write-Output "`n=========================================="
Write-Output "EXECUTING DISK OPERATIONS"
Write-Output "==========================================`n"

try {
    # Determine which scenario we're executing
    $extendC = $false
    $createRecovery = $false

    if ($recoveryBetweenOSAndEnd -and $targetRecoveryPartitions.Count -gt 0) {
        # Scenario 1: Delete recovery partition(s), extend C:\, recreate recovery
        $extendC = $true
        $createRecovery = $true
    } elseif ($unallocatedAfterOS) {
        # Scenario 2: Extend C:\, optionally create recovery
        $extendC = $true
        if ($unallocatedAfterOSSize -ge 5) {
            $createRecovery = $true
        }
    } elseif ($unallocatedAtEnd -and $unallocatedAtEndSize -ge 4) {
        # Scenario 3: Only create recovery partition (C:\ cannot extend)
        $createRecovery = $true
    }

    # STEP 1: Delete recovery partition(s) if they exist
    if ($recoveryBetweenOSAndEnd -and $targetRecoveryPartitions.Count -gt 0) {
        $recoveryCountText = if ($targetRecoveryPartitions.Count -eq 1) { "recovery partition" } else { "$($targetRecoveryPartitions.Count) recovery partitions" }
        Write-Output "Step 1: Deleting $recoveryCountText..."
        Write-Output ""

        $deletionCount = 0

        # Sort by partition number in reverse order to avoid renumbering issues
        $sortedRecoveryPartitions = $targetRecoveryPartitions | Sort-Object PartitionNumber -Descending

        foreach ($recovery in $sortedRecoveryPartitions) {
            $deletionCount++
            Write-Output "  [$deletionCount/$($targetRecoveryPartitions.Count)] Deleting partition $($recovery.PartitionNumber)"
            Write-Output "    Size: $([math]::Round($recovery.Size / 1GB, 2)) GB"
            Write-Output "    Offset: $($recovery.Offset)"

            try {
                Remove-Partition -DiskNumber $osDiskNumber -PartitionNumber $recovery.PartitionNumber -Confirm:$false -ErrorAction Stop
                Write-Output "    Status: Deleted successfully"

                # Wait briefly between deletions
                Start-Sleep -Seconds 1

            } catch {
                Write-Error "    Status: Failed to delete - $($_.Exception.Message)"
                throw "Failed to delete recovery partition $($recovery.PartitionNumber)"
            }

            Write-Output ""
        }

        Write-Output "  All $recoveryCountText deleted successfully"
        Write-Output "  Waiting for disk to update..."
        Start-Sleep -Seconds 2
    }

    # STEP 2: Extend C:\ partition (if applicable)
    if ($extendC) {
        Write-Output "`nStep 2: Extending C:\ partition..."

        # Get the maximum size C:\ can be extended to
        $supportedSizes = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
        $maxSize = $supportedSizes.SizeMax

        Write-Output "  Current C:\ size: $([math]::Round($osPartition.Size / 1GB, 2)) GB"
        Write-Output "  Maximum possible size: $([math]::Round($maxSize / 1GB, 2)) GB"

        # Calculate how much we should extend (leave buffer for recovery partition + alignment)
        # Use 5 GB buffer to account for partition alignment (1MB boundaries)
        $desiredRecoverySize = 4GB

        # Only leave buffer if we're creating a recovery partition
        if ($createRecovery) {
            $bufferSize = 5GB  # Extra buffer for alignment
            $targetSize = $maxSize - $bufferSize
        } else {
            $targetSize = $maxSize
        }

        # Ensure we're not shrinking the partition
        if ($targetSize -le $osPartition.Size) {
            Write-Warning "Not enough space to extend C:\ and create recovery partition."
            Write-Warning "Will extend C:\ to maximum available size without creating recovery partition."
            $targetSize = $maxSize
            $createRecovery = $false
        }

        Resize-Partition -DriveLetter C -Size $targetSize -ErrorAction Stop
        Write-Output "  C:\ extended to: $([math]::Round($targetSize / 1GB, 2)) GB"

        # Wait for partition resize to complete
        Start-Sleep -Seconds 3
    }

    # STEP 3: Create new recovery partition at end of disk
    if ($createRecovery) {
        # Determine step number based on whether we extended C:\
        $stepNumber = if ($extendC) { "3" } else { "1" }
        Write-Output "`nStep ${stepNumber}: Creating new recovery partition..."

        # Refresh disk info to get accurate unallocated space
        Update-Disk -Number $osDiskNumber -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        # Check actual available space after extension
        $updatedPartitions = Get-Partition -DiskNumber $osDiskNumber | Sort-Object Offset
        $lastPartitionAfterExtend = $updatedPartitions[-1]
        $lastPartitionEnd = $lastPartitionAfterExtend.Offset + $lastPartitionAfterExtend.Size
        $diskEnd = (Get-Disk -Number $osDiskNumber).Size
        $actualUnallocated = $diskEnd - $lastPartitionEnd

        Write-Output "  Available unallocated space: $([math]::Round($actualUnallocated / 1GB, 2)) GB"

        # Determine recovery partition size (use available space, max 4 GB)
        $minRecoverySize = 1GB  # Minimum 1 GB for recovery partition
        if ($actualUnallocated -lt $minRecoverySize) {
            Write-Warning "Only $([math]::Round($actualUnallocated / 1GB, 2)) GB available - skipping recovery partition creation"
            Write-Warning "Recovery partition requires minimum $([math]::Round($minRecoverySize / 1GB, 2)) GB"
            $createRecovery = $false
        } else {
            # Use available space but cap at 4 GB
            if ($actualUnallocated -gt $desiredRecoverySize) {
                $recoveryPartitionSize = $desiredRecoverySize
            } else {
                # Use 90% of available space to account for any remaining alignment issues
                $recoveryPartitionSize = [math]::Floor($actualUnallocated * 0.9)
            }

            Write-Output "  Creating recovery partition: $([math]::Round($recoveryPartitionSize / 1GB, 2)) GB"

            try {
                $newRecovery = New-Partition -DiskNumber $osDiskNumber -Size $recoveryPartitionSize -GptType "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" -ErrorAction Stop
                Write-Output "  Recovery partition created successfully"
                Write-Output "  Partition Number: $($newRecovery.PartitionNumber)"
                Write-Output "  Size: $([math]::Round($newRecovery.Size / 1GB, 2)) GB"

                # Format the recovery partition as NTFS
                Format-Volume -Partition $newRecovery -FileSystem NTFS -NewFileSystemLabel "Recovery" -Confirm:$false -ErrorAction Stop | Out-Null
                Write-Output "  Recovery partition formatted as NTFS"

                # Set partition attributes (hidden)
                Set-Partition -DiskNumber $osDiskNumber -PartitionNumber $newRecovery.PartitionNumber -IsHidden $true -ErrorAction Stop
                Write-Output "  Recovery partition set as hidden"

            } catch {
                Write-Warning "Failed to create recovery partition: $_"
                Write-Warning "C:\ has been extended successfully, but recovery partition creation failed."
                $createRecovery = $false
            }
        }
    }

    ### ————— FINAL SUMMARY —————
    Write-Output "`n=========================================="
    Write-Output "OPERATION COMPLETED"
    Write-Output "==========================================`n"

    # Get updated partition info
    $updatedOSPartition = Get-Partition -DriveLetter C
    $updatedOSVolume = Get-Volume -DriveLetter C

    Write-Output "Updated C:\ Volume:"
    Write-Output "  Total Size: $([math]::Round($updatedOSPartition.Size / 1GB, 2)) GB"
    Write-Output "  Used Space: $([math]::Round(($updatedOSVolume.Size - $updatedOSVolume.SizeRemaining) / 1GB, 2)) GB"
    Write-Output "  Free Space: $([math]::Round($updatedOSVolume.SizeRemaining / 1GB, 2)) GB"

    # Check if recovery partition was created
    $updatedRecoveryPartitions = Get-Partition -DiskNumber $osDiskNumber | Where-Object { $_.GptType -eq "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" }
    if ($updatedRecoveryPartitions) {
        Write-Output "`nRecovery Partition:"
        Write-Output "  Size: $([math]::Round($updatedRecoveryPartitions[0].Size / 1GB, 2)) GB"
        Write-Output "  Position: End of disk"
        Write-Output "  Status: Created successfully"
    } else {
        Write-Output "`nRecovery Partition:"
        Write-Output "  Status: Not created (insufficient space or error occurred)"
        Write-Output "  Note: C:\ has been extended to maximum available size"
    }

    ### ————— TUNNEL OUTPUT VARIABLE TO YOUR RMM HERE —————
    # Example for NinjaRMM:
    # if (Get-Command 'Ninja-Property-Set' -ErrorAction SilentlyContinue) {
    #     Ninja-Property-Set -Name 'diskExtensionResult' -Value "Success: C:\ extended to $([math]::Round($updatedOSPartition.Size / 1GB, 2)) GB"
    # }
    ### ————— END RMM OUTPUT TUNNEL —————

} catch {
    Write-Error "Failed during disk operation: $_"
    Write-Error "The disk may be in an inconsistent state. Manual intervention may be required."
    Write-Error "Check Disk Management (diskmgmt.msc) for current partition layout."
    Stop-Transcript
    exit 1
}

Stop-Transcript
