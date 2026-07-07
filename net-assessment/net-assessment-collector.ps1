## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM           - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description   - Optional; transcript-only audit note (never appears in report output)
## $env:RMMScriptPath - Optional log directory base provided by the RMM
##
## Per-script variables:
## $env:WriteFiles    - "1" (default) writes hostname-suffixed artifacts to OutputPath (creates the
##                      folder if missing) AND streams the report to stdout. "0" = stdout only.
## $env:OutputPath    - Artifact output directory (default: "C:\DTC" per NA SOP 5.2)
## $env:CollectDomain - "auto" (default: AD data only when running on a DC), "1" force domain-wide
##                      collection from ANY domain-joined machine (uses RSAT if present, otherwise
##                      native ADSI - no installs needed), "0" skip even on a DC
## $env:SubnetSweep   - "1" to ping-sweep the primary /24 for non-AD device discovery (default: off)
##                      Run the sweep from ONE machine per site only.
## $env:StaleDays     - Inactivity threshold in days for stale AD objects (default: "90")
## $env:WanLookup     - "1" (default) to resolve WAN IP/ISP via one HTTPS call to ipinfo.io; "0" to skip

<#
.SYNOPSIS
    Read-only, role-aware, zero-interaction network assessment collector (NA SOP 5.2).
.DESCRIPTION
    Runs on any machine in the prospect environment with NO prompts in any context
    and adapts to its role:

      PRIMARY DC (run once, required)  - full collection including domain-wide AD.
      ADDITIONAL SERVERS               - per-machine sections; AD skipped by default.
      WORKSTATIONS                     - per-machine sections plus feature release,
        pre-22H2 flagging, and slmgr /xpr activation/ESU capture.
      NO SERVER ACCESS                 - set CollectDomain=1 on any domain-joined
        workstation: domain-wide AD data is collected via RSAT if present, otherwise
        via native ADSI/DirectorySearcher (no installs). ADSI limits: computer IPv4
        not available (AD does not store it) and Domain Admins listed as direct
        members only (nested groups shown but not expanded).

    Report header is "NETWORK ASSESSMENT - <DOMAIN>" (WORKGROUP when not joined).
    Default behavior writes hostname-suffixed artifacts to OutputPath (creating the
    folder if missing) AND streams the full report to stdout for the NinjaOne
    activity log: na-report-<HOST>.txt, installed-programs-<HOST>.csv,
    services-<HOST>.csv, ipconfig-<HOST>.txt, ad-computers-<HOST>.csv,
    subnet-sweep-<HOST>.csv. Set WriteFiles=0 for activity-log-only runs.

    Evaluates the DTC standards gap table (NA SOP Section 6) inline and prints a
    GAP FLAGS section mapping deviations to SoW line items. Pre-fills the Environment
    Snapshot of the Network Assessment Review template (KB 3333).

    Does NOT replace: firewall/switch/VLAN capture, WiFi survey, speed test, M365
    tenant review, physical hardware walk, or Network Detective. Manual per SOP.
    Makes NO changes to the system.
.EXAMPLE
    .\net-assessment-collector.ps1
    # Runs immediately with defaults - no prompts. Artifacts in C:\DTC.
.EXAMPLE
    # Workstation-only engagement (no server access):
    $env:CollectDomain = "1"; .\net-assessment-collector.ps1
.NOTES
    Author: Zach Boogher
    Repo:   msp-script-library/net-assessment/net-assessment-collector.ps1
    Standards: KB 1536 (NA SOP v3.1), KB 3333 (NA Review template), KB 3299 (PowerShell patterns)
    Read-only; inherently idempotent. PowerShell 5.1 compatible. Degrades gracefully
    on workgroup machines (AD sections report NOT DOMAIN-JOINED).
#>

$ScriptLogName = "net-assessment-collector.log"

# --- Default optional RMM environment variables --------------------------

if ([string]::IsNullOrEmpty($env:OutputPath))    { $env:OutputPath    = "C:\DTC" }
if ([string]::IsNullOrEmpty($env:WriteFiles))    { $env:WriteFiles    = "1" }
if ([string]::IsNullOrEmpty($env:StaleDays))     { $env:StaleDays     = "90" }
if ([string]::IsNullOrEmpty($env:WanLookup))     { $env:WanLookup     = "1" }
if ([string]::IsNullOrEmpty($env:CollectDomain)) { $env:CollectDomain = "auto" }

# --- Input handling -------------------------------------------------------
# Zero-interaction by design: no prompting in any execution context (KB 3299).
# $env:Description is transcript-only audit metadata per the repo template.

if ($env:RMM -eq "1" -and -not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
    $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"
}

if ([string]::IsNullOrEmpty($env:Description)) {
    $env:Description = "No Description"
}

$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    Write-Host "Creating log directory: $logDir"
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# --- Script logic --------------------------------------------------------

Start-Transcript -Path $LogPath

Write-Host "Description: $env:Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $env:RMM"
Write-Host "WriteFiles: $env:WriteFiles"

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$writeFiles = ($env:WriteFiles -eq "1")
if ($writeFiles -and -not (Test-Path -Path $env:OutputPath)) {
    Write-Host "Creating output directory: $env:OutputPath"
    New-Item -Path $env:OutputPath -ItemType Directory -Force | Out-Null
}

$staleDays = 90
[void][int]::TryParse($env:StaleDays, [ref]$staleDays)
if ($staleDays -le 0) { $staleDays = 90 }
$staleCutoff = (Get-Date).AddDays(-$staleDays)
$activeCutoff = (Get-Date).AddDays(-30)

$hostTag = $env:COMPUTERNAME
function Get-ArtifactPath { param([string]$BaseName, [string]$Extension)
    Join-Path $env:OutputPath ("{0}-{1}.{2}" -f $BaseName, $hostTag, $Extension)
}

# --- Role detection -------------------------------------------------------
# Win32_ComputerSystem.DomainRole: 0/1 = workstation, 2/3 = server, 4/5 = DC
$cs = Get-CimInstance -ClassName Win32_ComputerSystem
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$domainRole = [int]$cs.DomainRole
$isDc          = $domainRole -ge 4
$isServer      = $domainRole -ge 2
$isWorkstation = $domainRole -le 1
$roleText = switch ($domainRole) {
    0 { 'Standalone workstation' } 1 { 'Member workstation' }
    2 { 'Standalone server' }      3 { 'Member server' }
    4 { 'Domain controller (backup)' } 5 { 'Domain controller (primary)' }
    default { "Unknown (DomainRole=$domainRole)" }
}
$domainLabel = $cs.Domain
if ([string]::IsNullOrEmpty($domainLabel)) { $domainLabel = 'WORKGROUP' }

