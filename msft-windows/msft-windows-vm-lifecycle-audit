#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Server Lifecycle Audit - Collects detailed system information for replacement planning.

.DESCRIPTION
    Comprehensive Windows Server/VM lifecycle audit script that collects:
    - OS, hostname, and domain role details
    - AD FSMO roles (if Domain Controller)
    - CPU, memory, and disk layout metrics
    - Physical disk controllers
    - Installed server roles
    - SQL Server instances
    - Filtered software inventory (excludes updates/hotfixes/runtimes)
    - Running services (non-Microsoft, auto-start)
    - File shares and shared printers
    - Network configuration and DNS settings
    - DHCP scopes (if DHCP server installed)
    - RDS licensing configuration
    - Scheduled tasks (non-Microsoft)
    - Hyper-V virtual machines (if installed)

    Reference: Server Lifecycle - Quote Validation Audit SOP (BookStack Page 1787)

.PARAMETER RMMScriptPath
    Custom log directory when executed from an RMM platform.

.EXAMPLE
    .\Invoke-ServerLifecycleAudit.ps1
    Run interactively — prompts for ticket # / initials.

.EXAMPLE
    # Via NinjaOne with RMM variables set:
    #   $RMM = 1
    #   $Description = "TICKET-1234 NS"
    .\Invoke-ServerLifecycleAudit.ps1

.NOTES
    Version:  1.0.0
    Author:   AlrightLad
    Requires: PowerShell 5.1+, Administrator privileges
#>

# ============================================================================
# 1) RMM VARIABLE DECLARATION
# ============================================================================
# When running from NinjaOne (or another RMM), set these script variables:
#   $RMM            = 1          (indicates RMM execution context)
#   $Description    = "TICKET-1234 NS"  (ticket # and/or initials)
#   $RMMScriptPath  = "C:\CustomLogPath" (optional custom log directory)

$ScriptLogName = "ServerLifecycleAudit.log"

# ============================================================================
# 2) INPUT HANDLING
# ============================================================================
if ($RMM -ne 1) {
    $ValidInput = 0
    while ($ValidInput -ne 1) {
        $Description = Read-Host "Please enter the ticket # and/or your initials (used as the Description for the job)"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
} else {
    if ($null -ne $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
    }

    if ($null -eq $Description -or $Description -eq '') {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    }
}

# ============================================================================
# 3) SCRIPT LOGIC
# ============================================================================
Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host ""

# --- Hostname & OS ---
Write-Host "===== HOSTNAME & OS =====" -ForegroundColor Cyan
Get-CimInstance Win32_OperatingSystem |
    Select-Object CSName, Caption, Version, InstallDate |
    Format-List

# --- Domain Role ---
Write-Host "===== DOMAIN ROLE =====" -ForegroundColor Cyan
Get-CimInstance Win32_ComputerSystem |
    Select-Object Name, Domain, DomainRole, PartOfDomain |
    Format-List

# --- AD FSMO Roles ---
Write-Host "===== AD FSMO ROLES (if DC) =====" -ForegroundColor Cyan
if (Get-Command netdom -ErrorAction SilentlyContinue) {
    $fsmoOutput = & netdom query fsmo 2>&1
    if ($LASTEXITCODE -eq 0) {
        $fsmoOutput
    } else {
        Write-Host "Not a DC or netdom query failed (exit code: $LASTEXITCODE)"
    }
} else {
    Write-Host "netdom not available on this system"
}

# --- CPU ---
Write-Host "`n===== CPU =====" -ForegroundColor Cyan
Get-CimInstance Win32_Processor |
    Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed |
    Format-List

# --- Memory ---
Write-Host "===== MEMORY =====" -ForegroundColor Cyan
$os = Get-CimInstance Win32_OperatingSystem
[PSCustomObject]@{
    TotalGB     = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    FreeGB      = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    UsedGB      = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
    CommittedGB = [math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB, 1)
} | Format-List

# --- Disk Layout ---
Write-Host "===== DISK LAYOUT =====" -ForegroundColor Cyan
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
    Select-Object DeviceID,
        @{N = 'SizeGB'; E = { [math]::Round($_.Size / 1GB, 1) }},
        @{N = 'FreeGB'; E = { [math]::Round($_.FreeSpace / 1GB, 1) }},
        @{N = 'UsedGB'; E = { [math]::Round(($_.Size - $_.FreeSpace) / 1GB, 1) }} |
    Format-Table -AutoSize

# --- Physical Disk Controller ---
Write-Host "===== PHYSICAL DISK CONTROLLER =====" -ForegroundColor Cyan
Get-CimInstance Win32_SCSIController |
    Select-Object Name, DriverName |
    Format-Table -AutoSize

# --- Server Roles ---
Write-Host "===== SERVER ROLES =====" -ForegroundColor Cyan
if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
    Get-WindowsFeature |
        Where-Object { $_.Installed -eq $true -and $_.FeatureType -eq 'Role' } |
        Select-Object Name, DisplayName |
        Format-Table -AutoSize
} else {
    Write-Host "Get-WindowsFeature not available (not a Windows Server OS or RSAT not installed)"
}

