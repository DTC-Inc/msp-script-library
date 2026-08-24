<#
.SYNOPSIS
    Read-only audit of every dependency that changes when a Windows host moves
    from a workgroup to an Active Directory domain. Built for NinjaOne delivery.

.DESCRIPTION
    Captures hardware identity, virtualisation platform, domain state, shares,
    services, databases, profiles, printers, remote-access surface and firewall
    posture prior to a domain join, so a Statement of Work is built on evidence
    rather than assumption, and so a failed cutover can be reversed rather than
    recovered.

    The script makes NO changes to the system. It does not write to the registry,
    does not start or stop services, and does not modify permissions. It does not
    enumerate file names inside practice-management or imaging data directories,
    which avoids capturing patient-identifying information. Where file activity is
    used as a signal, only counts and timestamps are reported.

    OUTPUT ORDER IS DELIBERATE. NinjaOne truncates the tail of long activity-log
    output, so all output is buffered and emitted summary-first: banner, then the
    checklist auto-fill block, then migration flags, then full detail. The final
    line is a completion token. If that token is absent, the log was truncated.

    OPTIONAL CAPTURE MODE: when DTC_CaptureDir is set, the script additionally
    writes a firewall rule export, an ODBC registry export and a share ACL dump to
    that directory. These are exports of existing state; nothing is altered.

.OUTPUTS
    System.String. Plain-text report to the success stream, sized and ordered for
    the NinjaOne activity log. A transcript is also written to disk.

.EXAMPLE
    $env:DTC_Client = 'Contoso Dental - Main'
    .\msft-windows-domain-readiness-audit.ps1

.EXAMPLE
    $env:DTC_Client      = 'Contoso Dental - Main'
    $env:DTC_Ticket      = '1234567'
    $env:DTC_ProfileSize = '1'
    $env:DTC_CaptureDir  = 'C:\_predomain'
    .\msft-windows-domain-readiness-audit.ps1

.NOTES
    Author  : Z. Boogher
    Version : 2.1.0

    NinjaOne preset variables (create with these exact names; all optional):
      DTC_Client        Client / site label for the banner. Default UNSPECIFIED.
      DTC_Ticket        Ticket reference for the banner. Default UNSPECIFIED.
      DTC_ProfileSize   '1' to total profile sizes on disk. Slow on session hosts.
      DTC_CaptureDir    Directory for state exports. Default off.
      DTC_LogPath       Transcript directory. Default %ProgramData%\DTC\Logs.
      DTC_LogRetention  Transcripts to retain. Default 10.
      DTC_MaxListItems  Cap on items per enumerated list. Default 60.

    Exit codes:
      0  Completed, no migration flags raised.
      2  Completed, one or more migration flags raised. Expected on most hosts.
      1  Script error. Report is INCOMPLETE; do not treat output as authoritative.

    A NinjaOne result of SUCCESS does not prove the audit ran to completion.
    Confirm the exit code AND the presence of the completion token in the activity
    log before using the output.

    StrictMode is Version 1.0, not 2.0. Version 2.0 throws on absent properties,
    which is a constant hazard in a script that reads optional registry values and
    WMI properties across mixed OS versions. Version 1.0 still catches the bug
    class that matters here - uninitialised variables - without the field risk.

    Relaunches itself 64-bit when started from a 32-bit host process. NinjaOne
    runs 32-bit by default and a 32-bit process reads a redirected registry view,
    which would silently miss 64-bit SQL Server instances.

    Virtualisation classification (2.1.0): the host is classified as physical or
    as a guest of a named platform, from manufacturer and model strings. This
    gates the warranty and out-of-band checklist lines - a guest's BIOS serial is
    a hypervisor-assigned GUID, not a service tag, and emitting it as one produces
    an unactionable warranty lookup per guest. HypervisorPresent is deliberately
    NOT used as the test: it reports true on a Hyper-V host as well as a guest,
    because enabling the role places the management OS on top of the hypervisor.
#>

# ---------------------------------------------------------------------------
# 64-bit self-relaunch. Runs before the mutex and transcript so the child owns
# both. NinjaOne writes the script to a temp file, so $PSCommandPath is populated;
# $MyInvocation is the fallback for hosts where it is not.
# ---------------------------------------------------------------------------
if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64' -and -not $env:DTC_RELAUNCHED) {
    $selfPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($selfPath)) { $selfPath = $MyInvocation.MyCommand.Definition }
    if (-not [string]::IsNullOrWhiteSpace($selfPath) -and (Test-Path -LiteralPath $selfPath)) {
        $env:DTC_RELAUNCHED = '1'
        $nativeShell = Join-Path $env:WINDIR 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $nativeShell) {
            & $nativeShell -NoProfile -ExecutionPolicy Bypass -File $selfPath
            exit $LASTEXITCODE
        }
    }
}

#Requires -Version 5.1

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$ClientLabel = $env:DTC_Client
if ([string]::IsNullOrWhiteSpace($ClientLabel)) { $ClientLabel = 'UNSPECIFIED' }

$TicketLabel = $env:DTC_Ticket
if ([string]::IsNullOrWhiteSpace($TicketLabel)) { $TicketLabel = 'UNSPECIFIED' }

$MeasureProfiles = ($env:DTC_ProfileSize -eq '1')

$CaptureDir = $env:DTC_CaptureDir
$DoCapture  = -not [string]::IsNullOrWhiteSpace($CaptureDir)

$LogDir = $env:DTC_LogPath
if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = Join-Path $env:ProgramData 'DTC\Logs' }

$LogRetention = 10
if ($env:DTC_LogRetention -match '^\d+$') { $LogRetention = [int]$env:DTC_LogRetention }

$MaxListItems = 60
if ($env:DTC_MaxListItems -match '^\d+$') { $MaxListItems = [int]$env:DTC_MaxListItems }

$ScriptTag     = 'DomainReadinessAudit'
$ScriptVersion = '2.1.0'
$CompleteToken = '##DTC-AUDIT-COMPLETE##'

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$script:Detail       = New-Object System.Collections.ArrayList
$script:Flags        = New-Object System.Collections.ArrayList
$script:RefHosts     = New-Object System.Collections.ArrayList
$script:Checklist    = New-Object System.Collections.ArrayList
$script:AclDump      = New-Object System.Collections.ArrayList
$script:ExitCode     = 0
$script:Mutex        = $null
$script:MutexHeld    = $false
$script:Transcribing = $false

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Add-Detail {
    [CmdletBinding()]
    param([string]$Text = '')
    [void]$script:Detail.Add($Text)
}

function Add-DetailSection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Add-Detail ''
    Add-Detail ('== ' + $Name.ToUpper() + ' ==')
}

function Add-DetailKv {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key, $Value)
    if ($null -eq $Value -or "$Value" -eq '') { $Value = '(not set)' }
    Add-Detail ('{0,-26}: {1}' -f $Key, $Value)
}

function Add-DetailList {
    <# Emits a capped list so a single pathological host cannot flood the log. #>
    [CmdletBinding()]
    param([string[]]$Items, [string]$Label = 'item')
    $total = @($Items).Count
    $shown = 0
    foreach ($line in $Items) {
        if ($shown -ge $MaxListItems) { break }
        Add-Detail $line
        $shown++
    }
    if ($total -gt $shown) {
        Add-Detail ('  ... and {0} more {1}(s) not shown (cap {2}; raise with DTC_MaxListItems)' -f ($total - $shown), $Label, $MaxListItems)
    }
}

function Add-Flag {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    if ($script:Flags -notcontains $Text) { [void]$script:Flags.Add($Text) }
}

function Register-Checklist {
    <#
        Records an answer against a checklist line ID so the operator transcribes
        rather than infers. Status is CAPTURED, PARTIAL, OPEN or N/A.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('CAPTURED', 'PARTIAL', 'OPEN', 'N/A')][string]$Status,
        [string]$Value = ''
    )
    $existing = $script:Checklist | Where-Object { $_.Id -eq $Id }
    if ($existing) {
        $existing.Status = $Status
        $existing.Value  = $Value
        return
    }
    [void]$script:Checklist.Add([PSCustomObject]@{ Id = $Id; Status = $Status; Value = $Value })
}

function Add-RefHost {
    [CmdletBinding()]
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    $clean = $Name.Trim().TrimStart('\').Split('\')[0].Split('/')[0].Split(',')[0]
    if ([string]::IsNullOrWhiteSpace($clean)) { return }
    if ($clean -eq $env:COMPUTERNAME) { return }
    if ($clean -match '^\d{1,3}(\.\d{1,3}){3}$') { return }
    if ($clean -eq '.' -or $clean -eq 'localhost') { return }
    if ($script:RefHosts -notcontains $clean) { [void]$script:RefHosts.Add($clean) }
}

function Get-RegValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    try {
        return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
    } catch {
        Write-Verbose ("Get-RegValue $Path\$Name : " + $_.Exception.Message)
        return $null
    }
}

function Get-VirtualisationPlatform {
    <#
        Classifies the host as physical or as a guest of a named platform.

        Manufacturer and model strings are the reliable tell. HypervisorPresent is
        NOT sufficient on its own: it reports true on a Hyper-V host as well as a
        guest, because enabling the role places the management OS on top of the
        hypervisor, so it cannot distinguish the two.

        Returns a display string; 'Physical' means no guest signature matched.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$ComputerSystem)

    $signature = "$($ComputerSystem.Manufacturer) $($ComputerSystem.Model)"

    switch -Regex ($signature) {
        'Microsoft Corporation.*Virtual Machine' { return 'Hyper-V guest' }
        'VMware'                                 { return 'VMware guest' }
        'innotek|VirtualBox'                     { return 'VirtualBox guest' }
        'QEMU|KVM'                               { return 'KVM/QEMU guest' }
        '\bXen\b'                                { return 'Xen guest' }
        'Parallels'                              { return 'Parallels guest' }
        'Amazon EC2'                             { return 'EC2 guest' }
        'Google Compute Engine'                  { return 'GCE guest' }
        'Nutanix'                                { return 'Nutanix guest' }
    }

    # Fallback: a Hyper-V guest whose manufacturer strings have been customised
    # still runs the integration-services heartbeat. A Hyper-V HOST does not.
    if (Get-Service -Name 'vmicheartbeat' -ErrorAction SilentlyContinue) {
        return 'Hyper-V guest (inferred from integration services)'
    }

    return 'Physical'
}