$collectAd = $false
if ($env:CollectDomain -eq "1")     { $collectAd = $true }
elseif ($env:CollectDomain -eq "0") { $collectAd = $false }
else                                 { $collectAd = $isDc }

$hasServerManager = [bool](Get-Command -Name Get-WindowsFeature -ErrorAction SilentlyContinue)

$lines = [System.Collections.Generic.List[string]]::new()
$gapFlags = [System.Collections.Generic.List[string]]::new()

function Add-GapFlag {
    param([string]$Severity, [string]$Category, [string]$Finding, [string]$SowImpact)
    $gapFlags.Add(("[{0}] {1} - {2}  => SoW: {3}" -f $Severity, $Category, $Finding, $SowImpact))
}

$lines.Add('========================================================================')
$lines.Add((" NETWORK ASSESSMENT - {0}   {1}" -f $domainLabel.ToUpper(), (Get-Date -Format 'yyyy-MM-dd HH:mm')))
$lines.Add((" Host   : {0}   Role: {1}" -f $env:COMPUTERNAME, $roleText))
$lines.Add((" Output : {0}" -f $(if ($writeFiles) { "activity log + artifact files in $env:OutputPath" } else { 'activity log only (WriteFiles=0)' })))
$lines.Add(' Scope  : NA SOP v3.1 (KB 1536) Section 5.2 A-G, role-aware, read-only.')
$lines.Add(' Run on : primary DC once (full), each additional server (per-machine),')
$lines.Add('          2-3 workstation spot-checks per SOP 5.2-D. No server access?')
$lines.Add('          Set CollectDomain=1 on any domain-joined machine for AD data.')
$lines.Add(' Manual : firewall/switch/VLAN, WiFi, speed test, M365 tenant, physical hardware,')
$lines.Add('          Network Detective - still required per SOP.')
$lines.Add('========================================================================')

# ----- A. NETWORK CONFIGURATION -----
$lines.Add('')
$lines.Add('== A. NETWORK CONFIGURATION ==')

if ($writeFiles) {
    ipconfig /all | Out-File -FilePath (Get-ArtifactPath 'ipconfig' 'txt') -Encoding utf8
}

$primaryGateway = $null
$dnsServersSeen = [System.Collections.Generic.List[string]]::new()
$primaryIp = $null
$primaryPrefix = $null
$publicDnsPattern = '^(8\.8\.8\.8|8\.8\.4\.4|1\.1\.1\.1|1\.0\.0\.1|9\.9\.9\.9|149\.112\.112\.112|208\.67\.222\.222|208\.67\.220\.220)$'

$adapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE'
foreach ($nic in $adapters) {
    $ipv4 = @($nic.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
    $gw   = @($nic.DefaultIPGateway | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
    $dns  = @($nic.DNSServerSearchOrder)
    $lines.Add(("Adapter         : {0}" -f $nic.Description))
    $lines.Add(("  IPv4          : {0}   Subnet: {1}" -f ($ipv4 -join ', '), (@($nic.IPSubnet) -join ', ')))
    $lines.Add(("  Gateway       : {0}" -f ($gw -join ', ')))
    $lines.Add(("  DNS servers   : {0}" -f ($dns -join ', ')))
    $lines.Add(("  DHCP enabled  : {0}" -f $nic.DHCPEnabled))
    if (-not $primaryGateway -and $gw.Count -gt 0) {
        $primaryGateway = $gw[0]
        $primaryIp = $ipv4 | Select-Object -First 1
        $idx = [array]::IndexOf(@($nic.IPAddress), $primaryIp)
        if ($idx -ge 0) { $primaryPrefix = @($nic.IPSubnet)[$idx] }
    }
    foreach ($d in $dns) { if ($d -and -not $dnsServersSeen.Contains($d)) { $dnsServersSeen.Add($d) } }
}

# Gap 1: public DNS on a domain-joined machine (any role) - breaks AD name resolution
# intermittently when the resolver rotates to the public server.
$publicDns = @($dnsServersSeen | Where-Object { $_ -match $publicDnsPattern })
if ($cs.PartOfDomain -and $publicDns.Count -gt 0) {
    Add-GapFlag -Severity 'REVIEW' -Category 'DNS' -Finding ("public DNS server(s) {0} configured on domain-joined {1} - intermittent AD resolution risk" -f ($publicDns -join ', '), $env:COMPUTERNAME) -SowImpact 'DNS reconfiguration (clients -> AD DNS only)'
}

# Gap 2: DTC standard = UDM gateway as sole DNS (NA SOP Section 6). DC-only evaluation -
# members pointing at the DC is correct config.
$nonStandardDns = @($dnsServersSeen | Where-Object { $_ -ne $primaryGateway -and $_ -ne '127.0.0.1' -and $_ -ne $primaryIp })
if ($nonStandardDns.Count -gt 0) {
    $lines.Add(("NOTE            : non-gateway DNS servers in use: {0}" -f ($nonStandardDns -join ', ')))
    if ($isDc) {
        Add-GapFlag -Severity 'REVIEW' -Category 'DNS' -Finding ("non-gateway DNS servers configured on DC: {0}" -f ($nonStandardDns -join ', ')) -SowImpact 'DNS reconfiguration'
    } else {
        $lines.Add('                  (domain members pointing at the DC/DNS server is expected - evaluate at the DC/gateway)')
    }
}

# WAN IP / ISP (single outbound HTTPS call; skip with WanLookup=0)
if ($env:WanLookup -eq "1") {
    try {
        $wan = Invoke-RestMethod -Uri 'https://ipinfo.io/json' -TimeoutSec 10
        $lines.Add(("WAN IP / ISP    : {0} / {1}" -f $wan.ip, $wan.org))
    } catch {
        $lines.Add('WAN IP / ISP    : lookup failed - capture manually (ipchicken.com per SOP)')
    }
} else {
    $lines.Add('WAN IP / ISP    : lookup skipped (WanLookup=0) - capture manually')
}
$lines.Add('WAN speed       : MANUAL - run fast.com per SOP 5.2-A (active test, not scripted)')

# DHCP role (server OS only - cmdlets absent on workstations)
if ($hasServerManager) {
    $dhcpRole = Get-WindowsFeature -Name 'DHCP' -ErrorAction SilentlyContinue
    if ($dhcpRole -and $dhcpRole.Installed -and (Get-Command -Name Get-DhcpServerv4Scope -ErrorAction SilentlyContinue)) {
        $lines.Add('DHCP            : server holds DHCP role. Scopes:')
        try {
            foreach ($scope in Get-DhcpServerv4Scope -ErrorAction Stop) {
                $lines.Add(("  {0}  {1}-{2}  mask {3}  state {4}" -f $scope.ScopeId, $scope.StartRange, $scope.EndRange, $scope.SubnetMask, $scope.State))
            }
        } catch {
            $lines.Add(("  scope enumeration failed: {0}" -f $_.Exception.Message))
        }
    } else {
        $lines.Add('DHCP            : role not on this server - assume gateway/UDM handles DHCP (verify at gateway)')
    }
} else {
    # Workstation: report the DHCP server that issued this lease (identifies the likely DC/gateway)
    $dhcpSrv = @($adapters | Where-Object { $_.DHCPServer } | Select-Object -ExpandProperty DHCPServer -Unique)
    if ($dhcpSrv.Count -gt 0) {
        $lines.Add(("DHCP            : workstation - lease issued by {0} (scope data lives there)" -f ($dhcpSrv -join ', ')))
    } else {
        $lines.Add('DHCP            : workstation - static IP or no DHCP server recorded')
    }
}

# DNS role forwarders
if (Get-Command -Name Get-DnsServerForwarder -ErrorAction SilentlyContinue) {
    try {
        $fwd = Get-DnsServerForwarder -ErrorAction Stop
        $lines.Add(("DNS forwarders  : {0}" -f (@($fwd.IPAddress.IPAddressToString) -join ', ')))
    } catch {
        $lines.Add('DNS forwarders  : DNS role tools present but query failed - capture manually')
    }
} else {
    $lines.Add('DNS forwarders  : DNS role not on this machine')
}

# ----- B. MACHINE PROFILE -----
$lines.Add('')
$lines.Add('== B. MACHINE PROFILE ==')
$cpu  = Get-CimInstance -ClassName Win32_Processor
$ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 0)
$lines.Add(("Manufacturer    : {0}   Model: {1}" -f $cs.Manufacturer, $cs.Model))
$lines.Add(("OS              : {0}  (build {1})" -f $os.Caption, $os.Version))
$lines.Add(("CPU             : {0}" -f (($cpu | Select-Object -First 1).Name).Trim()))
$lines.Add(("RAM             : {0} GB" -f $ramGB))

if ($isServer) {
    if ($hasServerManager) {
        $lines.Add(("Roles installed : {0}" -f ((Get-WindowsFeature -ErrorAction SilentlyContinue | Where-Object { $_.Installed -and $_.FeatureType -eq 'Role' } | Select-Object -ExpandProperty Name) -join ', ')))
    }
    if ($os.Caption -match 'Server (2008|2012|2016)') {
        Add-GapFlag -Severity 'HIGH' -Category 'Server OS' -Finding ("{0} on {1}" -f $os.Caption, $env:COMPUTERNAME) -SowImpact 'Server OS upgrade or replacement'
    }
    $lines.Add('Dell iDRAC/RAID : MANUAL if Dell - log into iDRAC per SOP 5.2-B (or run get-server-lifecycle-audit.ps1)')
}

if ($isWorkstation) {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $featureRelease = $cv.DisplayVersion
    if ([string]::IsNullOrEmpty($featureRelease)) { $featureRelease = $cv.ReleaseId }
    $lines.Add(("Feature release : {0}" -f $featureRelease))
    $isWin10 = ($os.Caption -match 'Windows 10') -and ([int]$cv.CurrentBuildNumber -lt 22000)
    if ($os.Caption -match 'Windows (7|8|8\.1)\b') {
        Add-GapFlag -Severity 'HIGH' -Category 'Workstation OS' -Finding ("{0} on {1}" -f $os.Caption, $env:COMPUTERNAME) -SowImpact 'Workstation OS upgrade or replacement'
    } elseif ($isWin10 -and $featureRelease -ne '22H2') {
        Add-GapFlag -Severity 'HIGH' -Category 'Workstation OS' -Finding ("Windows 10 {0} (pre-22H2) on {1}" -f $featureRelease, $env:COMPUTERNAME) -SowImpact 'Workstation OS upgrade or replacement'
    }
    if ($isWin10) {
        $xpr = (cscript //nologo "$env:WINDIR\System32\slmgr.vbs" /xpr 2>$null | Where-Object { $_ }) -join ' | '
        $lines.Add(("slmgr /xpr      : {0}" -f $xpr))
        $lines.Add('ESU             : Windows 10 in production - verify ESU licensing per SOP 5.2-D (post-Oct-2025 support gap if absent)')
        Add-GapFlag -Severity 'REVIEW' -Category 'Workstation OS' -Finding ("Windows 10 host {0} - confirm ESU or replacement plan" -f $env:COMPUTERNAME) -SowImpact 'ESU licensing or workstation replacement'
    }
    $lines.Add('Sensor drivers  : review INSTALLED SOFTWARE below for imaging/TWAIN entries not on the server (SOP 5.2-D)')
}

# Volumes + 80/90 thresholds (all roles)
foreach ($vol in Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3') {
    $sizeGB = [math]::Round($vol.Size / 1GB, 1)
    $freeGB = [math]::Round($vol.FreeSpace / 1GB, 1)
    $usedPct = 0
    if ($vol.Size -gt 0) { $usedPct = [math]::Round((($vol.Size - $vol.FreeSpace) / $vol.Size) * 100, 0) }
    $lines.Add(("Volume {0}       : {1} GB total, {2} GB free ({3}% used)" -f $vol.DeviceID, $sizeGB, $freeGB, $usedPct))
    if ($usedPct -gt 90)     { Add-GapFlag -Severity 'CRITICAL' -Category 'Disk Utilization' -Finding ("{0} {1} at {2}% used" -f $env:COMPUTERNAME, $vol.DeviceID, $usedPct) -SowImpact 'Disk cleanup or drive replacement' }
    elseif ($usedPct -gt 80) { Add-GapFlag -Severity 'WARNING'  -Category 'Disk Utilization' -Finding ("{0} {1} at {2}% used" -f $env:COMPUTERNAME, $vol.DeviceID, $usedPct) -SowImpact 'Disk cleanup or drive replacement' }
}

# C:\Windows\Installer size (server headline number; ref HALO 1125653)
if ($isServer) {
    $installerPath = Join-Path $env:WINDIR 'Installer'
    try {
        $installerBytes = (Get-ChildItem -Path $installerPath -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $installerGB = [math]::Round($installerBytes / 1GB, 1)
        $lines.Add(("Windows\Installer: {0} GB" -f $installerGB))
        if ($installerGB -gt 50)     { Add-GapFlag -Severity 'CRITICAL' -Category 'C:\Windows\Installer' -Finding ("{0} GB on {1}" -f $installerGB, $env:COMPUTERNAME) -SowImpact 'Orphaned patch cleanup (ref HALO 1125653)' }
        elseif ($installerGB -gt 20) { Add-GapFlag -Severity 'WARNING'  -Category 'C:\Windows\Installer' -Finding ("{0} GB on {1}" -f $installerGB, $env:COMPUTERNAME) -SowImpact 'Orphaned patch cleanup (ref HALO 1125653)' }
    } catch {
        $lines.Add('Windows\Installer: size scan failed - run TreeSize manually')
    }
    $lines.Add('TreeSize        : MANUAL - still export TreeSize PDF per SOP deliverables (full tree)')
}

# Shares + Everyone:FullControl check
$shares = @(Get-SmbShare -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^\w?\$$|^(ADMIN|IPC|print)\$' })
if ($shares.Count -gt 0) {
    $lines.Add('Network shares  :')
    foreach ($share in $shares) {
        $everyoneFull = $false
        try {
            $acc = Get-SmbShareAccess -Name $share.Name -ErrorAction Stop
            $everyoneFull = [bool]($acc | Where-Object { $_.AccountName -match 'Everyone' -and $_.AccessRight -eq 'Full' -and $_.AccessControlType -eq 'Allow' })
        } catch { Write-Verbose ("share access query failed for {0}: {1}" -f $share.Name, $_.Exception.Message) }
        $suffix = ''
        if ($everyoneFull) {
            $suffix = '   [Everyone: Full Control]'
            Add-GapFlag -Severity 'REVIEW' -Category 'Share Permissions' -Finding ("share '{0}' on {1} grants Everyone Full Control" -f $share.Name, $env:COMPUTERNAME) -SowImpact 'Share permission remediation'
        }
        $lines.Add(("  {0}  ->  {1}{2}" -f $share.Name, $share.Path, $suffix))
    }
    if ($isWorkstation) {
        Add-GapFlag -Severity 'REVIEW' -Category 'Shares' -Finding ("workstation {0} hosts {1} non-default share(s)" -f $env:COMPUTERNAME, $shares.Count) -SowImpact 'Migrate data shares to the server'
    }
} else {
    $lines.Add('Network shares  : none (beyond defaults)')
}

# MSSQL instances
$sqlKey = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
if (Test-Path $sqlKey) {
    $inst = (Get-Item $sqlKey).Property
    $lines.Add(("MSSQL instances : {0}" -f ($inst -join ', ')))
} else {
    $lines.Add('MSSQL instances : none detected')
}

# Services: CSV artifact when WriteFiles=1; always inline non-default logon accounts
$allServices = Get-CimInstance -ClassName Win32_Service
if ($writeFiles) {
    $allServices | Select-Object Name, DisplayName, State, StartMode, StartName |
        Export-Csv -Path (Get-ArtifactPath 'services' 'csv') -NoTypeInformation
}
$customAcctSvcs = @($allServices | Where-Object {
    $_.StartName -and $_.StartName -notmatch '^(LocalSystem|NT AUTHORITY\\(LocalService|NetworkService|LOCAL SERVICE|NETWORK SERVICE))$' -and $_.StartName -notmatch '^NT SERVICE\\'
})
if ($customAcctSvcs.Count -gt 0) {
    $lines.Add(("Svc accounts    : {0} service(s) on non-default logon accounts:" -f $customAcctSvcs.Count))
    foreach ($svc in ($customAcctSvcs | Sort-Object StartName | Select-Object -First 25)) {
        $lines.Add(("  {0}  [{1}]  runs as {2}" -f $svc.Name, $svc.State, $svc.StartName))
    }
    if ($customAcctSvcs.Count -gt 25) { $lines.Add(("  ... {0} more (see services CSV)" -f ($customAcctSvcs.Count - 25))) }
} else {
    $lines.Add('Svc accounts    : all services on default system accounts')
}

# ----- C. ACTIVE DIRECTORY (DC by default; CollectDomain=1 from any domain-joined machine) -----
$lines.Add('')
$lines.Add('== C. ACTIVE DIRECTORY ==')
if (-not $cs.PartOfDomain) {
    $lines.Add('Domain          : NOT DOMAIN-JOINED (workgroup)')
    Add-GapFlag -Severity 'HIGH' -Category 'Domain' -Finding ("{0} is in a workgroup" -f $env:COMPUTERNAME) -SowImpact 'Domain build, endpoint join'
} elseif (-not $collectAd) {
    $lines.Add(("Domain          : {0} (member of domain)" -f $cs.Domain))
    $lines.Add('Domain-wide data: SKIPPED on this host - collected by the primary-DC run (set CollectDomain=1 to force here)')
} else {
    $useRsat = [bool](Get-Module -ListAvailable -Name ActiveDirectory)
    if ($useRsat) {
        Import-Module ActiveDirectory -ErrorAction SilentlyContinue
        $lines.Add('AD data source  : ActiveDirectory module (RSAT)')
        try {
            $domain = Get-ADDomain
            $forest = Get-ADForest
            $lines.Add(("Forest / Domain : {0} / {1}" -f $forest.Name, $domain.DNSRoot))
            $lines.Add(("Functional lvl  : domain {0} / forest {1}" -f $domain.DomainMode, $forest.ForestMode))
            $dcs = @(Get-ADDomainController -Filter *)
            $lines.Add(("Domain Ctrllers : {0}" -f (($dcs | ForEach-Object { $_.HostName }) -join ', ')))
            if ($dcs.Count -eq 1) {
                Add-GapFlag -Severity 'REVIEW' -Category 'AD Resilience' -Finding 'single domain controller' -SowImpact 'Second DC once AD baseline is clean (continuity risk per BCP)'
            }

            $comps = @(Get-ADComputer -Filter * -Properties OperatingSystem, LastLogonTimestamp, IPv4Address, Enabled)
            $compObjects = $comps | ForEach-Object {
                [pscustomobject]@{
                    Name = $_.Name; OperatingSystem = $_.OperatingSystem; IPv4Address = $_.IPv4Address
                    Enabled = $_.Enabled
                    LastLogon = if ($_.LastLogonTimestamp) { [DateTime]::FromFileTime($_.LastLogonTimestamp) } else { $null }
                }
            }

            $users = @(Get-ADUser -Filter * -Properties LastLogonTimestamp, Enabled)
            $userObjects = $users | ForEach-Object {
                [pscustomobject]@{
                    SamAccountName = $_.SamAccountName; Enabled = $_.Enabled
                    LastLogon = if ($_.LastLogonTimestamp) { [DateTime]::FromFileTime($_.LastLogonTimestamp) } else { $null }
                }
            }

            $groupCount = @(Get-ADGroup -Filter *).Count
            $daNames = @(Get-ADGroupMember -Identity 'Domain Admins' -Recursive -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SamAccountName)
            $daNote = '(recursive)'

            $pw = Get-ADDefaultDomainPasswordPolicy
            $pwLine = ("min length {0}, complexity {1}, max age {2}, lockout threshold {3}" -f $pw.MinPasswordLength, $pw.ComplexityEnabled, $pw.MaxPasswordAge, $pw.LockoutThreshold)

            $ouCount = @(Get-ADOrganizationalUnit -Filter *).Count
            $gpoNames = @()
            if (Get-Command -Name Get-GPO -ErrorAction SilentlyContinue) {
                $gpoNames = @(Get-GPO -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DisplayName)
            }
            $adOk = $true
        } catch {
            $lines.Add(("AD collection error (RSAT): {0}" -f $_.Exception.Message))
            $adOk = $false
        }
    } else {
        # ADSI fallback - works from any domain-joined machine, no installs.
        $lines.Add('AD data source  : ADSI/DirectorySearcher (no RSAT on this host)')
        $lines.Add('                  Limits: computer IPv4 not stored in AD; Domain Admins = direct members only.')
        try {
            $adDomain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
            $adForest = $adDomain.Forest
            $lines.Add(("Forest / Domain : {0} / {1}" -f $adForest.Name, $adDomain.Name))
            $lines.Add(("Functional lvl  : domain {0} / forest {1}" -f $adDomain.DomainMode, $adForest.ForestMode))
            $dcNames = @($adDomain.DomainControllers | ForEach-Object { $_.Name })
            $lines.Add(("Domain Ctrllers : {0}" -f ($dcNames -join ', ')))
            if ($dcNames.Count -eq 1) {
                Add-GapFlag -Severity 'REVIEW' -Category 'AD Resilience' -Finding 'single domain controller' -SowImpact 'Second DC once AD baseline is clean (continuity risk per BCP)'
            }

            $rootDse = [ADSI]"LDAP://RootDSE"
            $defaultNc = $rootDse.defaultNamingContext.Value
            $domainEntry = [ADSI]("LDAP://" + $defaultNc)

            function Invoke-AdsiSearch {
                param([string]$Filter, [string[]]$Props)
                $searcher = New-Object System.DirectoryServices.DirectorySearcher($domainEntry, $Filter)
                $searcher.PageSize = 1000
                foreach ($p in $Props) { [void]$searcher.PropertiesToLoad.Add($p) }
                $searcher.FindAll()
            }

            # Computers (userAccountControl bit 0x2 = disabled)
            $compResults = Invoke-AdsiSearch -Filter '(objectCategory=computer)' -Props @('name','operatingSystem','lastLogonTimestamp','userAccountControl')
            $compObjects = foreach ($r in $compResults) {
                $uac2 = 0; if ($r.Properties['useraccountcontrol'].Count -gt 0) { $uac2 = [int]$r.Properties['useraccountcontrol'][0] }
                $llt = $null; if ($r.Properties['lastlogontimestamp'].Count -gt 0) { $llt = [DateTime]::FromFileTime([long]$r.Properties['lastlogontimestamp'][0]) }
                $osStr = ''; if ($r.Properties['operatingsystem'].Count -gt 0) { $osStr = [string]$r.Properties['operatingsystem'][0] }
                [pscustomobject]@{
                    Name = [string]$r.Properties['name'][0]; OperatingSystem = $osStr; IPv4Address = ''
                    Enabled = -not ($uac2 -band 2); LastLogon = $llt
                }
            }

            # Users
            $userResults = Invoke-AdsiSearch -Filter '(&(objectCategory=person)(objectClass=user))' -Props @('samAccountName','lastLogonTimestamp','userAccountControl')
            $userObjects = foreach ($r in $userResults) {
                $uac2 = 0; if ($r.Properties['useraccountcontrol'].Count -gt 0) { $uac2 = [int]$r.Properties['useraccountcontrol'][0] }
                $llt = $null; if ($r.Properties['lastlogontimestamp'].Count -gt 0) { $llt = [DateTime]::FromFileTime([long]$r.Properties['lastlogontimestamp'][0]) }
                [pscustomobject]@{
                    SamAccountName = [string]$r.Properties['samaccountname'][0]
                    Enabled = -not ($uac2 -band 2); LastLogon = $llt
                }
            }

            $groupCount = (Invoke-AdsiSearch -Filter '(objectCategory=group)' -Props @('name')).Count

            # Domain Admins - direct members via the group's member attribute
            $daNames = @()
            $daResult = (Invoke-AdsiSearch -Filter '(&(objectCategory=group)(sAMAccountName=Domain Admins))' -Props @('member')) | Select-Object -First 1
            if ($daResult) {
                foreach ($dn in $daResult.Properties['member']) {
                    $daNames += (($dn -split ',')[0] -replace '^CN=', '')
                }
            }
            $daNote = '(direct members only - nested groups not expanded)'

            # Password policy from domain object attributes
            $minPwd = $domainEntry.Properties['minPwdLength'].Value
            $pwdProps = [int]$domainEntry.Properties['pwdProperties'].Value
            $complexity = [bool]($pwdProps -band 1)
            $maxPwdAgeDays = 'never'
            $maxRaw = $domainEntry.ConvertLargeIntegerToInt64($domainEntry.Properties['maxPwdAge'].Value)
            if ($maxRaw -ne 0 -and $maxRaw -ne [long]::MinValue) { $maxPwdAgeDays = [math]::Round([math]::Abs($maxRaw) / 864000000000, 0) }
            $lockout = $domainEntry.Properties['lockoutThreshold'].Value
            $pwLine = ("min length {0}, complexity {1}, max age {2} days, lockout threshold {3}" -f $minPwd, $complexity, $maxPwdAgeDays, $lockout)

            $ouCount = (Invoke-AdsiSearch -Filter '(objectCategory=organizationalUnit)' -Props @('name')).Count
            $gpoNames = @()
            foreach ($r in (Invoke-AdsiSearch -Filter '(objectCategory=groupPolicyContainer)' -Props @('displayName'))) {
                if ($r.Properties['displayname'].Count -gt 0) { $gpoNames += [string]$r.Properties['displayname'][0] }
            }
            $adOk = $true
        } catch {
            $lines.Add(("AD collection error (ADSI): {0}" -f $_.Exception.Message))
            $adOk = $false
        }
    }

    if ($adOk) {
        # --- Unified reporting from either source ---
        $comps2 = @($compObjects)
        $enabledComps = @($comps2 | Where-Object { $_.Enabled })
        $activeComps  = @($enabledComps | Where-Object { $_.LastLogon -and $_.LastLogon -gt $activeCutoff })
        $staleComps   = @($enabledComps | Where-Object { -not $_.LastLogon -or $_.LastLogon -lt $staleCutoff })
        $lines.Add(("AD computers    : {0} enabled / {1} active in 30d / {2} inactive {3}d+  ({4} total)" -f $enabledComps.Count, $activeComps.Count, $staleComps.Count, $staleDays, $comps2.Count))
        $lines.Add('                  (LastLogonTimestamp replicates lazily - counts are +/- ~14 days)')
        if ($staleComps.Count -gt 0) {
            Add-GapFlag -Severity 'REVIEW' -Category 'Stale AD Computers' -Finding ("{0} enabled computers inactive {1}d+" -f $staleComps.Count, $staleDays) -SowImpact 'AD cleanup, account audit'
        }
        if ($writeFiles) {
            $comps2 | Select-Object Name, OperatingSystem, IPv4Address, Enabled,
                @{ n = 'LastLogon'; e = { if ($_.LastLogon) { $_.LastLogon.ToString('yyyy-MM-dd') } else { 'never' } } } |
                Sort-Object OperatingSystem, Name |
                Export-Csv -Path (Get-ArtifactPath 'ad-computers' 'csv') -NoTypeInformation
        }

        $lines.Add('Active servers  :')
        foreach ($c in ($enabledComps | Where-Object { $_.OperatingSystem -match 'Server' } | Sort-Object Name)) {
            $ll = 'never'; if ($c.LastLogon) { $ll = $c.LastLogon.ToString('yyyy-MM-dd') }
            $lines.Add(("  {0}  {1}  {2}  last logon {3}" -f $c.Name, $c.OperatingSystem, $c.IPv4Address, $ll))
        }
        $wsComps = @($enabledComps | Where-Object { $_.OperatingSystem -notmatch 'Server' } | Sort-Object Name)
        $lines.Add(("Workstations    : {0} enabled" -f $wsComps.Count))
        foreach ($c in ($wsComps | Select-Object -First 60)) {
            $ll = 'never'; if ($c.LastLogon) { $ll = $c.LastLogon.ToString('yyyy-MM-dd') }
            $lines.Add(("  {0}  {1}  {2}  last logon {3}" -f $c.Name, $c.OperatingSystem, $c.IPv4Address, $ll))
        }
        if ($wsComps.Count -gt 60) { $lines.Add(("  ... {0} more (full list in ad-computers CSV)" -f ($wsComps.Count - 60))) }
        $lines.Add('                  Run this collector on each active server above (when access exists),')
        $lines.Add('                  plus 2-3 workstation spot-checks (SOP 5.2-D).')

        $preW10 = @($enabledComps | Where-Object { $_.OperatingSystem -match 'Windows (7|8|8\.1|XP|Vista)\b' })
        if ($preW10.Count -gt 0) {
            Add-GapFlag -Severity 'HIGH' -Category 'Workstation OS' -Finding ("{0} enabled endpoints on pre-Windows-10 OS: {1}" -f $preW10.Count, (($preW10 | Select-Object -First 5 -ExpandProperty Name) -join ', ')) -SowImpact 'Workstation OS upgrade or replacement'
        }
        $oldServers = @($enabledComps | Where-Object { $_.OperatingSystem -match 'Server (2008|2012|2016)' })
        if ($oldServers.Count -gt 0) {
            Add-GapFlag -Severity 'HIGH' -Category 'Server OS' -Finding ("{0} server(s) on 2016 or older: {1}" -f $oldServers.Count, (($oldServers | Select-Object -ExpandProperty Name) -join ', ')) -SowImpact 'Server OS upgrade or replacement'
        }

        $users2 = @($userObjects)
        $enabledUsers = @($users2 | Where-Object { $_.Enabled })
        $staleUsers   = @($enabledUsers | Where-Object { -not $_.LastLogon -or $_.LastLogon -lt $staleCutoff })
        $lines.Add(("AD users        : {0} enabled / {1} disabled ({2} total)" -f $enabledUsers.Count, ($users2.Count - $enabledUsers.Count), $users2.Count))
        if ($staleUsers.Count -gt 0) {
            $lines.Add(("Stale users     : {0} enabled, no logon in {1}d+: {2}" -f $staleUsers.Count, $staleDays, (($staleUsers | Select-Object -First 10 -ExpandProperty SamAccountName) -join ', ')))
            Add-GapFlag -Severity 'REVIEW' -Category 'Stale AD Accounts' -Finding ("{0} enabled users with no logon in {1}d+" -f $staleUsers.Count, $staleDays) -SowImpact 'AD cleanup, account audit'
        }

        $lines.Add(("Security groups : {0} total" -f $groupCount))
        $lines.Add(("Domain Admins   : {0} member(s) {1}: {2}" -f $daNames.Count, $daNote, ($daNames -join ', ')))
        if ($daNames.Count -gt 3) {
            Add-GapFlag -Severity 'HIGH' -Category 'Domain Admins' -Finding ("{0} members (DTC cap is 3 per AD-001)" -f $daNames.Count) -SowImpact 'Privilege audit, DA reduction'
        }
        $lines.Add(("Password policy : {0}" -f $pwLine))
        $lines.Add(("OUs             : {0} (screenshot ADUC tree manually per SOP - structure needs eyes)" -f $ouCount))
        if ($gpoNames.Count -gt 0) {
            $lines.Add(("GPOs            : {0} - {1}" -f $gpoNames.Count, (($gpoNames | Select-Object -First 15) -join '; ')))
        } else {
            $lines.Add('GPOs            : none enumerated')
        }
    }
}

# ----- D/E. INSTALLED SOFTWARE + LOB DETECTION -----
$lines.Add('')
$lines.Add('== D. INSTALLED SOFTWARE / LOB DETECTION ==')
$programs = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                             'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName } |
    Select-Object DisplayName, Publisher, DisplayVersion, InstallDate |
    Sort-Object DisplayName
if ($writeFiles) {
    $programs | Export-Csv -Path (Get-ArtifactPath 'installed-programs' 'csv') -NoTypeInformation
}
$lines.Add(("Installed apps  : {0} entries" -f @($programs).Count))

$lobCategories = [ordered]@{
    'PMS / EHR'        = 'Dentrix|Eaglesoft|Open ?Dental|SoftDent|PracticeWorks|Curve|PBS Endo|\bTDO\b|Epic|Cerner|athena|eClinicalWorks|NextGen'
    'Imaging'          = 'DEXIS|CS Imaging|Carestream|EzDent|Schick|CDR|Apteryx|XVWeb|XrayVision|Romexis|Sidexis|DTX Studio|Dolphin|i-CAT|VixWin|CLINIVIEW'
    'Imaging services' = 'TWAIN|Twacker|Imaging Suite Service|IOSS'
    'Backup'           = 'Veeam|MSP360|CloudBerry|Acronis|StorageCraft|Arcserve|Datto|ShadowProtect|Windows Server Backup'
    'RMM'              = 'NinjaOne|NinjaRMM|LabTech|ConnectWise Automate|Datto RMM|Kaseya|Atera|N-able|SAAZ'
    'Remote access'    = 'TeamViewer|AnyDesk|Splashtop|ScreenConnect|ConnectWise Control|Bomgar|BeyondTrust|GoToAssist|GoTo Resolve|GoTo Opener|LogMeIn|RustDesk|Chrome Remote'
    'AV / EDR'         = 'SentinelOne|Blackpoint|Huntress|Webroot|Sophos|Norton|McAfee|\bAVG\b|Avast|Kaspersky|Bitdefender|Malwarebytes|CrowdStrike|Cynet|ESET|Trend Micro'
    'VoIP'             = 'Weave|RingCentral|8x8|Zoom|Vonage|Dialpad'
    'ERP / Business'   = 'QuickBooks|Sage|NetSuite|Dynamics|Salesforce|HubSpot'
    'CAD / Eng'        = 'AutoCAD|SolidWorks|Procore|PlanGrid'
}
$detected = @{}
foreach ($cat in $lobCategories.Keys) {
    $hits = @($programs | Where-Object { $_.DisplayName -match $lobCategories[$cat] })
    $detected[$cat] = $hits
    if ($hits.Count -gt 0) {
        $lines.Add(("{0,-16}: {1}" -f $cat, (($hits | ForEach-Object { "{0} {1}" -f $_.DisplayName, $_.DisplayVersion }) -join '; ')))
    } else {
        $lines.Add(("{0,-16}: none detected" -f $cat))
    }
}

$lines.Add('Full list       :')
foreach ($p in $programs) {
    $lines.Add(("  {0} | {1} | {2}" -f $p.DisplayName, $p.DisplayVersion, $p.Publisher))
}

if ($isServer) {
    if ($detected['RMM'].Count -eq 0 -or -not ($detected['RMM'].DisplayName -match 'Ninja')) {
        Add-GapFlag -Severity 'HIGH' -Category 'RMM' -Finding ("NinjaOne agent not detected on {0}" -f $env:COMPUTERNAME) -SowImpact 'RMM deployment'
    }
    if ($detected['Backup'].Count -eq 0 -or -not ($detected['Backup'].DisplayName -match 'Veeam')) {
        Add-GapFlag -Severity 'HIGH' -Category 'Backup' -Finding ("Veeam not detected on {0}" -f $env:COMPUTERNAME) -SowImpact 'Veeam BDR Day 1 deployment'
    }
}
$competingRmm = @($detected['RMM'] | Where-Object { $_.DisplayName -notmatch 'Ninja' })
if ($competingRmm.Count -gt 0) {
    Add-GapFlag -Severity 'REVIEW' -Category 'RMM' -Finding ("competing RMM on {0}: {1}" -f $env:COMPUTERNAME, (($competingRmm | Select-Object -ExpandProperty DisplayName) -join ', ')) -SowImpact 'Competing agent removal'
}
$consumerAv = @($detected['AV / EDR'] | Where-Object { $_.DisplayName -match 'Norton|McAfee|\bAVG\b|Avast|Kaspersky' })
if ($consumerAv.Count -gt 0) {
    Add-GapFlag -Severity 'REVIEW' -Category 'AV' -Finding ("consumer AV on {0}: {1}" -f $env:COMPUTERNAME, (($consumerAv | Select-Object -ExpandProperty DisplayName) -join ', ')) -SowImpact 'AV cleanup, managed AV deployment'
}
$nonDtcRemote = @($detected['Remote access'] | Where-Object { $_.DisplayName -match 'TeamViewer|AnyDesk|ScreenConnect|Bomgar|GoTo|LogMeIn|Splashtop' })
if ($nonDtcRemote.Count -gt 0) {
    Add-GapFlag -Severity 'REVIEW' -Category 'Remote Access' -Finding ("non-DTC remote access tools on {0}: {1}" -f $env:COMPUTERNAME, (($nonDtcRemote | Select-Object -ExpandProperty DisplayName) -join ', ')) -SowImpact 'Remote access tool removal / replacement'
}

# ----- F. SECURITY POSTURE -----
$lines.Add('')
$lines.Add('== F. SECURITY POSTURE ==')
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $lines.Add(("Defender        : AM enabled {0}, real-time {1}, definitions {2}" -f $mp.AntivirusEnabled, $mp.RealTimeProtectionEnabled, $mp.AntivirusSignatureLastUpdated))
    if (-not $mp.AntivirusEnabled -and $detected['AV / EDR'].Count -eq 0) {
        Add-GapFlag -Severity 'HIGH' -Category 'AV' -Finding ("Defender disabled on {0} with no third-party AV detected" -f $env:COMPUTERNAME) -SowImpact 'Managed AV deployment'
    }
} catch {
    $lines.Add('Defender        : status unavailable (third-party AV may be registered as primary)')
}
foreach ($fwProfile in Get-NetFirewallProfile -ErrorAction SilentlyContinue) {
    $lines.Add(("Firewall {0,-7}: enabled {1}" -f $fwProfile.Name, $fwProfile.Enabled))
    if (-not $fwProfile.Enabled) {
        Add-GapFlag -Severity 'REVIEW' -Category 'Host Firewall' -Finding ("Windows Firewall disabled on {0} profile ({1})" -f $fwProfile.Name, $env:COMPUTERNAME) -SowImpact 'Re-enable host security'
    }
}

$localAdmins = @()
try {
    $localAdmins = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop | Select-Object -ExpandProperty Name)
} catch {
    $adsiGroup = [ADSI]"WinNT://$env:COMPUTERNAME/Administrators,group"
    $localAdmins = @($adsiGroup.Invoke('Members') | ForEach-Object { $_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null) })
}
$lines.Add(("Local admins    : {0}" -f ($localAdmins -join ', ')))
if (-not ($localAdmins -match 'DTCADMIN')) {
    $lines.Add('DTCADMIN        : NOT present')
    Add-GapFlag -Severity 'REVIEW' -Category 'Local Admin' -Finding ("DTCADMIN not present on {0}" -f $env:COMPUTERNAME) -SowImpact 'Standardize local admin accounts + LAPS via NinjaOne'
} else {
    $lines.Add('DTCADMIN        : present')
}

$rdpDeny = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue).fDenyTSConnections
$nla = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction SilentlyContinue).UserAuthentication
$rdpEnabled = ($rdpDeny -eq 0)
$lines.Add(("RDP             : enabled {0}, NLA {1}   (internet exposure = firewall rule check, MANUAL per SOP 5.2-F)" -f $rdpEnabled, ($nla -eq 1)))
if ($isWorkstation -and $rdpEnabled) {
    Add-GapFlag -Severity 'REVIEW' -Category 'RDP' -Finding ("RDP enabled on workstation {0}" -f $env:COMPUTERNAME) -SowImpact 'Restrict RDP (NA template common finding NW-1)'
}

