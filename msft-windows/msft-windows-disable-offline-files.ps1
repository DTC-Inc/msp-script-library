## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $RMM

### ————— MSP RMM VARIABLE INITIALIZATION GOES HERE —————
# Example for NinjaRMM:
# $RMM = 1
#
# Example for ConnectWise Automate:
# $RMM = 1
#
# Example for Datto RMM:
# $RMM = 1
### ————— END RMM VARIABLE INITIALIZATION —————

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-disable-offline-files.log"

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
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"

<#
.SYNOPSIS
    Disables Windows Offline Files (Client-Side Caching) completely.

.DESCRIPTION
    This script completely disables the Windows Offline Files feature by:
    - Stopping and disabling the Offline Files service (CSC)
    - Setting registry keys to disable Offline Files system-wide
    - Clearing the Offline Files cache
    - Marking the cache database for deletion on next boot

    CRITICAL: A system reboot is REQUIRED for changes to take full effect.

.NOTES
    Author: Nathaniel Smith / Claude Code
    Requires: Administrator privileges
    WARNING: Changes require a reboot to complete. The script will NOT reboot automatically.
#>

### ————— SAFETY CHECK: REQUIRE ADMINISTRATOR —————
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Error "This script must be run as Administrator."
    Stop-Transcript
    exit 1
}

### ————— CHECK CURRENT STATUS —————
Write-Output "`n=========================================="
Write-Output "OFFLINE FILES - CURRENT STATUS"
Write-Output "==========================================`n"

# Check if CSC service exists
$cscService = Get-Service -Name "CSC" -ErrorAction SilentlyContinue

if ($null -eq $cscService) {
    Write-Output "Offline Files service (CSC) not found on this system."
    Write-Output "This feature may not be installed or available on this Windows version."
    Stop-Transcript
    exit 0
}

Write-Output "CSC Service Status:"
Write-Output "  Status: $($cscService.Status)"
Write-Output "  Startup Type: $($cscService.StartType)"

# Check registry status
$netCacheKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\NetCache"
$cscParamsKey = "HKLM:\SYSTEM\CurrentControlSet\Services\CSC\Parameters"

try {
    if (Test-Path $netCacheKey) {
        $enabledValue = Get-ItemProperty -Path $netCacheKey -Name "Enabled" -ErrorAction SilentlyContinue
        if ($null -ne $enabledValue) {
            $isEnabled = $enabledValue.Enabled
            Write-Output "`nRegistry Configuration:"
            Write-Output "  Offline Files Enabled: $($isEnabled -eq 1)"
        }
    }
} catch {
    Write-Output "`nRegistry Configuration: Unable to read current status"
}