function Get-DtcSqlInfo {
    <#
        Read-only query over an integrated connection. Returns Windows-type
        server principals and database file metadata. SQL logins are omitted as
        noise; they survive a domain join unchanged.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ServerSpec)

    $result = [PSCustomObject]@{ WindowsLogins = $null; Databases = $null; Error = $null }
    $conn = $null
    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection
        $conn.ConnectionString = "Server=$ServerSpec;Database=master;Integrated Security=True;Connect Timeout=5;Application Name=DTC-ReadinessAudit"
        $conn.Open()

        $logins = New-Object System.Collections.ArrayList
        $cmd = $conn.CreateCommand()
        $cmd.CommandTimeout = 15
        $cmd.CommandText = "SELECT name, type_desc, is_disabled FROM sys.server_principals WHERE type IN ('U','G') ORDER BY name"
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            [void]$logins.Add([PSCustomObject]@{
                Name     = $reader.GetString(0)
                TypeDesc = $reader.GetString(1)
                Disabled = $reader.GetBoolean(2)
            })
        }
        $reader.Close()
        $result.WindowsLogins = $logins

        $dbs = New-Object System.Collections.ArrayList
        $cmd2 = $conn.CreateCommand()
        $cmd2.CommandTimeout = 15
        $cmd2.CommandText = @"
SELECT d.name AS db_name, d.state_desc, mf.physical_name
FROM sys.databases d
JOIN sys.master_files mf ON mf.database_id = d.database_id
WHERE d.database_id > 4 AND mf.type = 0
ORDER BY d.name
"@
        $reader2 = $cmd2.ExecuteReader()
        while ($reader2.Read()) {
            [void]$dbs.Add([PSCustomObject]@{
                Name         = $reader2.GetString(0)
                State        = $reader2.GetString(1)
                PhysicalName = $reader2.GetString(2)
            })
        }
        $reader2.Close()
        $result.Databases = $dbs
        return $result
    } catch {
        $result.Error = $_.Exception.Message
        Write-Verbose ("SQL query $ServerSpec : " + $_.Exception.Message)
        return $result
    } finally {
        if ($conn) { $conn.Dispose() }
    }
}

function Get-PathActivity {
    <#
        Production-versus-legacy signal. Reports directory timestamp and a count
        of top-level entries written recently. Counts and timestamps only - no
        file names are read or emitted, so nothing patient-identifying is captured.
        Non-recursive by design; recursion over a multi-terabyte imaging store
        would exceed the RMM script timeout.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [int]$Days = 30)

    $out = [PSCustomObject]@{ Exists = $false; LastWrite = $null; RecentCount = 0; TotalTop = 0 }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $out }
        $out.Exists    = $true
        $out.LastWrite = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).LastWriteTime
        $cutoff = (Get-Date).AddDays(-$Days)
        $top = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
        $out.TotalTop    = $top.Count
        $out.RecentCount = @($top | Where-Object { $_.LastWriteTime -gt $cutoff }).Count
        return $out
    } catch {
        Write-Verbose ("Path activity $Path : " + $_.Exception.Message)
        return $out
    }
}