$uac = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA
if ($uac -eq 0) {
    $lines.Add('UAC             : DISABLED')
    Add-GapFlag -Severity 'REVIEW' -Category 'UAC' -Finding ("UAC disabled on {0}" -f $env:COMPUTERNAME) -SowImpact 'Re-enable UAC (common AD finding per NA template 3.1)'
} else {
    $lines.Add('UAC             : enabled')
}

try {
    $smb1 = (Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol
    $lines.Add(("SMBv1           : {0}" -f $smb1))
    if ($smb1) { Add-GapFlag -Severity 'REVIEW' -Category 'SMBv1' -Finding ("SMBv1 enabled on {0}" -f $env:COMPUTERNAME) -SowImpact 'Disable SMBv1 after LOB compatibility check' }
} catch {
    $lines.Add('SMBv1           : query failed')
}
$lines.Add('Assume breach   : review Svc accounts above + scheduled tasks + tray screenshots for anything off (SOP 5.2-F)')

# ----- G. BACKUP STATE -----
$lines.Add('')
$lines.Add('== G. BACKUP STATE ==')
$backupSvcs = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Veeam|MSP360|CloudBerry|Acronis|StorageCraft|Arcserve|Datto|Lockhart' }
if ($backupSvcs) {
    foreach ($svc in $backupSvcs) { $lines.Add(("Backup service  : {0} [{1}]" -f $svc.DisplayName, $svc.Status)) }
} else {
    $lines.Add('Backup services : none detected')
}
if ($isServer) {
    $lines.Add('Last job/restore: MANUAL - console screenshot per SOP 5.2-G (job history needs product console)')
}

# ----- H. SUBNET SWEEP (optional non-AD device discovery - one machine per site) -----
if ($env:SubnetSweep -eq "1") {
    $lines.Add('')
    $lines.Add('== H. SUBNET SWEEP (optional - run from ONE machine per site) ==')
    if ($primaryIp -and $primaryPrefix -eq '255.255.255.0') {
        $base = ($primaryIp -split '\.')[0..2] -join '.'
        $lines.Add(("Sweeping        : {0}.1-254 (async ICMP, 400ms timeout)" -f $base))
        $tasks = @{}
        foreach ($i in 1..254) {
            $ping = New-Object System.Net.NetworkInformation.Ping
            $tasks["$base.$i"] = $ping.SendPingAsync("$base.$i", 400)
        }
        [System.Threading.Tasks.Task]::WaitAll(@($tasks.Values))
        $alive = [System.Collections.Generic.List[object]]::new()
        foreach ($ip in $tasks.Keys) {
            if ($tasks[$ip].Result.Status -eq 'Success') {
                $hostname = ''
                try {
                    $rt = [System.Net.Dns]::GetHostEntryAsync($ip)
                    if ($rt.Wait(1500)) { $hostname = $rt.Result.HostName }
                } catch { Write-Verbose ("reverse DNS failed for {0}" -f $ip) }
                $alive.Add([pscustomobject]@{ IPAddress = $ip; Hostname = $hostname })
            }
        }
        $arp = @{}
        foreach ($n in Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.State -in 'Reachable', 'Stale', 'Permanent' }) {
            $arp[$n.IPAddress] = $n.LinkLayerAddress
        }
        $sweep = $alive | Sort-Object { [version]$_.IPAddress } | Select-Object IPAddress, Hostname, @{ n = 'MAC'; e = { $arp[$_.IPAddress] } }
        if ($writeFiles) {
            $sweep | Export-Csv -Path (Get-ArtifactPath 'subnet-sweep' 'csv') -NoTypeInformation
        }
        $lines.Add(("Hosts alive     : {0} (identify non-AD devices: gateway, printers, NAS, sensors)" -f @($sweep).Count))
        foreach ($row in $sweep) { $lines.Add(("  {0,-15} {1,-18} {2}" -f $row.IPAddress, $row.MAC, $row.Hostname)) }
    } else {
        $lines.Add('Sweep skipped   : primary NIC is not a /24 (or no gateway NIC found) - run Advanced IP Scanner manually')
    }
} else {
    $lines.Add('')
    $lines.Add('== H. SUBNET SWEEP ==')
    $lines.Add('Skipped (SubnetSweep!=1). Run Advanced IP Scanner manually per SOP 5.2-A, or re-run with SubnetSweep=1 on ONE machine.')
}