# Check cache location
$cacheRoot = "$env:SystemRoot\CSC"
if (Test-Path $cacheRoot) {
    try {
        $cacheSize = (Get-ChildItem -Path $cacheRoot -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $cacheSizeMB = [math]::Round($cacheSize / 1MB, 2)
        Write-Output "`nCache Information:"
        Write-Output "  Cache Location: $cacheRoot"
        Write-Output "  Cache Size: $cacheSizeMB MB"
    } catch {
        Write-Output "`nCache Information:"
        Write-Output "  Cache Location: $cacheRoot"
        Write-Output "  Cache Size: Unable to calculate (may be in use)"
    }
} else {
    Write-Output "`nCache Information:"
    Write-Output "  Cache Location: Not found or empty"
}

### ————— DISABLE OFFLINE FILES —————
Write-Output "`n=========================================="
Write-Output "DISABLING OFFLINE FILES"
Write-Output "==========================================`n"

$operationSuccess = $true
$changesApplied = @()

# STEP 1: Stop CSC Service
Write-Output "Step 1: Stopping Offline Files service..."
try {
    if ($cscService.Status -eq "Running") {
        Stop-Service -Name "CSC" -Force -ErrorAction Stop
        Write-Output "  Status: Service stopped successfully"
        $changesApplied += "Stopped CSC service"
    } else {
        Write-Output "  Status: Service already stopped"
    }
} catch {
    Write-Warning "  Status: Failed to stop service - $($_.Exception.Message)"
    Write-Warning "  The service may have active connections. Will continue with other steps."
}

# STEP 2: Disable CSC Service
Write-Output "`nStep 2: Disabling Offline Files service..."
try {
    Set-Service -Name "CSC" -StartupType Disabled -ErrorAction Stop
    Write-Output "  Status: Service disabled successfully"
    $changesApplied += "Disabled CSC service"
} catch {
    Write-Error "  Status: Failed to disable service - $($_.Exception.Message)"
    $operationSuccess = $false
}

# STEP 3: Set registry to disable Offline Files
Write-Output "`nStep 3: Configuring registry to disable Offline Files..."

# Create NetCache key if it doesn't exist
if (-not (Test-Path $netCacheKey)) {
    try {
        New-Item -Path $netCacheKey -Force -ErrorAction Stop | Out-Null
        Write-Output "  Created registry key: $netCacheKey"
    } catch {
        Write-Error "  Failed to create registry key: $_"
        $operationSuccess = $false
    }
}

# Set Enabled = 0 to disable Offline Files
try {
    Set-ItemProperty -Path $netCacheKey -Name "Enabled" -Value 0 -Type DWord -ErrorAction Stop
    Write-Output "  Status: Offline Files disabled in registry"
    $changesApplied += "Disabled Offline Files in registry"
} catch {
    Write-Error "  Status: Failed to set registry value - $($_.Exception.Message)"
    $operationSuccess = $false
}

# STEP 4: Mark cache database for deletion
Write-Output "`nStep 4: Marking cache database for deletion on next boot..."

# Create CSC Parameters key if it doesn't exist
if (-not (Test-Path $cscParamsKey)) {
    try {
        New-Item -Path $cscParamsKey -Force -ErrorAction Stop | Out-Null
        Write-Output "  Created registry key: $cscParamsKey"
    } catch {
        Write-Error "  Failed to create CSC Parameters key: $_"
        $operationSuccess = $false
    }
}

# Set FormatDatabase = 1 to delete cache on next boot
try {
    Set-ItemProperty -Path $cscParamsKey -Name "FormatDatabase" -Value 1 -Type DWord -ErrorAction Stop
    Write-Output "  Status: Cache database will be deleted on next reboot"
    $changesApplied += "Scheduled cache database deletion"
} catch {
    Write-Error "  Status: Failed to set FormatDatabase flag - $($_.Exception.Message)"
    $operationSuccess = $false
}

# STEP 5: Attempt to clear cache (optional, may fail if files are in use)
Write-Output "`nStep 5: Attempting to clear cache directory..."
if (Test-Path $cacheRoot) {
    try {
        # Try to remove cache contents (may fail for locked files)
        Get-ChildItem -Path $cacheRoot -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        Write-Output "  Status: Cache contents cleared (partial or complete)"
        Write-Output "  Note: Some files may remain if they are in use. They will be removed after reboot."
        $changesApplied += "Cleared cache directory"
    } catch {
        Write-Warning "  Status: Unable to clear cache - files may be in use"
        Write-Output "  Note: Cache will be cleared automatically after reboot"
    }
} else {
    Write-Output "  Status: Cache directory not found (already clear)"
}

### ————— FINAL SUMMARY —————
Write-Output "`n=========================================="
Write-Output "OPERATION SUMMARY"
Write-Output "==========================================`n"

if ($operationSuccess) {
    Write-Output "Offline Files has been disabled successfully.`n"

    Write-Output "Changes Applied:"
    foreach ($change in $changesApplied) {
        Write-Output "  ✓ $change"
    }

    Write-Output "`n=========================================="
    Write-Output "⚠️  REBOOT REQUIRED"
    Write-Output "==========================================`n"
    Write-Output "CRITICAL: A system reboot is REQUIRED for changes to take full effect."
    Write-Output ""
    Write-Output "After reboot, the following will be complete:"
    Write-Output "  • Offline Files service will remain disabled"
    Write-Output "  • Offline Files cache will be deleted"
    Write-Output "  • All sync connections will be terminated"
    Write-Output "  • No cached files will remain on the system"
    Write-Output ""
    Write-Output "INSTRUCTIONS:"
    Write-Output "  1. Close all open network files and mapped drives"
    Write-Output "  2. Reboot the system at your earliest convenience"
    Write-Output "  3. Verify service status after reboot (should remain Disabled)"
    Write-Output ""

    ### ————— TUNNEL OUTPUT VARIABLE TO YOUR RMM HERE —————
    # Example for NinjaRMM:
    # if (Get-Command 'Ninja-Property-Set' -ErrorAction SilentlyContinue) {
    #     Ninja-Property-Set -Name 'offlineFilesStatus' -Value "Disabled - Reboot Required"
    # }
    ### ————— END RMM OUTPUT TUNNEL —————

} else {
    Write-Error "`nOperation completed with errors. Some changes may not have been applied."
    Write-Error "Review the log file for details: $LogPath"
    Write-Error ""
    Write-Error "Manual steps may be required:"
    Write-Error "  1. Open Services (services.msc)"
    Write-Error "  2. Find 'Offline Files' service"
    Write-Error "  3. Set Startup Type to 'Disabled'"
    Write-Error "  4. Stop the service if running"
    Write-Error "  5. Reboot the system"

    Stop-Transcript
    exit 1
}

Stop-Transcript