# --- SQL Server Instances ---
Write-Host "===== SQL SERVER INSTANCES =====" -ForegroundColor Cyan
$sqlServices = Get-Service | Where-Object { $_.Name -match '^MSSQL' -or $_.Name -match '^SQL' }
if ($sqlServices) {
    $sqlServices | Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize
} else {
    Write-Host "No SQL Server services detected"
}

# --- Installed Software (filtered) ---
Write-Host "===== INSTALLED SOFTWARE (filtered) =====" -ForegroundColor Cyan
$regPaths = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and $_.DisplayName -notmatch 'Update|Hotfix|KB\d|Visual C\+\+|\.NET' } |
    Select-Object DisplayName, DisplayVersion, Publisher |
    Sort-Object DisplayName |
    Format-Table -AutoSize

# --- Running Services (non-Microsoft, Auto-start) ---
Write-Host "===== RUNNING SERVICES (non-Microsoft, Auto-start) =====" -ForegroundColor Cyan
Get-CimInstance Win32_Service |
    Where-Object { $_.StartMode -eq 'Auto' -and $_.PathName -notmatch 'Windows|Microsoft|svchost' } |
    Select-Object Name, DisplayName, State, PathName |
    Format-Table -AutoSize

# --- File Shares ---
Write-Host "===== FILE SHARES =====" -ForegroundColor Cyan
if (Get-Command Get-SmbShare -ErrorAction SilentlyContinue) {
    Get-SmbShare |
        Where-Object { $_.Name -notmatch '^\$|^ADMIN\$|^IPC\$|^print\$' } |
        Select-Object Name, Path, Description |
        Format-Table -AutoSize
} else {
    Write-Host "Get-SmbShare not available"
}

# --- Shared Printers ---
Write-Host "===== SHARED PRINTERS =====" -ForegroundColor Cyan
$sharedPrinters = Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Shared -eq $true }
if ($sharedPrinters) {
    $sharedPrinters | Select-Object Name, DriverName, PortName, Shared | Format-Table -AutoSize
} else {
    Write-Host "No shared printers found"
}

# --- Network Config ---
Write-Host "===== NETWORK CONFIG =====" -ForegroundColor Cyan
Get-NetAdapter |
    Select-Object Name, InterfaceDescription, Status, LinkSpeed |
    Format-Table -AutoSize
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notmatch '^127' } |
    Select-Object InterfaceAlias, IPAddress, PrefixLength |
    Format-Table -AutoSize

# --- DNS Server Settings ---
Write-Host "===== DNS SERVER SETTINGS (if DC) =====" -ForegroundColor Cyan
if (Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue) {
    $dnsZones = Get-DnsServerZone -ErrorAction SilentlyContinue
    if ($dnsZones) {
        $dnsZones | Select-Object ZoneName, ZoneType, IsReverseLookupZone | Format-Table -AutoSize
    } else {
        Write-Host "DNS Server role not installed or no zones configured"
    }
} else {
    Write-Host "DNS Server cmdlets not available"
}

# --- DHCP Scopes ---
Write-Host "===== DHCP SCOPES (if DHCP server) =====" -ForegroundColor Cyan
if (Get-Command Get-DhcpServerv4Scope -ErrorAction SilentlyContinue) {
    $dhcpScopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
    if ($dhcpScopes) {
        $dhcpScopes | Select-Object ScopeId, Name, StartRange, EndRange, SubnetMask, State | Format-Table -AutoSize
    } else {
        Write-Host "DHCP Server role not installed or no scopes configured"
    }
} else {
    Write-Host "DHCP Server cmdlets not available"
}

# --- RDS Licensing ---
Write-Host "===== RDS LICENSING =====" -ForegroundColor Cyan
if (Get-Command Get-RDLicenseConfiguration -ErrorAction SilentlyContinue) {
    $rdsConfig = Get-RDLicenseConfiguration -ErrorAction SilentlyContinue
    if ($rdsConfig) {
        $rdsConfig | Format-List
    } else {
        Write-Host "RDS Licensing not configured"
    }
} else {
    Write-Host "RDS Licensing cmdlets not available"
}

# --- Scheduled Tasks (non-Microsoft) ---
Write-Host "===== SCHEDULED TASKS (non-Microsoft) =====" -ForegroundColor Cyan
Get-ScheduledTask |
    Where-Object { $_.TaskPath -notmatch '\\Microsoft\\' -and $_.State -ne 'Disabled' } |
    Select-Object TaskName, TaskPath, State |
    Format-Table -AutoSize

# --- Hyper-V VMs ---
Write-Host "===== HYPER-V VMs (if any) =====" -ForegroundColor Cyan
if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
    $vms = Get-VM -ErrorAction SilentlyContinue
    if ($vms) {
        $vms | Select-Object Name, State, MemoryAssigned, ProcessorCount | Format-Table -AutoSize
    } else {
        Write-Host "Hyper-V installed but no VMs found"
    }
} else {
    Write-Host "Hyper-V not installed"
}

Write-Host "===== AUDIT COMPLETE =====" -ForegroundColor Green

Stop-Transcript