# ----- GAP ANALYSIS FLAGS (NA SOP Section 6) -----
$lines.Add('')
$lines.Add('== GAP ANALYSIS FLAGS (NA SOP v3.1 Section 6 - each maps to a SoW line item) ==')
if ($gapFlags.Count -eq 0) {
    $lines.Add('No automated gap flags raised on this host. Manual checks (firewall, VLAN, email platform, spam filter, printing model) still apply.')
} else {
    foreach ($flag in $gapFlags) { $lines.Add($flag) }
}
$lines.Add('')
$lines.Add('NOT EVALUATED BY THIS SCRIPT (manual per SOP): firewall make/model + RDP internet')
$lines.Add('exposure, managed switches/VLANs, WiFi SSID separation, WAN speed test, email')
$lines.Add('platform + spam filter, print deployment model, M365 tenant state, specialized')
$lines.Add('hardware walk, Network Detective, server room photos.')
$lines.Add('========================================================================')
$lines.Add((" END OF NETWORK ASSESSMENT - {0} ({1})" -f $domainLabel.ToUpper(), $env:COMPUTERNAME))
$lines.Add('========================================================================')

# Emit report: stdout (NinjaOne activity log capture) + artifact file when WriteFiles=1
$report = $lines -join [Environment]::NewLine
if ($writeFiles) {
    $report | Out-File -FilePath (Get-ArtifactPath 'na-report' 'txt') -Encoding utf8
}
Write-Output $report

Stop-Transcript