function Invoke-AuditSection {
    <#
        Runs a section in isolation. A failing section is reported and skipped
        rather than aborting the whole audit, which matters when the operator
        only gets one shot per maintenance visit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    Add-DetailSection $Name
    try {
        & $Body
    } catch {
        Add-Detail ('  !! SECTION FAILED: ' + $_.Exception.Message)
        Add-Flag ("Audit section '" + $Name + "' failed - that section's data is missing and must be captured manually")
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {

    # -- single instance -----------------------------------------------------
    $script:Mutex = New-Object System.Threading.Mutex($false, "Global\DTC-$ScriptTag")
    try {
        $script:MutexHeld = $script:Mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        Write-Verbose 'Recovered abandoned mutex from a prior run.'
        $script:MutexHeld = $true
    }
    if (-not $script:MutexHeld) {
        Write-Output 'Another instance of this audit is already running on this host. Exiting without action.'
        Write-Output $CompleteToken
        $script:ExitCode = 0
        return
    }

    # -- transcript with rotation -------------------------------------------
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
        }
        Get-ChildItem -LiteralPath $LogDir -Filter "$ScriptTag-*.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip $LogRetention |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $logFile = Join-Path $LogDir ("$ScriptTag-{0}-{1}.log" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Start-Transcript -Path $logFile -Force | Out-Null
        $script:Transcribing = $true
    } catch {
        Write-Verbose ('Transcript unavailable: ' + $_.Exception.Message)
    }

    # -- capture directory ---------------------------------------------------
    if ($DoCapture) {
        try {
            if (-not (Test-Path -LiteralPath $CaptureDir)) {
                New-Item -Path $CaptureDir -ItemType Directory -Force | Out-Null
            }
        } catch {
            Write-Verbose ('Capture directory unavailable: ' + $_.Exception.Message)
            $DoCapture = $false
        }
    }

    # -- HKU drive -----------------------------------------------------------
    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script -ErrorAction SilentlyContinue | Out-Null
    }

    # -- role and platform detection ----------------------------------------
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $isServerOS = ($os.ProductType -ne 1)
    $isDC       = ($cs.DomainRole -eq 4 -or $cs.DomainRole -eq 5)
    $isHyperV   = $false
    $isRDSH     = $false
    if ($isServerOS) {
        try {
            $installedFeatures = Get-WindowsFeature -ErrorAction Stop | Where-Object { $_.Installed }
            $isHyperV = [bool]($installedFeatures | Where-Object { $_.Name -eq 'Hyper-V' })
            $isRDSH   = [bool]($installedFeatures | Where-Object { $_.Name -eq 'RDS-RD-Server' })
        } catch {
            Write-Verbose ('Role enumeration unavailable: ' + $_.Exception.Message)
        }
    }

    $virtPlatform   = Get-VirtualisationPlatform -ComputerSystem $cs
    $isVirtualGuest = ($virtPlatform -ne 'Physical')

    $roleParts = @()
    if ($isServerOS) { $roleParts += 'ServerOS' } else { $roleParts += 'Workstation' }
    if ($isDC)     { $roleParts += 'DomainController' }
    if ($isHyperV) { $roleParts += 'Hyper-V Host' }
    if ($isRDSH)   { $roleParts += 'RD Session Host' }
    $roleParts += $virtPlatform
    $roleText = $roleParts -join ' / '

    Register-Checklist -Id 'CL-1.1-A' -Status 'CAPTURED' -Value ('{0} | role {1} | {2}' -f $env:COMPUTERNAME, $roleText, (Get-Date -Format 'yyyy-MM-dd HH:mm'))

    # =======================================================================
    # HARDWARE IDENTITY
    # =======================================================================
    Invoke-AuditSection -Name 'Hardware Identity' -Body {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
        $cpus = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue)
        $mem  = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction SilentlyContinue)
        $arr  = Get-CimInstance -ClassName Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue | Select-Object -First 1

        $ramGb      = [math]::Round(($cs.TotalPhysicalMemory / 1GB), 0)
        $slotsUsed  = $mem.Count
        $slotsTotal = if ($arr) { $arr.MemoryDevices } else { 'unknown' }
        $maxGb      = if ($arr -and $arr.MaxCapacityEx) { [math]::Round(($arr.MaxCapacityEx / 1MB), 0) } else { 'unknown' }
        $cpuName    = if ($cpus.Count -gt 0) { $cpus[0].Name.Trim() } else { 'unknown' }
        $cores      = ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum
        $logical    = $cs.NumberOfLogicalProcessors

        Add-DetailKv 'Platform'      $virtPlatform
        Add-DetailKv 'Manufacturer'  $cs.Manufacturer
        Add-DetailKv 'Model'         $cs.Model
        Add-DetailKv 'BIOS version'  $(if ($bios) { $bios.SMBIOSBIOSVersion } else { 'unknown' })
        Add-DetailKv 'CPU'           $cpuName
        Add-DetailKv 'Sockets/Cores' ('{0} socket(s), {1} physical, {2} logical' -f $cpus.Count, $cores, $logical)

        if ($isVirtualGuest) {
            Add-DetailKv 'BIOS serial'   ('{0}   (hypervisor-assigned GUID - NOT a service tag)' -f $(if ($bios) { $bios.SerialNumber } else { 'unknown' }))
            Add-DetailKv 'RAM allocated' ('{0} GB   (virtual allocation, not installed hardware)' -f $ramGb)
            Add-Detail ''
            Add-Detail '  NOTE: this is a virtual guest. Hardware warranty and out-of-band management'
            Add-Detail '        apply to the virtualisation host, not to this machine. An absent TPM'
            Add-Detail '        is expected on a Generation 2 guest without a virtual TPM and is not'
            Add-Detail '        a hardware finding.'

            Register-Checklist -Id 'CL-1.2-A' -Status 'CAPTURED' -Value ('{0} | {1} | {2}C/{3}T allocated | {4} GB allocated' -f `
                $virtPlatform, $cs.Model, $cores, $logical, $ramGb)
            Register-Checklist -Id 'CL-2.1-A' -Status 'N/A' -Value ($virtPlatform + ' - no hardware warranty; warranty applies to the virtualisation host')
        } else {
            Add-DetailKv 'Service tag'   $(if ($bios) { $bios.SerialNumber } else { 'unknown' })
            Add-DetailKv 'RAM installed' ('{0} GB (slots {1} of {2}, max {3} GB)' -f $ramGb, $slotsUsed, $slotsTotal, $maxGb)

            Register-Checklist -Id 'CL-1.2-A' -Status 'CAPTURED' -Value ('{0} {1} | tag {2} | {3} | {4}C/{5}T | {6} GB, slots {7}/{8}, max {9} GB' -f `
                $cs.Manufacturer, $cs.Model, $(if ($bios) { $bios.SerialNumber } else { 'unknown' }), $cpuName, $cores, $logical, $ramGb, $slotsUsed, $slotsTotal, $maxGb)

            if ($bios -and $bios.SerialNumber) {
                Register-Checklist -Id 'CL-2.1-A' -Status 'OPEN' -Value ('Warranty lookup required for service tag ' + $bios.SerialNumber + ' - not obtainable from the OS')
            }
        }

        Add-Detail ''
        foreach ($vol in (Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
            Add-Detail ('  Volume {0} : {1} GB free of {2} GB' -f $vol.DeviceID, `
                [math]::Round(($vol.FreeSpace / 1GB), 1), [math]::Round(($vol.Size / 1GB), 1))
        }
    }

    # =======================================================================
    # IDENTITY / DOMAIN STATE
    # =======================================================================
    Invoke-AuditSection -Name 'Identity / Domain State' -Body {
        Add-DetailKv 'Computer name'      $env:COMPUTERNAME
        Add-DetailKv 'Domain / Workgroup' $cs.Domain
        Add-DetailKv 'PartOfDomain'       $cs.PartOfDomain
        Add-DetailKv 'DomainRole'         ('{0}   (0/1=wkstn  2=standalone svr  3=member svr  4/5=DC)' -f $cs.DomainRole)
        Add-DetailKv 'OS'                 $os.Caption
        Add-DetailKv 'Version / Build'    $os.Version
        Add-DetailKv 'OS install date'    $os.InstallDate
        Add-DetailKv 'Last boot'          $os.LastBootUpTime

        Register-Checklist -Id 'CL-1.2-B' -Status 'CAPTURED' -Value ('{0} | build {1} | domain state: {2} | {3}' -f $os.Caption, $os.Version, $cs.Domain, $virtPlatform)

        if (-not $cs.PartOfDomain) {
            Add-Flag ("$env:COMPUTERNAME is WORKGROUP '" + $cs.Domain + "' - full identity cutover required")
        }

        $tcpipParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
        Add-DetailKv 'Primary DNS suffix' (Get-RegValue -Path $tcpipParams -Name 'Domain')
        Add-DetailKv 'DHCP DNS suffix'    (Get-RegValue -Path $tcpipParams -Name 'DhcpDomain')
        Add-DetailKv 'NV Hostname'        (Get-RegValue -Path $tcpipParams -Name 'NV Hostname')

        # Sign-in format, current versus post-join. Feeds the remote user notice.
        $currentFormat = if ($cs.PartOfDomain) { "$($cs.Domain)\username" } else { "$env:COMPUTERNAME\username  -or-  .\username" }
        Add-DetailKv 'Sign-in format now'   $currentFormat
        Add-DetailKv 'Sign-in format after' '<NETBIOS>\username  -or-  username@<domain.fqdn>   (fill from the agreed domain name)'
        Register-Checklist -Id 'CL-2.4-C' -Status 'PARTIAL' -Value ('current = ' + $currentFormat + ' ; future = <NETBIOS>\username once the domain name is agreed')
    }

    # =======================================================================
    # NETWORK CONFIGURATION
    # =======================================================================
    Invoke-AuditSection -Name 'Network Configuration' -Body {
        foreach ($cfg in (Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
            if (-not $cfg.IPv4Address) { continue }
            $ipList  = ($cfg.IPv4Address | ForEach-Object { $_.IPAddress }) -join ','
            $gwList  = ($cfg.IPv4DefaultGateway | ForEach-Object { $_.NextHop }) -join ','
            $dnsList = ($cfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ','
            $prefix  = (Get-NetIPAddress -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        Select-Object -First 1).PrefixLength
            $dhcp    = (Get-NetIPInterface -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
            Add-Detail ('  {0,-22} IPv4={1}/{2}  GW={3}  DNS={4}  DHCP={5}' -f `
                $cfg.InterfaceAlias, $ipList, $prefix, $gwList, $dnsList, $dhcp)
        }

        $hostsPath    = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
        $hostsEntries = @(Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*\d' })
        Add-DetailKv 'HOSTS file entries' $hostsEntries.Count
        foreach ($entry in $hostsEntries) {
            Add-Detail ('  hosts-entry : ' + $entry.Trim())
            Add-Flag 'HOSTS file contains static entries - these will mask AD DNS after join'
        }

        if ($isServerOS) {
            try {
                $dnsRole = Get-WindowsFeature -Name DNS -ErrorAction Stop
                Add-DetailKv 'DNS Server role' $dnsRole.InstallState
                if ($dnsRole.Installed) {
                    Add-Flag 'Standalone DNS Server role present - non-AD zones must be retired at cutover, not left running alongside AD DNS'
                    $zoneLines = @()
                    try {
                        Get-DnsServerZone -ErrorAction Stop | ForEach-Object {
                            $zoneLines += ('  dns-zone    : {0,-30} Type={1} AD-integrated={2}' -f $_.ZoneName, $_.ZoneType, $_.IsDsIntegrated)
                        }
                    } catch {
                        Write-Verbose ('Zone enumeration failed: ' + $_.Exception.Message)
                        $zoneLines += '  dns-zone    : (unable to enumerate)'
                    }
                    Add-DetailList -Items $zoneLines -Label 'zone'
                    Register-Checklist -Id 'CL-2.2-D' -Status 'CAPTURED' -Value ('DNS role INSTALLED - ' + $zoneLines.Count + ' zone(s); must be retired at cutover')
                } else {
                    Register-Checklist -Id 'CL-2.2-D' -Status 'CAPTURED' -Value 'No standalone DNS role on this host - nothing to retire'
                }
            } catch {
                Write-Verbose ('DNS role query failed: ' + $_.Exception.Message)
            }
        }

        Register-Checklist -Id 'CL-2.2-A' -Status 'OPEN' -Value 'Gateway configuration export must be taken from the network controller - not obtainable from the OS'
        Register-Checklist -Id 'CL-2.2-B' -Status 'OPEN' -Value 'Static address for the controller must be reserved outside the DHCP pool - pool range lives on the gateway'
    }

    # =======================================================================
    # LOCAL ACCOUNTS
    # =======================================================================
    Invoke-AuditSection -Name 'Local Accounts' -Body {
        $localUsers = $null
        try { $localUsers = Get-LocalUser -ErrorAction Stop } catch {
            Write-Verbose ('Get-LocalUser unavailable: ' + $_.Exception.Message)
        }
        $lines = @()
        if ($localUsers) {
            foreach ($u in $localUsers) {
                $lines += ('  {0,-26} Enabled={1,-5} PwdLastSet={2,-22} LastLogon={3,-22} PwdExpires={4}' -f `
                    $u.Name, $u.Enabled, $u.PasswordLastSet, $u.LastLogon, $u.PasswordExpires)
            }
        } else {
            Get-CimInstance -ClassName Win32_UserAccount -Filter 'LocalAccount=True' | ForEach-Object {
                $lines += ('  {0,-26} Disabled={1,-5} SID={2}   (via CIM fallback)' -f $_.Name, $_.Disabled, $_.SID)
            }
        }
        Add-DetailList -Items $lines -Label 'account'
    }

    # =======================================================================
    # LOCAL GROUP MEMBERSHIP
    # =======================================================================
    Invoke-AuditSection -Name 'Local Group Membership' -Body {
        $rdpMembers = New-Object System.Collections.ArrayList
        foreach ($groupName in @('Administrators', 'Remote Desktop Users', 'Users', 'Backup Operators', 'Power Users')) {
            $members = $null
            try { $members = Get-LocalGroupMember -Group $groupName -ErrorAction Stop } catch {
                Write-Verbose ("Get-LocalGroupMember $groupName : " + $_.Exception.Message)
            }
            if ($members) {
                foreach ($m in $members) {
                    Add-Detail ('  {0,-22} <- {1,-40} ({2})' -f $groupName, $m.Name, $m.ObjectClass)
                    if ($groupName -eq 'Remote Desktop Users') { [void]$rdpMembers.Add($m.Name) }
                }
            } else {
                try {
                    $adsiGroup = [ADSI]("WinNT://$env:COMPUTERNAME/$groupName,group")
                    $adsiGroup.psbase.Invoke('Members') | ForEach-Object {
                        $memberName = $_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null)
                        Add-Detail ('  {0,-22} <- {1}   (via ADSI fallback)' -f $groupName, $memberName)
                        if ($groupName -eq 'Remote Desktop Users') { [void]$rdpMembers.Add($memberName) }
                    }
                } catch {
                    Write-Verbose ("ADSI fallback $groupName : " + $_.Exception.Message)
                    Add-Detail ('  {0,-22} <- (group not present or unreadable)' -f $groupName)
                }
            }
        }
        $script:RdpGroupMembers = $rdpMembers
    }

    # =======================================================================
    # USER PROFILES
    # =======================================================================
    Invoke-AuditSection -Name 'User Profiles  (domain join = new SID = new profile per user)' -Body {
        if (-not $MeasureProfiles) { Add-Detail '  (size totals skipped - set DTC_ProfileSize=1 to include)' }
        $profileCount = 0
        $recentCount  = 0
        $cutoff = (Get-Date).AddDays(-90)
        $lines  = @()
        foreach ($p in (Get-CimInstance -ClassName Win32_UserProfile | Where-Object { -not $_.Special })) {
            $profileCount++
            $account = $p.SID
            try {
                $account = (New-Object System.Security.Principal.SecurityIdentifier($p.SID)).Translate([System.Security.Principal.NTAccount]).Value
            } catch {
                Write-Verbose ('SID translate failed: ' + $_.Exception.Message)
            }
            if ($p.LastUseTime -and $p.LastUseTime -gt $cutoff) { $recentCount++ }
            $size = 'not measured'
            if ($MeasureProfiles -and $p.LocalPath -and (Test-Path -LiteralPath $p.LocalPath)) {
                try {
                    $sum = (Get-ChildItem -LiteralPath $p.LocalPath -Recurse -Force -File -ErrorAction SilentlyContinue |
                            Measure-Object -Property Length -Sum).Sum
                    $size = ('{0} MB' -f [math]::Round(($sum / 1MB), 0))
                } catch {
                    Write-Verbose ('Profile measure failed: ' + $_.Exception.Message)
                    $size = 'measure failed'
                }
            }
            $lines += ('  {0,-30} {1,-40} LastUse={2,-22} Loaded={3,-5} Size={4}' -f `
                $account, $p.LocalPath, $p.LastUseTime, $p.Loaded, $size)
        }
        Add-DetailList -Items $lines -Label 'profile'
        Add-DetailKv 'Non-special profiles'   $profileCount
        Add-DetailKv 'Active in last 90 days' $recentCount
        if ($profileCount -gt 0) {
            Add-Flag "$profileCount local profile(s) on $env:COMPUTERNAME ($recentCount active in 90 days) - each becomes a new profile after domain join"
        }
        $script:ProfileTotal  = $profileCount
        $script:ProfileRecent = $recentCount
    }

    # =======================================================================
    # SMB SHARES + PERMISSIONS + ACTIVITY
    # =======================================================================
    Invoke-AuditSection -Name 'SMB Shares, Permissions and Write Activity' -Body {
        $shares = @()
        try {
            $shares = @(Get-SmbShare -ErrorAction Stop | Where-Object {
                $_.Name -notmatch '^\w\$$' -and $_.Name -notin @('IPC$', 'ADMIN$', 'print$')
            })
        } catch {
            Write-Verbose ('Get-SmbShare unavailable: ' + $_.Exception.Message)
            Add-Detail '  (Get-SmbShare unavailable on this host)'
            return
        }
        if ($shares.Count -eq 0) { Add-Detail '  (no non-administrative shares)'; return }

        foreach ($s in $shares) {
            Add-Detail ('  SHARE {0}   ->   {1}' -f $s.Name, $s.Path)
            [void]$script:AclDump.Add(('SHARE {0} -> {1}' -f $s.Name, $s.Path))

            $activity = Get-PathActivity -Path $s.Path -Days 30
            if ($activity.Exists) {
                Add-Detail ('        activity   : dir-lastwrite={0}  top-level entries={1}  modified<30d={2}' -f `
                    $activity.LastWrite, $activity.TotalTop, $activity.RecentCount)
            }

            Get-SmbShareAccess -Name $s.Name -ErrorAction SilentlyContinue | ForEach-Object {
                $line = ('        share-perm : {0,-42} {1} {2}' -f $_.AccountName, $_.AccessControlType, $_.AccessRight)
                Add-Detail $line
                [void]$script:AclDump.Add($line)
                if ($_.AccountName -eq 'Everyone') {
                    Add-Flag ("Share '" + $s.Name + "' grants Everyone - re-ACL to a domain group AFTER endpoints are joined and validated, never before")
                }
                if ("$($_.AccountName)" -like "$env:COMPUTERNAME\*") {
                    Add-Flag ("Share '" + $s.Name + "' grants LOCAL account " + $_.AccountName + " - will not resolve for domain users")
                }
            }
            if ($s.Path -and (Test-Path -LiteralPath $s.Path)) {
                try {
                    $aceLines = @()
                    (Get-Acl -LiteralPath $s.Path).Access | ForEach-Object {
                        $line = ('        ntfs-ace   : {0,-42} {1} {2}' -f $_.IdentityReference, $_.AccessControlType, $_.FileSystemRights)
                        $aceLines += $line
                        [void]$script:AclDump.Add($line)
                        if ("$($_.IdentityReference)" -like "$env:COMPUTERNAME\*") {
                            Add-Flag ('NTFS ACE on ' + $s.Path + ' references LOCAL account ' + $_.IdentityReference)
                        }
                    }
                    Add-DetailList -Items $aceLines -Label 'ACE'
                } catch {
                    Write-Verbose ('ACL read failed: ' + $_.Exception.Message)
                    Add-Detail '        ntfs-ace   : (ACL unreadable)'
                }
            }
        }
    }

    # =======================================================================
    # SERVICE LOGON IDENTITIES
    # =======================================================================
    Invoke-AuditSection -Name 'Service Logon Identities  (non-builtin only)' -Body {
        $builtinAccounts = @(
            'LocalSystem', 'NT AUTHORITY\LocalService', 'NT AUTHORITY\NetworkService',
            'NT AUTHORITY\LOCAL SERVICE', 'NT AUTHORITY\NETWORK SERVICE', 'NT AUTHORITY\SYSTEM'
        )
        $customCount = 0
        Get-CimInstance -ClassName Win32_Service | Sort-Object Name | ForEach-Object {
            $startName = $_.StartName
            if ($startName -and ($builtinAccounts -notcontains $startName)) {
                $customCount++
                Add-Detail ('  {0,-40} runs-as={1,-32} State={2,-8} Start={3}' -f $_.Name, $startName, $_.State, $_.StartMode)
                Add-Flag ("Service '" + $_.Name + "' runs as '" + $startName + "' - confirm it survives domain join")
            }
        }
        if ($customCount -eq 0) { Add-Detail '  (all services run under builtin accounts - clean)' }
    }

    # =======================================================================
    # PMS / IMAGING FOOTPRINT  + PRODUCTION SIGNAL
    # =======================================================================
    Invoke-AuditSection -Name 'PMS / Imaging Footprint  (no data enumeration)' -Body {
        $platformMap = @{
            'SoftDent'    = 'Carestream|SoftDent'
            'Eaglesoft'   = 'Eaglesoft|Patterson'
            'CS Imaging'  = 'CS Imaging|CSIS'
            'Dentrix'     = 'Dentrix'
            'Open Dental' = 'Open ?Dental'
            'Sidexis'     = 'Sidexis'
            'DEXIS'       = 'DEXIS'
            'VixWin'      = 'VixWin'
            'TDO'         = '\bTDO\b'
            'WinOMS'      = 'WinOMS'
            'iDentalSoft' = 'iDentalSoft'
            'DTX Studio'  = 'DTX'
        }
        $enginePattern = 'SQLANY|SQL Anywhere|Sybase|Actian|Pervasive|MySQL|MariaDB|FairCom|ctree|c-tree'
        $allServices = @(Get-CimInstance -ClassName Win32_Service)

        # Database engine services, which are the production tell.
        $engineLines = @()
        $engineFound = @()
        foreach ($svc in ($allServices | Where-Object { $_.Name -match $enginePattern -or $_.DisplayName -match $enginePattern })) {
            $engineLines += ('  engine  {0,-40} State={1,-9} Start={2,-10} RunAs={3}' -f $svc.Name, $svc.State, $svc.StartMode, $svc.StartName)
            $engineLines += ('          path: ' + $svc.PathName)
            $engineFound += ('{0}={1}' -f $svc.Name, $svc.State)
            if ($svc.PathName -match '\\\\([^\\]+)\\') { Add-RefHost $Matches[1] }
            # Stat any database file referenced on the command line. Path and
            # timestamp only; the file is never opened.
            if ($svc.PathName -match '([A-Za-z]:\\[^"]*?\.db)') {
                $dbPath = $Matches[1]
                try {
                    if (Test-Path -LiteralPath $dbPath) {
                        $dbItem = Get-Item -LiteralPath $dbPath -Force -ErrorAction Stop
                        $engineLines += ('          dbfile: {0}  size={1} MB  lastwrite={2}' -f `
                            $dbPath, [math]::Round(($dbItem.Length / 1MB), 1), $dbItem.LastWriteTime)
                    } else {
                        $engineLines += ('          dbfile: {0}  (NOT PRESENT)' -f $dbPath)
                    }
                } catch {
                    Write-Verbose ('DB file stat failed: ' + $_.Exception.Message)
                }
            }
        }
        if ($engineLines.Count -eq 0) {
            Add-Detail '  engine  (no database engine service detected)'
            $engineFound += 'none detected'
        } else {
            Add-DetailList -Items $engineLines -Label 'engine line'
        }

        # Application services and installed products, per platform.
        $platformsPresent = @()
        foreach ($platform in ($platformMap.Keys | Sort-Object)) {
            $pattern = $platformMap[$platform]
            $svcs = @($allServices | Where-Object { $_.Name -match $pattern -or $_.DisplayName -match $pattern })
            $apps = @()
            foreach ($uninstallRoot in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                                         'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
                if (-not (Test-Path -LiteralPath $uninstallRoot)) { continue }
                Get-ChildItem -LiteralPath $uninstallRoot -ErrorAction SilentlyContinue | ForEach-Object {
                    $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                    if ($props -and $props.DisplayName -and $props.DisplayName -match $pattern) {
                        $apps += $props
                    }
                }
            }
            if ($svcs.Count -eq 0 -and $apps.Count -eq 0) { continue }

            $running = @($svcs | Where-Object { $_.State -eq 'Running' }).Count
            $platformsPresent += ('{0}(svc {1}/{2} running)' -f $platform, $running, $svcs.Count)
            Add-Detail ''
            Add-Detail ('  PLATFORM {0}   services {1} ({2} running)   products {3}' -f $platform, $svcs.Count, $running, $apps.Count)
            foreach ($svc in ($svcs | Sort-Object Name)) {
                Add-Detail ('        svc  {0,-40} State={1,-9} Start={2,-10} RunAs={3}' -f $svc.Name, $svc.State, $svc.StartMode, $svc.StartName)
                if ($svc.PathName -match '\\\\([^\\]+)\\') { Add-RefHost $Matches[1] }
            }
            foreach ($app in ($apps | Sort-Object DisplayName -Unique)) {
                Add-Detail ('        app  {0,-50} v{1}' -f $app.DisplayName, $app.DisplayVersion)
                if ($app.InstallLocation -and (Test-Path -LiteralPath $app.InstallLocation)) {
                    $act = Get-PathActivity -Path $app.InstallLocation -Days 30
                    if ($act.Exists) {
                        Add-Detail ('             loc: {0}  lastwrite={1}  modified<30d={2}' -f `
                            $app.InstallLocation, $act.LastWrite, $act.RecentCount)
                    }
                }
            }
        }

        if ($platformsPresent.Count -eq 0) {
            Register-Checklist -Id 'CL-1.1-E' -Status 'CAPTURED' -Value 'No practice-management platform detected on this host'
            Register-Checklist -Id 'CL-1.3-D' -Status 'N/A' -Value 'No practice platform on this host'
        } else {
            Register-Checklist -Id 'CL-1.1-E' -Status 'CAPTURED' -Value (($platformsPresent -join '; ') + ' | engines: ' + ($engineFound -join '; '))
            if ($platformsPresent.Count -gt 1) {
                Register-Checklist -Id 'CL-1.3-D' -Status 'PARTIAL' -Value ('Multiple platforms present: ' + ($platformsPresent -join '; ') + '. Compare engine state and share write activity above; confirm production platform with the practice.')
                Add-Flag ('More than one practice-management platform detected (' + ($platformsPresent -join '; ') + ') - confirm which is production before scoping validation')
            } else {
                Register-Checklist -Id 'CL-1.3-D' -Status 'CAPTURED' -Value ('Single platform: ' + ($platformsPresent -join '; '))
            }
        }
    }

    # =======================================================================
    # SQL INSTANCES / AUTH / PORTS / LOGINS / DATABASES
    # =======================================================================
    Invoke-AuditSection -Name 'SQL Instances, Authentication, Ports, Logins' -Body {
        $instanceRoot = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
        if (-not (Test-Path -LiteralPath $instanceRoot)) {
            Add-Detail '  (no SQL Server instances found in registry)'
            Register-Checklist -Id 'CL-1.1-F' -Status 'CAPTURED' -Value 'No SQL Server instances on this host'
            return
        }
        $instanceKey = Get-Item -LiteralPath $instanceRoot
        $authSummary = @()
        foreach ($instanceName in $instanceKey.GetValueNames()) {
            $instanceId = $instanceKey.GetValue($instanceName)
            $setupKey   = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\Setup"
            $engineKey  = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer"
            $tcpKey     = "$engineKey\SuperSocketNetLib\Tcp\IPAll"

            $edition   = Get-RegValue -Path $setupKey -Name 'Edition'
            $version   = Get-RegValue -Path $setupKey -Name 'Version'
            $loginMode = Get-RegValue -Path $engineKey -Name 'LoginMode'
            $tcpPort   = Get-RegValue -Path $tcpKey -Name 'TcpPort'
            $dynPort   = Get-RegValue -Path $tcpKey -Name 'TcpDynamicPorts'

            $loginModeText = switch ($loginMode) {
                1       { 'Windows Authentication ONLY' }
                2       { 'Mixed Mode (SQL + Windows)' }
                default { 'unknown' }
            }
            if ($instanceName -eq 'MSSQLSERVER') {
                $serviceName = 'MSSQLSERVER'; $serverSpec = '.'
            } else {
                $serviceName = "MSSQL`$$instanceName"; $serverSpec = ".\$instanceName"
            }
            $svc = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $serviceName + "'") -ErrorAction SilentlyContinue

            $portMode = if (-not [string]::IsNullOrWhiteSpace("$tcpPort")) { "static $tcpPort" }
                        elseif (-not [string]::IsNullOrWhiteSpace("$dynPort")) { "DYNAMIC $dynPort" }
                        else { 'not configured' }

            Add-Detail ''
            Add-Detail ('  INSTANCE {0}' -f $instanceName)
            Add-Detail ('        edition   : {0}   version {1}' -f $edition, $version)
            Add-Detail ('        auth mode : {0}   (LoginMode={1})' -f $loginModeText, $loginMode)
            Add-Detail ('        tcp port  : {0}' -f $portMode)
            if ($svc) { Add-Detail ('        service   : {0}  State={1}  RunAs={2}' -f $svc.Name, $svc.State, $svc.StartName) }

            $authSummary += ('{0}={1}, {2}' -f $instanceName, $loginModeText, $portMode)

            if ([string]::IsNullOrWhiteSpace("$tcpPort") -and -not [string]::IsNullOrWhiteSpace("$dynPort")) {
                Add-Flag ("SQL instance '" + $instanceName + "' uses a DYNAMIC port - scope the firewall rule to the program, not the port, or it breaks at the next service restart")
            }
            if ($loginMode -eq 1) {
                Add-Flag ("SQL instance '" + $instanceName + "' is Windows-Auth ONLY - existing logins break at domain join. See Windows principals below.")
            }

            if ($svc -and $svc.State -eq 'Running') {
                $sqlInfo = Get-DtcSqlInfo -ServerSpec $serverSpec
                if ($sqlInfo.Error) {
                    Add-Detail ('        win-logins: (query failed - ' + $sqlInfo.Error + ')')
                } else {
                    if (@($sqlInfo.WindowsLogins).Count -eq 0) {
                        Add-Detail '        win-logins: (none - all logins are SQL-authenticated; clean across a domain join)'
                    } else {
                        $loginLines = @()
                        foreach ($login in $sqlInfo.WindowsLogins) {
                            $loginLines += ('        win-login : {0,-46} {1,-16} Disabled={2}' -f $login.Name, $login.TypeDesc, $login.Disabled)
                            if ($login.Name -like "$env:COMPUTERNAME\*") {
                                Add-Flag ("SQL login '" + $login.Name + "' on instance '" + $instanceName + "' references a LOCAL principal - will not resolve after domain join")
                            }
                            if ($login.Name -eq 'BUILTIN\Administrators') {
                                Add-Flag ("SQL instance '" + $instanceName + "' grants BUILTIN\Administrators - after domain join this silently widens to every Domain Admin. Review before cutover.")
                            }
                        }
                        Add-DetailList -Items $loginLines -Label 'login'
                    }
                    # Database write activity: a production tell, and PHI-safe.
                    foreach ($db in $sqlInfo.Databases) {
                        $stamp = 'file not reachable'
                        try {
                            if (Test-Path -LiteralPath $db.PhysicalName) {
                                $f = Get-Item -LiteralPath $db.PhysicalName -Force -ErrorAction Stop
                                $stamp = ('{0} MB, lastwrite {1}' -f [math]::Round(($f.Length / 1MB), 1), $f.LastWriteTime)
                            }
                        } catch {
                            Write-Verbose ('DB stat failed: ' + $_.Exception.Message)
                        }
                        Add-Detail ('        database  : {0,-28} {1,-10} {2}' -f $db.Name, $db.State, $stamp)
                    }
                }
            }
        }
        Register-Checklist -Id 'CL-1.1-F' -Status 'CAPTURED' -Value ($authSummary -join ' | ')
    }

    # =======================================================================
    # ODBC DATA SOURCES
    # =======================================================================
    Invoke-AuditSection -Name 'ODBC Data Sources' -Body {
        $odbcHives = New-Object System.Collections.ArrayList
        [void]$odbcHives.Add('HKLM:\SOFTWARE\ODBC\ODBC.INI')
        [void]$odbcHives.Add('HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBC.INI')
        Get-ChildItem -LiteralPath 'HKU:\' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'S-1-5-21' -and $_.Name -notmatch '_Classes$' } |
            ForEach-Object {
                $userHive = $_.PSPath.Replace('Microsoft.PowerShell.Core\Registry::', 'Registry::')
                [void]$odbcHives.Add(($userHive + '\SOFTWARE\ODBC\ODBC.INI'))
            }
        $dsnCount = 0
        $lines = @()
        foreach ($hive in $odbcHives) {
            $sourcesKey = Join-Path $hive 'ODBC Data Sources'
            if (-not (Test-Path -LiteralPath $sourcesKey)) { continue }
            $sk = Get-Item -LiteralPath $sourcesKey
            foreach ($dsn in $sk.GetValueNames()) {
                $dsnCount++
                $driver  = $sk.GetValue($dsn)
                $detail  = Get-ItemProperty -LiteralPath (Join-Path $hive $dsn) -ErrorAction SilentlyContinue
                $server = $null; $database = $null; $trusted = $null
                if ($detail) {
                    foreach ($c in @('Server', 'ServerName', 'CommLinks')) {
                        if (-not $server -and $detail.$c) { $server = $detail.$c }
                    }
                    foreach ($c in @('Database', 'DatabaseName')) {
                        if (-not $database -and $detail.$c) { $database = $detail.$c }
                    }
                    $trusted = $detail.Trusted_Connection
                }
                $lines += ('  DSN {0,-26} driver={1,-32} server={2,-22} db={3} trusted={4}' -f $dsn, $driver, $server, $database, $trusted)
                Add-RefHost $server
                if ($trusted -eq 'Yes') {
                    Add-Flag ("ODBC DSN '" + $dsn + "' uses Trusted_Connection (Windows auth) - the calling identity changes at domain join")
                }
            }
        }
        Add-DetailList -Items $lines -Label 'DSN'
        if ($dsnCount -eq 0) { Add-Detail '  (no DSNs found)' }
        Add-Detail '  NOTE: per-user DSNs are visible only while that user hive is loaded. Re-run during business hours if any are expected.'
    }

    # =======================================================================
    # SCHEDULED TASKS
    # =======================================================================
    Invoke-AuditSection -Name 'Scheduled Tasks with Non-System Principals' -Body {
        $systemPrincipals = '^(SYSTEM|LOCAL SERVICE|NETWORK SERVICE|S-1-5-18|S-1-5-19|S-1-5-20|Users|Administrators|INTERACTIVE|Authenticated Users)$'
        $taskCount = 0
        $lines = @()
        Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } | ForEach-Object {
            $principal = $_.Principal
            if ($principal.UserId -and $principal.UserId -notmatch $systemPrincipals) {
                $taskCount++
                $lines += ('  {0,-50} RunAs={1,-26} LogonType={2,-14} State={3}' -f `
                    ($_.TaskPath + $_.TaskName), $principal.UserId, $principal.LogonType, $_.State)
                if ($principal.LogonType -eq 'Password') {
                    Add-Flag ('Scheduled task ' + $_.TaskName + ' stores a password for ' + $principal.UserId + ' - must be re-created post-join')
                }
            }
        }
        Add-DetailList -Items $lines -Label 'task'
        if ($taskCount -eq 0) { Add-Detail '  (none)' }
    }

    # =======================================================================
    # MAPPED DRIVES
    # =======================================================================
    Invoke-AuditSection -Name 'Persistent Mapped Drives  (per loaded user hive)' -Body {
        $mapCount = 0
        $lines = @()
        Get-ChildItem -LiteralPath 'HKU:\' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'S-1-5-21' -and $_.Name -notmatch '_Classes$' } |
            ForEach-Object {
                $sid        = Split-Path $_.Name -Leaf
                $networkKey = $_.PSPath.Replace('Microsoft.PowerShell.Core\Registry::', 'Registry::') + '\Network'
                if (Test-Path -LiteralPath $networkKey) {
                    $who = $sid
                    try {
                        $who = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value
                    } catch {
                        Write-Verbose ('SID translate failed: ' + $_.Exception.Message)
                    }
                    Get-ChildItem -LiteralPath $networkKey -ErrorAction SilentlyContinue | ForEach-Object {
                        $mapCount++
                        $remotePath = (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).RemotePath
                        $lines += ('  {0,-30} {1}: -> {2}' -f $who, (Split-Path $_.Name -Leaf), $remotePath)
                        if ($remotePath -match '^\\\\([^\\]+)\\') { Add-RefHost $Matches[1] }
                    }
                }
            }
        Add-DetailList -Items $lines -Label 'mapping'
        if ($mapCount -eq 0) { Add-Detail '  (none found in loaded hives)' }
    }

    # =======================================================================
    # PRINTERS
    # =======================================================================
    Invoke-AuditSection -Name 'Printers / Ports' -Body {
        $lines = @()
        Get-Printer -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
            $lines += ('  {0,-34} Shared={1,-6} Port={2,-28} Driver={3}' -f $_.Name, $_.Shared, $_.PortName, $_.DriverName)
            if ($_.PortName -match '^\\\\([^\\]+)\\') { Add-RefHost $Matches[1] }
            if ($_.Shared) { Add-Flag ('Printer ' + $_.Name + ' is shared from this host - re-deploy via GPO after join') }
        }
        Add-DetailList -Items $lines -Label 'printer'
        if ($lines.Count -eq 0) { Add-Detail '  (none)' }
    }

    # =======================================================================
    # SMB / NTLM POSTURE
    # =======================================================================
    Invoke-AuditSection -Name 'SMB / NTLM Posture' -Body {
        $lsaKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
        Add-DetailKv 'LmCompatibilityLevel' (Get-RegValue -Path $lsaKey -Name 'LmCompatibilityLevel')
        Add-DetailKv 'RestrictSendingNTLM'  (Get-RegValue -Path "$lsaKey\MSV1_0" -Name 'RestrictSendingNTLMTraffic')
        Add-DetailKv 'NoLmHash'             (Get-RegValue -Path $lsaKey -Name 'NoLmHash')
        $smbServer = Get-SmbServerConfiguration -ErrorAction SilentlyContinue
        if ($smbServer) {
            Add-DetailKv 'SMB1 enabled (server)' $smbServer.EnableSMB1Protocol
            Add-DetailKv 'SMB2 enabled (server)' $smbServer.EnableSMB2Protocol
            Add-DetailKv 'Server sign required'  $smbServer.RequireSecuritySignature
            if ($smbServer.EnableSMB1Protocol) {
                Add-Flag 'SMB1 is ENABLED on the server side - remediate before or during the domain build'
            }
        }
        $smbClient = Get-SmbClientConfiguration -ErrorAction SilentlyContinue
        if ($smbClient) { Add-DetailKv 'Client sign required' $smbClient.RequireSecuritySignature }
        Add-Detail '  NOTE: Get-SmbClientConfiguration does NOT surface LmCompatibilityLevel. The LSA value above is authoritative.'
    }

    # =======================================================================
    # FIREWALL PROFILES
    # =======================================================================
    Invoke-AuditSection -Name 'Windows Firewall  (domain join activates the Domain profile)' -Body {
        Get-NetFirewallProfile -ErrorAction SilentlyContinue | ForEach-Object {
            Add-Detail ('  {0,-10} Enabled={1,-6} InboundDefault={2,-6} OutboundDefault={3}' -f `
                $_.Name, $_.Enabled, $_.DefaultInboundAction, $_.DefaultOutboundAction)
        }
        $inboundRules = @(Get-NetFirewallRule -Direction Inbound -Enabled True -ErrorAction SilentlyContinue)
        $counts = @{}
        foreach ($profileName in @('Domain', 'Private', 'Public')) {
            $counts[$profileName] = @($inboundRules | Where-Object { $_.Profile -match $profileName -or $_.Profile -eq 'Any' }).Count
            Add-DetailKv ("Enabled inbound ($profileName)") $counts[$profileName]
        }
        $privateOnly = @($inboundRules | Where-Object { $_.Profile -eq 'Private' })
        Add-DetailKv 'Private-only rules' $privateOnly.Count
        if ($privateOnly.Count -gt 0) {
            Add-Detail '  --- rules scoped to Private only; these go inert at domain join and are the phase-C worklist ---'
            $ruleLines = @($privateOnly | Sort-Object DisplayName | ForEach-Object { '  private-only : ' + $_.DisplayName })
            Add-DetailList -Items $ruleLines -Label 'rule'
            Add-Flag ($privateOnly.Count.ToString() + ' inbound firewall rule(s) are scoped to the Private profile only - they go inert at domain join. Re-scope BEFORE any post-join application test.')
        }
        Add-DetailKv 'Current active profile' ((Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -First 1).NetworkCategory)
    }

    # =======================================================================
    # REMOTE ACCESS SURFACE
    # =======================================================================
    Invoke-AuditSection -Name 'Remote Access Surface  (remote sign-in changes at cutover)' -Body {
        $tsKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $rdpTcp = "$tsKey\WinStations\RDP-Tcp"
        $denyTs = Get-RegValue -Path $tsKey -Name 'fDenyTSConnections'
        $rdpOn  = ($denyTs -eq 0)
        Add-DetailKv 'RDP enabled'       $(if ($rdpOn) { 'Yes' } elseif ($null -eq $denyTs) { 'unknown' } else { 'No' })
        Add-DetailKv 'RDP listener port' (Get-RegValue -Path $rdpTcp -Name 'PortNumber')
        Add-DetailKv 'NLA required'      (Get-RegValue -Path $rdpTcp -Name 'UserAuthentication')
        Add-DetailKv 'Security layer'    (Get-RegValue -Path $rdpTcp -Name 'SecurityLayer')

        $vpnPattern = 'OpenVPN|WireGuard|FortiClient|GlobalProtect|AnyConnect|Cisco VPN|SonicWall|NetExtender|Pulse Secure|Ivanti|ZeroTier|Tailscale|Meraki|WatchGuard|SoftEther|Barracuda|Splashtop|TeamViewer|ScreenConnect|AnyDesk|LogMeIn'
        $vpnLines = @()
        foreach ($uninstallRoot in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
            if (-not (Test-Path -LiteralPath $uninstallRoot)) { continue }
            Get-ChildItem -LiteralPath $uninstallRoot -ErrorAction SilentlyContinue | ForEach-Object {
                $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                if ($props -and $props.DisplayName -and $props.DisplayName -match $vpnPattern) {
                    $vpnLines += ('  remote-client : {0,-44} v{1}' -f $props.DisplayName, $props.DisplayVersion)
                }
            }
        }
        Add-DetailList -Items ($vpnLines | Sort-Object -Unique) -Label 'client'
        if ($vpnLines.Count -eq 0) { Add-Detail '  remote-client : (none detected in uninstall registry)' }

        # Saved credentials and saved connection files, per profile. Counts only -
        # no credential is read, decrypted or emitted.
        $credLines  = @()
        $credTotal  = 0
        $rdpTotal   = 0
        foreach ($p in (Get-CimInstance -ClassName Win32_UserProfile | Where-Object { -not $_.Special })) {
            if (-not $p.LocalPath -or -not (Test-Path -LiteralPath $p.LocalPath)) { continue }
            $who = $p.SID
            try {
                $who = (New-Object System.Security.Principal.SecurityIdentifier($p.SID)).Translate([System.Security.Principal.NTAccount]).Value
            } catch {
                Write-Verbose ('SID translate failed: ' + $_.Exception.Message)
            }
            $credCount = 0
            foreach ($credPath in @(
                (Join-Path $p.LocalPath 'AppData\Roaming\Microsoft\Credentials'),
                (Join-Path $p.LocalPath 'AppData\Local\Microsoft\Credentials')
            )) {
                if (Test-Path -LiteralPath $credPath) {
                    $credCount += @(Get-ChildItem -LiteralPath $credPath -Force -File -ErrorAction SilentlyContinue).Count
                }
            }
            $rdpCount = @(Get-ChildItem -LiteralPath $p.LocalPath -Filter '*.rdp' -Recurse -Force -File -Depth 3 -ErrorAction SilentlyContinue).Count
            if ($credCount -gt 0 -or $rdpCount -gt 0) {
                $credLines += ('  {0,-32} saved-credentials={1,-4} rdp-files={2}' -f $who, $credCount, $rdpCount)
                $credTotal += $credCount
                $rdpTotal  += $rdpCount
            }
        }
        Add-Detail ''
        Add-Detail '  --- saved credentials and connection files (counts only; nothing is read) ---'
        Add-DetailList -Items $credLines -Label 'profile'
        if ($credLines.Count -eq 0) { Add-Detail '  (none found)' }
        Add-DetailKv 'Saved credentials total' $credTotal
        Add-DetailKv 'Saved .rdp files total'  $rdpTotal

        if ($credTotal -gt 0 -or $rdpTotal -gt 0) {
            Add-Flag ("Saved credentials ($credTotal) and/or saved .rdp files ($rdpTotal) exist on this host - stale entries produce a sign-in failure after cutover that looks like an outage. Clear as part of the remote-user follow-up.")
        }
        Register-Checklist -Id 'CL-2.4-D' -Status 'CAPTURED' -Value ("saved credentials=$credTotal ; saved .rdp files=$rdpTotal across $($credLines.Count) profile(s)")

        # Remote user candidate list.
        $rdpMembers = @()
        if (Get-Variable -Name RdpGroupMembers -Scope Script -ErrorAction SilentlyContinue) {
            $rdpMembers = @($script:RdpGroupMembers)
        }
        if ($rdpOn) {
            Add-Flag 'RDP is enabled on this host - every remote user sign-in name changes at domain join. Advance notice and an assisted first sign-in are required.'
            Register-Checklist -Id 'CL-2.4-A' -Status 'PARTIAL' -Value ('RDP enabled. Remote Desktop Users members: ' + $(if ($rdpMembers.Count -gt 0) { $rdpMembers -join ', ' } else { '(none listed - access may be via Administrators)' }) + '. Confirm the definitive named list with the practice.')
        } else {
            Register-Checklist -Id 'CL-2.4-A' -Status 'CAPTURED' -Value 'RDP not enabled on this host'
        }
    }

    # =======================================================================
    # RDS CONFIGURATION
    # =======================================================================
    if ($isRDSH) {
        Invoke-AuditSection -Name 'RDS Configuration' -Body {
            $tsKey        = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
            $licCoreKey   = "$tsKey\RCM\Licensing Core"
            $licPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
            $licensingMode = Get-RegValue -Path $licCoreKey -Name 'LicensingMode'
            $licensingText = switch ($licensingMode) {
                2       { 'Per Device' }
                4       { 'Per User' }
                5       { 'Not configured' }
                default { 'not set / grace period' }
            }
            Add-DetailKv 'Licensing mode'       ('{0}   (raw={1})' -f $licensingText, $licensingMode)
            Add-DetailKv 'LicenseServers (GPO)' (Get-RegValue -Path $licPolicyKey -Name 'LicenseServers')
            Add-DetailKv 'LicensingMode (GPO)'  (Get-RegValue -Path $licPolicyKey -Name 'LicensingMode')
            try {
                $tsSetting = Get-CimInstance -Namespace 'root/cimv2/TerminalServices' -ClassName Win32_TerminalServiceSetting -ErrorAction Stop
                Add-DetailKv 'WMI LicensingType' $tsSetting.LicensingType
                Add-DetailKv 'WMI LicensingName' $tsSetting.LicensingName
            } catch {
                Write-Verbose ('TerminalServices WMI unavailable: ' + $_.Exception.Message)
            }
            $inGrace = Test-Path -LiteralPath "$tsKey\RCM\GracePeriod"
            Add-DetailKv 'Grace period key present' $inGrace
            if ($inGrace) {
                Add-Flag 'RDS GracePeriod key present - the session host is running on the licensing grace clock, not on licensed CALs'
            }
            if ($licensingMode -ne 2 -and $licensingMode -ne 4) {
                Add-Flag 'RDS licensing mode is NOT configured. Per-User CALs require a directory; a workgroup host can only run Per-Device.'
            }
            if ($licensingMode -eq 4 -and -not $cs.PartOfDomain) {
                Add-Flag 'RDS is set to Per-User while in a WORKGROUP - unsupported. Per-User CAL tracking requires a directory.'
            }
            $sessionLines = @(& quser.exe 2>$null | Select-Object -Skip 1)
            Add-DetailKv 'Active sessions' $sessionLines.Count
            Register-Checklist -Id 'CL-2.5-C' -Status 'PARTIAL' -Value ("mode=$licensingText ; grace key present=$inGrace ; active sessions=$($sessionLines.Count). CAL ownership and count still require the licensing record.")
        }
    } else {
        Register-Checklist -Id 'CL-2.5-C' -Status 'N/A' -Value 'Not an RD Session Host'
    }

    # =======================================================================
    # HYPER-V INVENTORY + LICENSING ENTITLEMENT
    # =======================================================================
    if ($isHyperV) {
        Invoke-AuditSection -Name 'Hyper-V Inventory and Licensing Entitlement' -Body {
            $vms = @()
            try { $vms = @(Get-VM -ErrorAction Stop) } catch {
                Write-Verbose ('Hyper-V module unavailable: ' + $_.Exception.Message)
                Add-Detail '  (Hyper-V module unavailable)'
                return
            }
            $totalAssigned = 0
            foreach ($vm in ($vms | Sort-Object Name)) {
                $assignedGb = [math]::Round(($vm.MemoryAssigned / 1GB), 1)
                $totalAssigned += $assignedGb
                Add-Detail ('  {0,-18} State={1,-9} Gen={2} vCPU={3,-3} RAMassigned={4,-6} GB  Startup={5} GB  Dynamic={6}  Version={7}' -f `
                    $vm.Name, $vm.State, $vm.Generation, $vm.ProcessorCount, $assignedGb, `
                    [math]::Round(($vm.MemoryStartup / 1GB), 1), $vm.DynamicMemoryEnabled, $vm.Version)
            }
            $physicalGb  = [math]::Round(($cs.TotalPhysicalMemory / 1GB), 1)
            $headroomGb  = [math]::Round(($physicalGb - $totalAssigned), 1)
            $logicalCpu  = $cs.NumberOfLogicalProcessors
            $assignedCpu = ($vms | Measure-Object -Property ProcessorCount -Sum).Sum

            Add-Detail ''
            Add-DetailKv 'Host physical RAM'    ("$physicalGb GB")
            Add-DetailKv 'Sum assigned to VMs'  ("$totalAssigned GB")
            Add-DetailKv 'Nominal RAM headroom' ("$headroomGb GB")
            Add-DetailKv 'Logical processors'   $logicalCpu
            Add-DetailKv 'vCPU assigned total'  $assignedCpu

            if ($assignedCpu -ge $logicalCpu) {
                Add-Flag ("vCPU is already at or over subscription ($assignedCpu assigned against $logicalCpu logical) - adding a controller guest increases contention")
            }
            if ($headroomGb -lt 8) {
                Add-Flag ("RAM headroom is $headroomGb GB - a controller guest needs 4-8 GB. Confirm the fit before committing to an on-host controller.")
            }

            Register-Checklist -Id 'CL-1.2-C' -Status 'CAPTURED' -Value (($vms | ForEach-Object { '{0}({1}GB/{2}vCPU,{3})' -f $_.Name, [math]::Round(($_.MemoryAssigned / 1GB), 1), $_.ProcessorCount, $_.State }) -join ' ')
            Register-Checklist -Id 'CL-1.2-D' -Status 'CAPTURED' -Value ("RAM headroom $headroomGb GB of $physicalGb GB ; vCPU $assignedCpu assigned of $logicalCpu logical")

            # Licensing entitlement math.
            $hostEdition  = $os.Caption
            $isStandard   = $hostEdition -match 'Standard'
            $isDatacenter = $hostEdition -match 'Datacenter'
            $guestCount   = $vms.Count
            if ($isDatacenter) {
                $verdict = "Host is Datacenter - unlimited guest environments. No additional licence required for a controller guest."
            } elseif ($isStandard) {
                if ($guestCount -ge 2) {
                    $verdict = "Host is Standard: 2 guest environments entitled, $guestCount in use. A controller guest is number $($guestCount + 1) and REQUIRES an additional Server Standard licence or Datacenter conversion. Automatic guest activation is unavailable on Standard, so each guest needs its own key."
                    Add-Flag 'LICENSING: Standard host with both guest entitlements consumed. A controller guest requires an additional Server Standard licence or Datacenter conversion. Mandatory quote line.'
                } else {
                    $verdict = "Host is Standard: 2 guest environments entitled, $guestCount in use. A controller guest fits within the existing entitlement, but needs its own product key - automatic guest activation is unavailable on Standard."
                }
            } else {
                $verdict = "Host edition '$hostEdition' - entitlement not determined automatically. Verify manually."
            }
            Add-Detail ''
            Add-Detail ('  ENTITLEMENT: ' + $verdict)
            Register-Checklist -Id 'CL-1.3-C' -Status 'CAPTURED' -Value $verdict

            Get-VMSwitch -ErrorAction SilentlyContinue | ForEach-Object {
                Add-Detail ('  vswitch {0,-20} Type={1}  EmbeddedTeaming={2}  AllowMgmtOS={3}' -f `
                    $_.Name, $_.SwitchType, $_.EmbeddedTeamingEnabled, $_.AllowManagementOS)
            }
        }
    } else {
        Register-Checklist -Id 'CL-1.2-C' -Status 'N/A' -Value 'Not a virtualisation host'
        Register-Checklist -Id 'CL-1.2-D' -Status 'N/A' -Value 'Not a virtualisation host'
        Register-Checklist -Id 'CL-1.3-C' -Status 'N/A' -Value 'Not a virtualisation host'
    }

    # =======================================================================
    # ACTIVATION
    # =======================================================================
    Invoke-AuditSection -Name 'Windows Activation' -Body {
        Get-CimInstance -ClassName SoftwareLicensingProduct -Filter 'PartialProductKey IS NOT NULL' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'Windows*' } | ForEach-Object {
                $status = switch ($_.LicenseStatus) {
                    0 { 'Unlicensed' } 1 { 'Licensed' } 2 { 'OOB Grace' } 3 { 'OOT Grace' }
                    4 { 'Non-Genuine Grace' } 5 { 'Notification' } 6 { 'Extended Grace' }
                    default { 'unknown' }
                }
                Add-Detail ('  {0}' -f $_.Name)
                Add-Detail ('       Status={0}  Channel={1}  KeyLast5={2}' -f $status, $_.ProductKeyChannel, $_.PartialProductKey)
            }
    }

    # =======================================================================
    # TIME SOURCE
    # =======================================================================
    Invoke-AuditSection -Name 'Time Source' -Body {
        $w32TimeParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
        Add-DetailKv 'w32tm /query /source' (& w32tm.exe /query /source 2>&1)
        Add-DetailKv 'NtpServer'            (Get-RegValue -Path $w32TimeParams -Name 'NtpServer')
        Add-DetailKv 'Type'                 (Get-RegValue -Path $w32TimeParams -Name 'Type')
        Add-DetailKv 'Local time'           (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
    }

    # =======================================================================
    # REFERENCED HOSTNAME RESOLUTION
    # =======================================================================
    Invoke-AuditSection -Name 'Referenced Hostnames - Resolution Test' -Body {
        if ($script:RefHosts.Count -eq 0) {
            Add-Detail '  (no external hostnames referenced by shares, DSNs, drives, printers or services)'
            return
        }
        foreach ($refHost in ($script:RefHosts | Sort-Object)) {
            $resolved = 'FAILED'
            try {
                $record = Resolve-DnsName -Name $refHost -Type A -ErrorAction Stop |
                          Where-Object { $_.IPAddress } | Select-Object -First 1
                if ($record) { $resolved = $record.IPAddress }
            } catch {
                Write-Verbose ("Resolve $refHost : " + $_.Exception.Message)
            }
            Add-Detail ('  {0,-24} -> {1}' -f $refHost, $resolved)
            if ($resolved -eq 'FAILED') {
                Add-Flag ("Referenced host '" + $refHost + "' does not resolve via DNS - currently depends on NetBIOS or WINS and will behave differently after AD DNS cutover")
            }
        }
    }

    # =======================================================================
    # OPTIONAL STATE CAPTURE
    # =======================================================================
    if ($DoCapture) {
        Invoke-AuditSection -Name 'State Capture  (rollback reference exports)' -Body {
            $stamp = '{0}-{1}' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss')
            $captured = @()

            $fwFile = Join-Path $CaptureDir "firewall-$stamp.wfw"
            try {
                & netsh.exe advfirewall export "$fwFile" | Out-Null
                Add-Detail ('  firewall export : ' + $fwFile)
                $captured += 'firewall'
            } catch {
                Write-Verbose ('Firewall export failed: ' + $_.Exception.Message)
                Add-Detail '  firewall export : FAILED'
            }

            foreach ($pair in @(
                @{ Key = 'HKLM\SOFTWARE\ODBC\ODBC.INI';             File = "odbc-64-$stamp.reg" },
                @{ Key = 'HKLM\SOFTWARE\WOW6432Node\ODBC\ODBC.INI'; File = "odbc-32-$stamp.reg" }
            )) {
                $target = Join-Path $CaptureDir $pair.File
                try {
                    & reg.exe export $pair.Key "$target" /y | Out-Null
                    Add-Detail ('  odbc export     : ' + $target)
                    $captured += 'odbc'
                } catch {
                    Write-Verbose ('ODBC export failed: ' + $_.Exception.Message)
                    Add-Detail ('  odbc export     : FAILED (' + $pair.Key + ')')
                }
            }

            if ($script:AclDump.Count -gt 0) {
                $aclFile = Join-Path $CaptureDir "share-acl-$stamp.txt"
                try {
                    $script:AclDump | Set-Content -LiteralPath $aclFile -Encoding UTF8
                    Add-Detail ('  share ACL dump  : ' + $aclFile)
                    $captured += 'share-acl'
                } catch {
                    Write-Verbose ('ACL dump failed: ' + $_.Exception.Message)
                    Add-Detail '  share ACL dump  : FAILED'
                }
            }
            Register-Checklist -Id 'CL-2.3-ALL' -Status 'CAPTURED' -Value (($captured | Sort-Object -Unique) -join ', ')
        }
    } else {
        Register-Checklist -Id 'CL-2.3-ALL' -Status 'OPEN' -Value 'Capture mode off - set DTC_CaptureDir and re-run immediately before the join to produce the rollback reference'
    }

    # =======================================================================
    # ITEMS THIS SCRIPT CANNOT ANSWER
    # =======================================================================
    Register-Checklist -Id 'CL-1.3-A' -Status 'OPEN' -Value 'Domain name - engineering and architecture decision'
    Register-Checklist -Id 'CL-1.3-B' -Status 'OPEN' -Value 'Network re-addressing - engineering and architecture decision'
    Register-Checklist -Id 'CL-1.3-E' -Status 'OPEN' -Value 'Server rename in or out of scope - default position is OUT'
    Register-Checklist -Id 'CL-1.3-F' -Status 'OPEN' -Value 'Site device count for CAL sizing - from the RMM device list, not this host'
    Register-Checklist -Id 'CL-1.3-G' -Status 'OPEN' -Value 'Staff working across multiple sites - account manager and client'
    Register-Checklist -Id 'CL-2.1-C' -Status 'OPEN' -Value 'Backup job health and restore point - from the backup console'
    Register-Checklist -Id 'CL-2.1-D' -Status 'OPEN' -Value 'Verified test restore - must be performed, not queried'
    Register-Checklist -Id 'CL-2.2-C' -Status 'OPEN' -Value 'Site-to-site tunnel and peer overlap - from the network controller'
    Register-Checklist -Id 'CL-2.2-E' -Status 'OPEN' -Value 'Cloud tenant identity boundary - engineering and cloud lead decision'
    Register-Checklist -Id 'CL-2.2-F' -Status 'OPEN' -Value 'Non-server inventory - from the RMM and gateway client list'
    Register-Checklist -Id 'CL-2.4-B' -Status 'OPEN' -Value 'How each remote user connects, and whether tunnel credentials are separate - confirm with the practice'
    Register-Checklist -Id 'CL-2.4-E' -Status 'OPEN' -Value 'Advance written notice to remote users - account manager'
    Register-Checklist -Id 'CL-2.4-F' -Status 'OPEN' -Value 'Follow-up assisted sign-in engagement - raise once a cutover date exists'
    Register-Checklist -Id 'CL-2.5-A' -Status 'OPEN' -Value 'Operating hours and no-touch dates - account manager and client'
    Register-Checklist -Id 'CL-2.5-B' -Status 'OPEN' -Value 'Window count and shape - dispatch, against the execution sequence'

    # CL-2.1-B is gated on the virtualisation classification: a guest has no BMC.
    if ($isVirtualGuest) {
        Register-Checklist -Id 'CL-2.1-B' -Status 'N/A' -Value 'Virtual guest - no out-of-band management controller; applies to the virtualisation host'
    } else {
        Register-Checklist -Id 'CL-2.1-B' -Status 'OPEN' -Value 'Remote management controller reachability and licence - confirm in the controller interface'
    }

    if ($script:Flags.Count -gt 0) { $script:ExitCode = 2 }

    # =======================================================================
    # EMIT: banner, checklist, flags, detail, terminator
    # =======================================================================
    $out = New-Object System.Collections.ArrayList

    [void]$out.Add('========================================================================')
    [void]$out.Add(' WORKGROUP -> DOMAIN READINESS AUDIT  (read-only)')
    [void]$out.Add((' Client   : ' + $ClientLabel))
    [void]$out.Add((' Host     : ' + $env:COMPUTERNAME))
    [void]$out.Add((' Role     : ' + $roleText))
    [void]$out.Add((' Platform : ' + $virtPlatform))
    [void]$out.Add((' Ticket   : ' + $TicketLabel))
    [void]$out.Add((' Run      : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    [void]$out.Add((' Version  : ' + $ScriptVersion))
    [void]$out.Add((' Flags    : ' + $script:Flags.Count))
    [void]$out.Add((' Exit     : ' + $script:ExitCode))
    if ($DoCapture) { [void]$out.Add((' Capture  : ' + $CaptureDir)) }

    # Reserve the slot for the line count. The total cannot be known until the
    # whole report is assembled, and the placeholder must occupy a real slot so
    # that the count it eventually reports is correct. Remember the index rather
    # than inserting at a fixed position later - capture mode adds a banner row
    # and shifts everything below it.
    $lineCountIndex = $out.Count
    [void]$out.Add('<<LINECOUNT>>')

    [void]$out.Add('========================================================================')
    [void]$out.Add('')
    [void]$out.Add('== CHECKLIST AUTO-FILL  (transcribe these onto the site checklist) ==')
    [void]$out.Add('')
    foreach ($item in ($script:Checklist | Sort-Object Id)) {
        [void]$out.Add(('  {0,-12} {1,-9} {2}' -f $item.Id, $item.Status, $item.Value))
    }
    [void]$out.Add('')
    [void]$out.Add('== MIGRATION FLAGS ==')
    [void]$out.Add('')
    if ($script:Flags.Count -eq 0) {
        [void]$out.Add('  (no flags raised)')
    } else {
        $i = 0
        foreach ($flag in $script:Flags) {
            $i++
            [void]$out.Add(('  [{0:D2}] {1}' -f $i, $flag))
        }
    }
    [void]$out.Add('')
    [void]$out.Add('========================================================================')
    [void]$out.Add(' FULL DETAIL BELOW')
    [void]$out.Add('========================================================================')
    foreach ($line in $script:Detail) { [void]$out.Add($line) }
    [void]$out.Add('')
    [void]$out.Add('========================================================================')
    [void]$out.Add((' END - ' + $env:COMPUTERNAME + ' - ' + $script:Flags.Count + ' flag(s) - exit ' + $script:ExitCode))
    [void]$out.Add('========================================================================')

    # +1 accounts for the completion token emitted after the list.
    $expected = $out.Count + 1
    $out[$lineCountIndex] = (' Lines    : ' + $expected + '   (if the log ends before the completion token, it was truncated)')

    foreach ($line in $out) { Write-Output $line }
    Write-Output $CompleteToken

} catch {
    Write-Output ''
    Write-Output '!! AUDIT ERROR - report is INCOMPLETE and must not be treated as authoritative'
    Write-Output ('!! ' + $_.Exception.Message)
    if ($_.InvocationInfo) {
        Write-Output ('!! at line ' + $_.InvocationInfo.ScriptLineNumber + ': ' + $_.InvocationInfo.Line.Trim())
    }
    Write-Output ''
    Write-Output '-- partial detail captured before the failure --'
    foreach ($line in $script:Detail) { Write-Output $line }
    $script:ExitCode = 1
    Write-Output $CompleteToken
} finally {
    if ($script:MutexHeld -and $script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch { Write-Verbose ('Mutex release: ' + $_.Exception.Message) }
        $script:Mutex.Dispose()
    }
    if ($script:Transcribing) {
        try { Stop-Transcript | Out-Null } catch { Write-Verbose ('Stop-Transcript: ' + $_.Exception.Message) }
    }
}

exit $script:ExitCode