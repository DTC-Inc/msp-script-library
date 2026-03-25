#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    Audits an existing Hyper-V host for server lifecycle quote validation.

.DESCRIPTION
    Gathers comprehensive Hyper-V host information during VM migration scenarios.
    Designed to run on the EXISTING host when migrating VMs to a new host.

    Collects:
    - Host OS, hardware, CPU, and memory details
    - Disk layout and storage controller inventory
    - VM inventory with memory and processor allocation
    - VHDX paths, sizes, and types
    - VM checkpoints (snapshots)
    - Virtual switch configuration
    - Physical network adapters and VMQ status

    Output is logged via Start-Transcript for QA evidence retention.

    Reference: Server Lifecycle - Quote Validation Audit SOP (BookStack Page 1787)

.PARAMETER LogPath
    Directory for the transcript log file.
    Default: $env:SystemRoot\Logs\HyperVAudit

.EXAMPLE
    .\Invoke-HyperVHostAudit.ps1
    Run a full host audit with default log path.

.EXAMPLE
    .\Invoke-HyperVHostAudit.ps1 -LogPath "C:\AuditLogs"
    Run audit with a custom log output directory.

.NOTES
    Version:        1.1.0
    Author:         AlrightLad
    Requirements:   PowerShell 5.1+, Administrator rights, Hyper-V role installed
#>

[CmdletBinding()]
param(
    [string]$LogPath = "$env:SystemRoot\Logs\HyperVAudit"
)

# ── Logging ──────────────────────────────────────────────────────────────────
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$hostname  = $env:COMPUTERNAME
$logFile   = Join-Path $LogPath "HyperVAudit-${hostname}-${timestamp}.log"
Start-Transcript -Path $logFile -Append

# ── Helper ───────────────────────────────────────────────────────────────────
function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "===== $Title =====" -ForegroundColor Cyan
}

# ── Host OS & Hardware ───────────────────────────────────────────────────────
Write-Section "HOST OS & HARDWARE"
Get-CimInstance Win32_OperatingSystem |
    Select-Object CSName, Caption, Version | Format-List
Get-CimInstance Win32_ComputerSystem |
    Select-Object Manufacturer, Model, TotalPhysicalMemory, NumberOfProcessors | Format-List
Get-CimInstance Win32_Processor |
    Select-Object Name, NumberOfCores, NumberOfLogicalProcessors | Format-List

# ── Disk Layout ──────────────────────────────────────────────────────────────
Write-Section "DISK LAYOUT"
Get-CimInstance Win32_LogicalDisk |
    Select-Object Name, Size, FreeSpace | Format-Table -AutoSize

# ── Storage Controllers ──────────────────────────────────────────────────────
Write-Section "STORAGE CONTROLLERS"
Get-CimInstance Win32_SCSIController |
    Select-Object Name, Manufacturer, DeviceID | Format-Table -AutoSize

# ── Cache VM list once to avoid repeated calls and cross-section drift ───────
$allVMs = Get-VM

# ── VM Inventory ─────────────────────────────────────────────────────────────
Write-Section "VM INVENTORY"
$allVMs | Select-Object Name, State, Generation,
    @{N = 'MemoryAssignedGB';  E = { [math]::Round($_.MemoryAssigned / 1GB, 1) }},
    @{N = 'MemoryStartupGB';   E = { [math]::Round($_.MemoryStartup  / 1GB, 1) }},
    ProcessorCount, DynamicMemoryEnabled |
    Format-Table -AutoSize

# ── VHDX Paths & Sizes ──────────────────────────────────────────────────────
Write-Section "VHDX PATHS & SIZES"
$allVMs | Get-VMHardDiskDrive | ForEach-Object {
    try {
        $vhd = Get-VHD -Path $_.Path -ErrorAction Stop
        [PSCustomObject]@{
            VMName    = $_.VMName
            Path      = $_.Path
            MaxSizeGB = [math]::Round($vhd.Size     / 1GB, 1)
            UsedGB    = [math]::Round($vhd.FileSize  / 1GB, 1)
            Type      = $vhd.VhdType
        }
    }
    catch {
        Write-Warning "Failed to read VHD '$($_.Path)' for VM '$($_.VMName)': $_"
        [PSCustomObject]@{
            VMName    = $_.VMName
            Path      = $_.Path
            MaxSizeGB = 'ERROR'
            UsedGB    = 'ERROR'
            Type      = 'N/A'
        }
    }
} | Format-Table -AutoSize

# ── VM Checkpoints ───────────────────────────────────────────────────────────
Write-Section "VM CHECKPOINTS"
try {
    $snaps = $allVMs | Get-VMSnapshot -ErrorAction Stop
    if ($snaps) {
        $snaps | Select-Object VMName, Name, CreationTime | Format-Table -AutoSize
    }
    else {
        Write-Host "No checkpoints found."
    }
}
catch [Microsoft.HyperV.PowerShell.VirtualizationException] {
    Write-Host "No checkpoints found."
}
catch {
    Write-Warning "Failed to query checkpoints: $_"
}

# ── Virtual Switches ────────────────────────────────────────────────────────
Write-Section "VIRTUAL SWITCHES"
Get-VMSwitch |
    Select-Object Name, SwitchType, NetAdapterInterfaceDescription | Format-Table -AutoSize

# ── Network Adapters ────────────────────────────────────────────────────────
Write-Section "NETWORK ADAPTERS"
Get-NetAdapter |
    Select-Object Name, InterfaceDescription, Status, LinkSpeed | Format-Table -AutoSize

# ── VMQ Status ──────────────────────────────────────────────────────────────
Write-Section "VMQ STATUS"
try {
    Get-NetAdapterVmq -ErrorAction Stop |
        Select-Object Name, InterfaceDescription, Enabled | Format-Table -AutoSize
}
catch {
    Write-Warning "VMQ data unavailable: $_"
}

# ── Done ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "===== HOST AUDIT COMPLETE =====" -ForegroundColor Green
Write-Host "Transcript saved to: $logFile"

Stop-Transcript
