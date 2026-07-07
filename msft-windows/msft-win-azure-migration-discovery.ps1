# NOTE: intentionally no "#Requires" - downlevel hosts (PS 4.0 / Server 2012 R2 era)
# must run with degraded output rather than failing before execution. See version banner.
<#
.SYNOPSIS
    msft-win-azure-migration-discovery - Standardized server discovery for Azure/Entra migration SOW scoping.

.DESCRIPTION
    Read-only environment discovery run via NinjaOne against ANY server context:
    physical servers, Hyper-V hosts, Hyper-V guest VMs, and RDS session hosts.
    Detects its own run context and gathers context-appropriate data; all sections
    degrade gracefully when a role/module is absent.

    v4 adds: outbound established-connection dependency map, hosts file entries,
    SMB1/SMB-signing/LmCompatibilityLevel auth posture, OS activation channel
    (Azure Hybrid Benefit eligibility), stale AD computer count, and FSLogix /
    Entra Cloud Sync / Printix agent detection.

    Output: stdout (NinjaOne activity feed, sectioned) + optional full report on disk.
    Makes NO changes. Non-interactive.

    Companion SOP: BookStack Page 3893 (Azure Migration Discovery & SOW Development SOP).

.NOTES
    NinjaOne script variables (all optional):
        scanShareSizes    (Checkbox, default true)  - recursive share sizing + recency
        includeDhcpLeases (Checkbox, default true)  - DHCP lease dump (peripheral discovery)
        maxDnsRecords     (Integer,  default 200)   - cap DNS A-record listing on DCs
        ntlmAuditDays     (Integer,  default 7)     - Security-log NTLM logon scan window; 0 disables
        saveReportToDisk  (Checkbox, default true)  - write report + transcript to ProgramData

    Run as: SYSTEM, 64-bit (self-relaunches from 32-bit NinjaOne default).
    PowerShell: designed for 5.1; runs degraded on 4.0 (some sections emit errors/empty).
    Deployment: run on EVERY server at the site - each host AND inside each guest VM.
    Repo: DTC-Inc/msp-script-library -> msft-windows/msft-win-azure-migration-discovery.ps1
#>

[CmdletBinding()]
param()

# ============================================================================
# 64-bit relaunch (NinjaOne defaults to 32-bit PowerShell)
# ============================================================================
if ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64') {
    $ps64 = Join-Path $env:WINDIR 'sysnative\WindowsPowerShell\v1.0\powershell.exe'
    & $ps64 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $MyInvocation.MyCommand.Path
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'SilentlyContinue'
Set-StrictMode -Off

# ============================================================================
# NinjaOne variable ingestion
# ============================================================================
function Get-EnvBool {
    param([string]$Name, [bool]$Default)
    $raw = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return ($raw -match '^(1|true|yes)$')
}
$ScanShareSizes    = Get-EnvBool -Name 'scanShareSizes'    -Default $true
$IncludeDhcpLeases = Get-EnvBool -Name 'includeDhcpLeases' -Default $true
$SaveReportToDisk  = Get-EnvBool -Name 'saveReportToDisk'  -Default $true
$MaxDnsRecords     = 200
if ($env:maxDnsRecords -match '^\d+$') { $MaxDnsRecords = [int]$env:maxDnsRecords }
$NtlmAuditDays     = 7
if ($env:ntlmAuditDays -match '^\d+$') { $NtlmAuditDays = [int]$env:ntlmAuditDays }

# ============================================================================
# Output plumbing + transcript rotation (keep 5)
# ============================================================================
$script:ReportLines = New-Object System.Collections.Generic.List[string]
$OutDir = 'C:\ProgramData\DTC\AzureMigrationDiscovery'
$Stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'

if ($SaveReportToDisk) {
    $null = New-Item -ItemType Directory -Path $OutDir -Force
    Get-ChildItem -Path $OutDir -Filter '*.transcript.log' |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 4 |
        Remove-Item -Force
    try { Start-Transcript -Path (Join-Path $OutDir "AzMigDiscovery-$Stamp.transcript.log") -Force | Out-Null }
    catch { Write-Output "WARN: transcript failed to start: $($_.Exception.Message)" }
}

function Write-Line {
    param([Parameter(ValueFromPipeline = $true)]$InputObject)
    process {
        $text = if ($InputObject -is [string]) { $InputObject } else { ($InputObject | Out-String -Width 4096).TrimEnd() }
        if ([string]::IsNullOrEmpty($text)) { return }
        Write-Output $text
        $script:ReportLines.Add($text)
    }
}
function Write-Section {
    param([string]$Title)
    Write-Line ''
    Write-Line ('=' * 70)
    Write-Line "== $Title"
    Write-Line ('=' * 70)
}

# ============================================================================
# RUN-CONTEXT DETECTION (Physical / Hyper-V Host / Hyper-V Guest / RDS Session Host)
# ============================================================================
$cs    = Get-CimInstance Win32_ComputerSystem
$os    = Get-CimInstance Win32_OperatingSystem
$bios  = Get-CimInstance Win32_BIOS
$board = Get-CimInstance Win32_BaseBoard

$IsHyperVGuest = ($board.Product -eq 'Virtual Machine' -or $cs.Model -eq 'Virtual Machine')
$IsHyperVHost  = $false
if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
    try { if (@(Get-VM -ErrorAction Stop).Count -ge 0) { $IsHyperVHost = $true } } catch { $IsHyperVHost = $false }
}
$tsSetting = Get-CimInstance -Namespace 'root\CIMV2\TerminalServices' -ClassName Win32_TerminalServiceSetting -ErrorAction SilentlyContinue
$IsRdsHost = ($tsSetting -and $tsSetting.TerminalServerMode -eq 1)
$isDC = $cs.DomainRole -in 4, 5

$contexts = New-Object System.Collections.Generic.List[string]
if ($IsHyperVGuest) { $contexts.Add('HYPER-V GUEST') } else { $contexts.Add('PHYSICAL') }
if ($IsHyperVHost)  { $contexts.Add('HYPER-V HOST') }
if ($IsRdsHost)     { $contexts.Add('RDS SESSION HOST') }
if ($isDC)          { $contexts.Add('DOMAIN CONTROLLER') }

Write-Line "DTC AZURE MIGRATION DISCOVERY v4 | Host: $env:COMPUTERNAME | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | SOP: KB 3893"
Write-Line "RUN CONTEXT: $($contexts -join ' + ')"
$psMajor = $PSVersionTable.PSVersion.Major
Write-Line "PowerShell: $($PSVersionTable.PSVersion)"
if ($psMajor -lt 5) {
    Write-Line "WARN: PowerShell $psMajor.x detected (target is 5.1+). Some sections will be empty or emit errors - treat gaps as 'not collected', NOT as 'absent'."
    Write-Line "FLAG: PS $psMajor.x implies Server 2012 R2-era or older OS - EOL platform, itself a migration finding."
}

# ============================================================================
# 1. OS / HARDWARE / IDENTITY / FIRMWARE / LICENSING CHANNEL
# ============================================================================
Write-Section '1. OS / HARDWARE / IDENTITY / FIRMWARE / LICENSING'
Write-Line ([pscustomobject]@{
    ComputerName = $env:COMPUTERNAME
    Domain       = $cs.Domain
    PartOfDomain = $cs.PartOfDomain
    DomainRole   = $cs.DomainRole
    Manufacturer = $cs.Manufacturer
    Model        = $cs.Model
    ServiceTag   = $bios.SerialNumber
    OS           = $os.Caption
    Build        = $os.BuildNumber
    InstallDate  = $os.InstallDate
    LastBoot     = $os.LastBootUpTime
    LogicalCPUs  = $cs.NumberOfLogicalProcessors
    RAM_GB       = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
} | Format-List)
Write-Line (Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors | Format-List)

# Firmware / boot style -> Azure Gen1 (BIOS/MBR) vs Gen2 (UEFI/GPT) + migration tooling choice
$firmware = if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { 'UEFI' } else { 'BIOS (legacy)' }
$secureBoot = 'n/a'
try { $secureBoot = if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'Enabled' } else { 'Disabled' } }
catch { $secureBoot = 'Not supported (BIOS) or not readable' }
$bootDisk = Get-Disk -ErrorAction SilentlyContinue | Where-Object { $_.IsBoot }
Write-Line "Firmware: $firmware | Secure Boot: $secureBoot | Boot disk partition style: $($bootDisk.PartitionStyle)"
Write-Line '  (UEFI/GPT -> Azure Gen2 VM eligible; BIOS/MBR -> Gen1 or convert. Matches Disk2VHD P2V rules in KB 1074.)'

Write-Line 'Windows activation channel (OEM does NOT transfer to Azure; Azure Hybrid Benefit needs qualifying licensing - run-rate input):'
Write-Line (Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" -ErrorAction SilentlyContinue |
    Select-Object Name, Description, LicenseStatus | Format-List)

if ($IsHyperVGuest) {
    $guestParams = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters' -ErrorAction SilentlyContinue
    if ($guestParams) {
        Write-Line "Hyper-V GUEST of physical host: $($guestParams.PhysicalHostNameFullyQualified)  (run this script on that host too)"
    } else {
        Write-Line 'Hyper-V guest detected but host parameters not readable (integration services issue?).'
    }
}

# ============================================================================
# 2. DISK / VOLUMES / STORAGE CONTROLLER
# ============================================================================
Write-Section '2. DISK / VOLUMES / STORAGE CONTROLLER'
Write-Line (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
    Select-Object DeviceID, VolumeName,
        @{N = 'SizeGB'; E = { [math]::Round($_.Size / 1GB, 1) } },
        @{N = 'FreeGB'; E = { [math]::Round($_.FreeSpace / 1GB, 1) } },
        @{N = 'UsedGB'; E = { [math]::Round(($_.Size - $_.FreeSpace) / 1GB, 1) } } |
    Format-Table -AutoSize)
Write-Line 'Storage controller (PERC/LSI = physical RAID; "Microsoft Hyper-V SCSI Controller" = VM):'
Write-Line (Get-CimInstance Win32_SCSIController | Select-Object Name, DriverName | Format-Table -AutoSize)
Write-Line 'Physical disks (media type - physical boxes only, empty on guests):'
Write-Line (Get-PhysicalDisk -ErrorAction SilentlyContinue |
    Select-Object FriendlyName, MediaType, BusType,
        @{N = 'SizeGB'; E = { [math]::Round($_.Size / 1GB, 0) } }, HealthStatus |
    Format-Table -AutoSize)

# ============================================================================
# 3. RESOURCE UTILIZATION SAMPLE (Azure VM sizing input)
# ============================================================================
Write-Section '3. RESOURCE UTILIZATION SAMPLE (point-in-time - corroborate with NinjaOne 30-day graphs)'
try {
    $cpuSample = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 2 -MaxSamples 3 -ErrorAction Stop).CounterSamples.CookedValue
    Write-Line ("CPU busy avg over 3x2s samples: {0} %" -f [math]::Round(($cpuSample | Measure-Object -Average).Average, 1))
} catch {
    Write-Line "CPU counter sample unavailable: $($_.Exception.Message)"
}
Write-Line ([pscustomobject]@{
    RAM_TotalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    RAM_UsedGB  = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB, 1)
    RAM_FreeGB  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
} | Format-List)
$localProfiles = Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special }
Write-Line "Local user profiles (RDS/AVD sizing signal): $(@($localProfiles).Count)"

# ============================================================================
# 4. INSTALLED ROLES / FEATURES + HIGH-IMPACT ROLE FLAGS + IIS
# ============================================================================
Write-Section '4. INSTALLED SERVER ROLES / FEATURES'
$installedRoles = @()
if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
    $installedRoles = Get-WindowsFeature | Where-Object { $_.Installed }
    Write-Line ($installedRoles | Where-Object { $_.FeatureType -eq 'Role' } |
        Select-Object Name, DisplayName | Format-Table -AutoSize)
    $flagMap = @{
        'AD-Certificate' = 'ADCS (internal CA) - certificate issuance needs a design decision (Cloud PKI / Intune SCEP / retire)'
        'NPAS'           = 'NPS/RADIUS - Wi-Fi/VPN auth depends on this box; needs replacement (RADIUSaaS / cloud RADIUS)'
        'UpdateServices' = 'WSUS - patch source moves to NinjaOne/Intune; decommission plan needed'
        'WDS'            = 'WDS imaging - replace with Autopilot or NinjaOne deployment'
        'ADFS-Federation'= 'AD FS - federated identity in play; identity design changes materially'
        'FS-DFS-Namespace' = 'DFS Namespace - UNC paths abstracted; remap plan required'
        'FS-DFS-Replication' = 'DFS Replication - multi-target file data; scope all replicas'
        'Web-Server'     = 'IIS - internal web apps hosted here (bindings below)'
        'FS-SMB1'        = 'SMB1 FEATURE INSTALLED - legacy clients likely depend on it; breaks against Azure Files/modern targets'
    }
    foreach ($k in $flagMap.Keys) {
        if ($installedRoles | Where-Object { $_.Name -eq $k }) { Write-Line "FLAG: $($flagMap[$k])" }
    }
    if ($installedRoles | Where-Object { $_.Name -eq 'Web-Server' }) {
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        if (Get-Command Get-Website -ErrorAction SilentlyContinue) {
            Write-Line 'IIS site bindings:'
            Write-Line (Get-Website | Select-Object Name, State,
                @{N = 'Bindings'; E = { ($_.bindings.Collection | ForEach-Object { $_.bindingInformation }) -join ' | ' } },
                PhysicalPath | Format-Table -AutoSize)
        }
    }
} else {
    Write-Line 'Get-WindowsFeature not available (not a Server SKU or module missing).'
}

# ============================================================================
# 5. ACTIVE DIRECTORY (if DC) - identity migration inputs
# ============================================================================
Write-Section '5. ACTIVE DIRECTORY DOMAIN SERVICES'
Write-Line "DomainRole: $($cs.DomainRole) (4/5 = Domain Controller)"
if ($isDC) {
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
    if (Get-Command Get-ADDomain -ErrorAction SilentlyContinue) {
        $dom = Get-ADDomain
        $for = Get-ADForest
        Write-Line ($dom | Select-Object Name, NetBIOSName, DNSRoot, DomainMode, PDCEmulator, RIDMaster, InfrastructureMaster | Format-List)
        Write-Line ($for | Select-Object Name, ForestMode, SchemaMaster, DomainNamingMaster | Format-List)
        Write-Line "UPN suffixes: $((@($for.UPNSuffixes) -join ', '))"
        if ($dom.DNSRoot -match '\.(local|lan|internal|corp)$') {
            Write-Line "FLAG: Non-routable AD domain suffix ($($dom.DNSRoot)) - UPN suffix remediation required before Entra sync."
        }
        Write-Line ("Enabled users : {0}" -f @(Get-ADUser -Filter { Enabled -eq $true }).Count)
        Write-Line ("Disabled users: {0}" -f @(Get-ADUser -Filter { Enabled -eq $false }).Count)
        $allComputers = @(Get-ADComputer -Filter { Enabled -eq $true } -Properties OperatingSystem, lastLogonTimestamp)
        Write-Line ("Enabled computer objects: {0}" -f $allComputers.Count)
        $staleComputers = @($allComputers | Where-Object {
            $_.lastLogonTimestamp -and ([datetime]::FromFileTime($_.lastLogonTimestamp) -lt (Get-Date).AddDays(-90))
        })
        Write-Line ("Stale computers (no logon 90+ days): {0}  (exclude from Entra-join/Intune scope; cleanup candidates)" -f $staleComputers.Count)
        Write-Line 'Computers by OS:'
        Write-Line ($allComputers | Group-Object OperatingSystem | Sort-Object Count -Descending |
            Select-Object Count, Name | Format-Table -AutoSize)
        $krbtgt = Get-ADUser -Identity krbtgt -Properties PasswordLastSet
        Write-Line "krbtgt PasswordLastSet: $($krbtgt.PasswordLastSet)  (never-reset = RC4-only keys; blocks Server 2025 KDC / flags for fleet krbtgt audit)"
        if (Get-Command Get-GPO -ErrorAction SilentlyContinue) {
            $gpos = Get-GPO -All
            Write-Line "GPO count: $(@($gpos).Count) (each must be reproduced in Intune or deliberately dropped - SOW input)"
            Write-Line ($gpos | Select-Object DisplayName, GpoStatus | Sort-Object DisplayName | Format-Table -AutoSize)
        }
        Write-Line 'Trusts:'
        Write-Line (Get-ADTrust -Filter * | Select-Object Name, Direction, TrustType | Format-Table -AutoSize)

        # ---- M365 / Entra signals living inside AD ----
        Write-Line '--- Entra/M365 signals in AD ---'
        try {
            $cfgNC = (Get-ADRootDSE).configurationNamingContext
            $scp = Get-ADObject -SearchBase "CN=Device Registration Configuration,CN=Services,$cfgNC" -Filter * -Properties keywords -ErrorAction Stop
            if ($scp) {
                Write-Line "Hybrid Azure AD Join SCP FOUND - tenant config: $((@($scp.keywords) -join '; '))"
            } else { Write-Line 'No hybrid-join SCP found.' }
        } catch { Write-Line 'No hybrid-join SCP container (hybrid device join not configured).' }
        $ssoAcct = Get-ADComputer -Filter { Name -eq 'AZUREADSSOACC' }
        if ($ssoAcct) { Write-Line 'Seamless SSO computer account (AZUREADSSOACC$) PRESENT - Entra seamless SSO configured.' }
        else { Write-Line 'No AZUREADSSOACC$ account (seamless SSO not configured).' }
        $msol = @(Get-ADUser -Filter 'SamAccountName -like "MSOL_*"' | Select-Object -ExpandProperty SamAccountName)
        if ($msol.Count -gt 0) { Write-Line "Entra Connect sync account(s) in AD: $($msol -join ', ') - directory sync exists or existed. Locate the sync server." }
        else { Write-Line 'No MSOL_* sync accounts found.' }
        $mailUsers = @(Get-ADUser -Filter { Enabled -eq $true } -Properties mail, proxyAddresses |
            Where-Object { $_.mail -or $_.proxyAddresses })
        Write-Line "Enabled users with mail/proxyAddresses populated: $($mailUsers.Count) (nonzero suggests existing/previous M365 or Exchange integration)"
    } else {
        Write-Line 'DC detected but ActiveDirectory module unavailable - investigate manually.'
    }
} else {
    Write-Line 'Not a domain controller.'
}

# ============================================================================
# 6. RDS DEPLOYMENT + CALS + LIVE SESSIONS
# ============================================================================
Write-Section '6. REMOTE DESKTOP SERVICES'
if ($IsRdsHost) { Write-Line 'TerminalServerMode=1: this IS an RDS session host (AppServer mode).' }
Import-Module RemoteDesktop -ErrorAction SilentlyContinue
if (Get-Command Get-RDServer -ErrorAction SilentlyContinue) {
    try { Write-Line (Get-RDServer -ErrorAction Stop | Select-Object Server, Roles | Format-Table -AutoSize) }
    catch { Write-Line "Get-RDServer: $($_.Exception.Message)" }
    try { Write-Line (Get-RDSessionCollection -ErrorAction Stop | Select-Object CollectionName, Size | Format-Table -AutoSize) }
    catch { Write-Line 'No session collections readable from this host.' }
    try {
        Write-Line 'Published RemoteApps:'
        Write-Line (Get-RDRemoteApp -ErrorAction Stop | Select-Object CollectionName, DisplayName, FilePath | Format-Table -AutoSize)
    } catch { Write-Line 'No RemoteApps readable from this host.' }
    try { Write-Line (Get-RDLicenseConfiguration -ErrorAction Stop | Format-List) }
    catch { Write-Line 'RDS licensing configuration not readable.' }
} else {
    Write-Line 'RemoteDesktop module not present.'
}
Write-Line 'Installed RDS CAL key packs:'
Write-Line (Get-CimInstance -ClassName Win32_TSLicenseKeyPack -ErrorAction SilentlyContinue |
    Select-Object TypeAndModel, ProductVersion, TotalLicenses, IssuedLicenses, AvailableLicenses |
    Format-Table -AutoSize)
Write-Line 'Live RDP/console sessions (qwinsta):'
Write-Line ((& "$env:WINDIR\System32\qwinsta.exe" 2>&1) -join "`r`n")

# ============================================================================
# 7. SQL SERVER + ODBC DSNS (LOB backend wiring)
# ============================================================================
Write-Section '7. SQL SERVER INSTANCES + DATA FOOTPRINT + ODBC DSNS'
$instKey = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue
if ($instKey) {
    $instKey.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
        $instName = $_.Name; $instId = $_.Value
        $setup = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instId\Setup" -ErrorAction SilentlyContinue
        Write-Line "Instance: $instName | Version: $($setup.Version) | Edition: $($setup.Edition) | Patch: $($setup.PatchLevel)"
        if ($setup.SQLDataRoot -and (Test-Path $setup.SQLDataRoot)) {
            Write-Line "  DataRoot: $($setup.SQLDataRoot)"
            $dbFiles = Get-ChildItem -Path $setup.SQLDataRoot -Recurse -Include *.mdf, *.ndf, *.ldf -ErrorAction SilentlyContinue
            Write-Line ($dbFiles | Select-Object Name,
                @{N = 'SizeGB'; E = { [math]::Round($_.Length / 1GB, 2) } }, DirectoryName |
                Sort-Object SizeGB -Descending | Format-Table -AutoSize)
            $dbTotal = ($dbFiles | Measure-Object Length -Sum).Sum
            Write-Line ("  Total DB file footprint: {0} GB" -f [math]::Round($dbTotal / 1GB, 2))
        }
    }
} else {
    Write-Line 'No SQL Server instance registry keys found.'
}
Write-Line (Get-Service | Where-Object { $_.Name -match 'MSSQL|SQLAgent|SQLBrowser' } |
    Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize)
Write-Line 'System ODBC DSNs (64-bit + 32-bit views - LOB-to-database wiring):'
foreach ($dsnPath in 'HKLM:\SOFTWARE\ODBC\ODBC.INI\ODBC Data Sources',
                     'HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBC.INI\ODBC Data Sources') {
    $dsns = Get-ItemProperty $dsnPath -ErrorAction SilentlyContinue
    if ($dsns) {
        $view = if ($dsnPath -match 'WOW6432Node') { '32-bit' } else { '64-bit' }
        $dsns.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
            Write-Line "  [$view] $($_.Name) -> $($_.Value)"
        }
    }
}

# ============================================================================
# 8. APPLICATIONS + SERVICE ACCOUNTS
# ============================================================================
Write-Section '8. INSTALLED APPLICATIONS + SERVICE ACCOUNTS'
$uninst = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
Write-Line (Get-ItemProperty $uninst -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and $_.DisplayName -notmatch 'Update|Hotfix|KB\d|Visual C\+\+|\.NET Framework' } |
    Select-Object DisplayName, DisplayVersion, Publisher |
    Sort-Object DisplayName -Unique | Format-Table -AutoSize)
Write-Line 'Auto-start non-Microsoft services (server-side LOB components):'
$allSvc = Get-CimInstance Win32_Service
Write-Line ($allSvc |
    Where-Object { $_.StartMode -eq 'Auto' -and $_.PathName -notmatch 'Windows|Microsoft|svchost' } |
    Select-Object Name, DisplayName, State, PathName | Format-Table -AutoSize)
Write-Line 'Services running as DOMAIN/custom accounts (each needs an identity answer post-migration):'
Write-Line ($allSvc |
    Where-Object { $_.StartName -and $_.StartName -notmatch '^(LocalSystem|NT AUTHORITY|NT SERVICE)' } |
    Select-Object Name, DisplayName, StartName, State | Format-Table -AutoSize)
Write-Line 'Scheduled tasks running as domain/custom accounts:'
Write-Line (Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.Principal.UserId -and $_.Principal.UserId -notmatch '^(SYSTEM|LOCAL SERVICE|NETWORK SERVICE|NT AUTHORITY|Users|INTERACTIVE)' } |
    Select-Object TaskName, TaskPath, @{N = 'RunAs'; E = { $_.Principal.UserId } }, State |
    Format-Table -AutoSize)

# ============================================================================
# 9. SMB SHARES + SIZES + RECENCY + ACLS + LIVE SESSIONS
# ============================================================================
Write-Section '9. SMB SHARES'
$shares = Get-SmbShare -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '\$$' -and $_.Name -ne 'IPC$' }
if ($shares) {
    foreach ($s in $shares) {
        Write-Line "----- SHARE: $($s.Name) | PATH: $($s.Path)"
        if ($ScanShareSizes -and (Test-Path -LiteralPath $s.Path)) {
            $sum = 0L; $count = 0L; $newest = [datetime]::MinValue
            Get-ChildItem -LiteralPath $s.Path -Recurse -Force -File -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $sum += $_.Length; $count++
                    if ($_.LastWriteTime -gt $newest) { $newest = $_.LastWriteTime }
                }
            $recency = if ($newest -gt [datetime]::MinValue) { $newest } else { 'n/a (empty)' }
            Write-Line ("  Size: {0} GB | Files: {1} | Newest file write: {2}  (stale newest-write = archive candidate, not migration payload)" -f [math]::Round($sum / 1GB, 2), $count, $recency)
        }
        Write-Line '  Share ACL:'
        Write-Line (Get-SmbShareAccess -Name $s.Name -ErrorAction SilentlyContinue |
            Select-Object AccountName, AccessRight, AccessControlType | Format-Table -AutoSize)
        Write-Line '  NTFS ACL (top level):'
        Write-Line ((Get-Acl -LiteralPath $s.Path -ErrorAction SilentlyContinue).Access |
            Select-Object IdentityReference, FileSystemRights, AccessControlType | Format-Table -AutoSize)
    }
} else {
    Write-Line 'No non-administrative shares found.'
}
Write-Line 'LIVE SMB sessions (who consumes this server right now):'
Write-Line (Get-SmbSession -ErrorAction SilentlyContinue |
    Select-Object ClientComputerName, ClientUserName, NumOpens, Dialect | Format-Table -AutoSize)
Write-Line 'Open files by share path (first 50):'
Write-Line (Get-SmbOpenFile -ErrorAction SilentlyContinue |
    Select-Object ClientComputerName, ClientUserName, Path -First 50 | Format-Table -AutoSize)
Write-Line 'SMB server auth posture:'
$smbCfg = Get-SmbServerConfiguration -ErrorAction SilentlyContinue
if ($smbCfg) {
    Write-Line "  EnableSMB1Protocol: $($smbCfg.EnableSMB1Protocol) | RequireSecuritySignature: $($smbCfg.RequireSecuritySignature) | EncryptData: $($smbCfg.EncryptData)"
    if ($smbCfg.EnableSMB1Protocol) { Write-Line '  FLAG: SMB1 enabled - identify the legacy clients (usually MFP scan-to-SMB) before any file-target change.' }
}
$lmLevel = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name LmCompatibilityLevel -ErrorAction SilentlyContinue).LmCompatibilityLevel
if ($null -ne $lmLevel) {
    Write-Line "  LmCompatibilityLevel: $lmLevel"
    if ($lmLevel -lt 3) { Write-Line '  FLAG: LmCompatibilityLevel < 3 - NTLMv2 not enforced/sent; known SMB auth-failure source (KB 3818) and a blocker against modern targets.' }
} else {
    Write-Line '  LmCompatibilityLevel: not set (OS default applies)'
}

# ============================================================================
# 10. PRINT SERVICES
# ============================================================================
Write-Section '10. PRINT SERVICES'
Write-Line (Get-Printer -ErrorAction SilentlyContinue |
    Select-Object Name, DriverName, PortName, Shared | Format-Table -AutoSize)
Write-Line (Get-PrinterPort -ErrorAction SilentlyContinue |
    Select-Object Name, PrinterHostAddress | Format-Table -AutoSize)

# ============================================================================
# 11. DHCP / DNS (peripheral + LDAP-bound device discovery)
# ============================================================================
Write-Section '11. DHCP / DNS'
if (Get-Command Get-DhcpServerv4Scope -ErrorAction SilentlyContinue) {
    $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
    Write-Line ($scopes | Select-Object ScopeId, StartRange, EndRange, State | Format-Table -AutoSize)
    if ($IncludeDhcpLeases -and $scopes) {
        Write-Line 'DHCP leases (non-PC hostnames = peripherals to inventory - MFPs, scanners, NAS, badge systems):'
        Write-Line ($scopes | ForEach-Object { Get-DhcpServerv4Lease -ScopeId $_.ScopeId -ErrorAction SilentlyContinue } |
            Select-Object IPAddress, HostName, AddressState | Format-Table -AutoSize)
    }
} else {
    Write-Line 'DHCP Server role not present.'
}
if ($isDC -and (Get-Command Get-DnsServerResourceRecord -ErrorAction SilentlyContinue)) {
    Write-Line "DNS A records (first $MaxDnsRecords):"
    Write-Line (Get-DnsServerResourceRecord -ZoneName $cs.Domain -RRType A -ErrorAction SilentlyContinue |
        Select-Object HostName, @{N = 'IP'; E = { $_.RecordData.IPv4Address } } -First $MaxDnsRecords |
        Format-Table -AutoSize)
}

# ============================================================================
# 12. HYPER-V HOST AUDIT (VHDX sizing, checkpoints, vSwitch, VMQ)
# ============================================================================
Write-Section '12. HYPER-V HOST AUDIT'
if ($IsHyperVHost) {
    Write-Line 'VM inventory:'
    Write-Line (Get-VM | Select-Object Name, State, Generation,
        @{N = 'MemAssignedGB'; E = { [math]::Round($_.MemoryAssigned / 1GB, 1) } },
        @{N = 'MemStartupGB'; E = { [math]::Round($_.MemoryStartup / 1GB, 1) } },
        ProcessorCount, DynamicMemoryEnabled | Format-Table -AutoSize)
    Write-Line 'VHDX paths + actual on-disk sizes (UsedGB = migration/transfer payload, NOT MaxGB):'
    Write-Line (Get-VM | Get-VMHardDiskDrive | ForEach-Object {
        $vhd = Get-VHD -Path $_.Path -ErrorAction SilentlyContinue
        [pscustomobject]@{
            VMName  = $_.VMName
            Path    = $_.Path
            MaxGB   = if ($vhd) { [math]::Round($vhd.Size / 1GB, 1) } else { 'ERROR' }
            UsedGB  = if ($vhd) { [math]::Round($vhd.FileSize / 1GB, 1) } else { 'ERROR' }
            Type    = if ($vhd) { $vhd.VhdType } else { 'n/a' }
        }
    } | Format-Table -AutoSize)
    Write-Line '  (VHDX rows showing ERROR = missing/orphaned disk - flag for cleanup, exclude from scope.)'
    $snaps = Get-VM | Get-VMSnapshot -ErrorAction SilentlyContinue
    if ($snaps) {
        Write-Line 'FLAG: Checkpoints present - must merge before export/replication (production checkpoints on DCs also risk non-persisted AD writes):'
        Write-Line ($snaps | Select-Object VMName, Name, CreationTime | Format-Table -AutoSize)
    } else { Write-Line 'No checkpoints.' }
    Write-Line 'Virtual switches (SET vs legacy LBFO):'
    Write-Line (Get-VMSwitch | Select-Object Name, SwitchType, NetAdapterInterfaceDescription, EmbeddedTeamingEnabled | Format-Table -AutoSize)
    $lbfo = Get-NetLbfoTeam -ErrorAction SilentlyContinue
    if ($lbfo) {
        Write-Line 'FLAG: LBFO NIC team present (legacy - DTC standard is SET):'
        Write-Line ($lbfo | Select-Object Name, TeamingMode, LoadBalancingAlgorithm | Format-Table -AutoSize)
    }
    Write-Line 'VMQ status (Broadcom 5720 silent-drop check):'
    Write-Line (Get-NetAdapterVmq -ErrorAction SilentlyContinue |
        Select-Object Name, InterfaceDescription, Enabled | Format-Table -AutoSize)
} elseif (Get-Command Get-VM -ErrorAction SilentlyContinue) {
    Write-Line 'Hyper-V cmdlets present but VM inventory not readable.'
} else {
    Write-Line 'Hyper-V role not installed.'
}

# ============================================================================
# 13. EXISTING CLOUD / HYBRID FOOTPRINT (simplifiers + complete picture)
# ============================================================================
Write-Section '13. EXISTING CLOUD / HYBRID FOOTPRINT'
Write-Line 'dsregcmd /status (key lines):'
$dsreg = & "$env:WINDIR\System32\dsregcmd.exe" /status 2>&1
Write-Line (($dsreg | Where-Object { $_ -match 'AzureAdJoined|EnterpriseJoined|DomainJoined|TenantName|TenantId' }) -join "`r`n")

$adsync = Get-Service ADSync -ErrorAction SilentlyContinue
if ($adsync) {
    Write-Line "Entra Connect (ADSync) service on THIS server: $($adsync.Status) / $($adsync.StartType)"
    Import-Module ADSync -ErrorAction SilentlyContinue
    if (Get-Command Get-ADSyncScheduler -ErrorAction SilentlyContinue) {
        try {
            $sched = Get-ADSyncScheduler -ErrorAction Stop
            Write-Line "  Sync enabled: $($sched.SyncCycleEnabled) | Staging mode: $($sched.StagingModeEnabled) | Last sync: $($sched.LastSyncCycleStartTimeInUTC) UTC"
            if ($sched.StagingModeEnabled) { Write-Line '  FLAG: Staging mode - another Entra Connect server is the active one. Find it.' }
        } catch { Write-Line "  ADSync scheduler not readable: $($_.Exception.Message)" }
    }
} else {
    Write-Line 'Entra Connect (ADSync) not installed on this server. (If MSOL_ accounts exist in Section 5, sync runs elsewhere.)'
}

Write-Line 'Azure / hybrid / legacy agent detection:'
$agentMap = @(
    @{ Svc = 'himds';                        Label = 'Azure Arc (Connected Machine agent) - server already Azure-managed; Arc-enabled migration paths available' }
    @{ Svc = 'obengine';                     Label = 'Azure Backup MARS agent - backups already in an Azure Recovery Services vault' }
    @{ Svc = 'RDAgentBootLoader';            Label = 'Azure Virtual Desktop agent - this host is ALREADY an AVD session host' }
    @{ Svc = 'FileSyncSvc';                  Label = 'Azure File Sync - file data already tiering to Azure Files; file workstream may be mostly done' }
    @{ Svc = 'WAPCSvc';                      Label = 'Entra App Proxy connector - internal apps already published through Entra' }
    @{ Svc = 'svagents';                     Label = 'Azure Site Recovery mobility service - ASR replication configured; IaaS lift may be one failover away' }
    @{ Svc = 'adfssrv';                      Label = 'AD FS federation service - federated identity; identity design changes materially' }
    @{ Svc = 'frxsvc';                       Label = 'FSLogix profile containers - profiles already containerized; AVD/RDS profile workstream simplified' }
    @{ Svc = 'AADConnectProvisioningAgent';  Label = 'Entra Cloud Sync provisioning agent - lightweight sync already in place (instead of/alongside full Entra Connect)' }
    @{ Svc = 'PrintixService';               Label = 'Printix client - print management already cloud-based; print workstream simplified' }
)
$foundAgent = $false
foreach ($a in $agentMap) {
    $svc = Get-Service -Name $a.Svc -ErrorAction SilentlyContinue
    if ($svc) { Write-Line "  FOUND: $($a.Label) [service: $($a.Svc), status: $($svc.Status)]"; $foundAgent = $true }
}
if (-not $foundAgent) { Write-Line '  None of the known Azure/hybrid agents present on this server.' }

$exch = Get-Service -Name 'MSExchange*' -ErrorAction SilentlyContinue
if ($exch) {
    Write-Line 'FLAG: On-prem Exchange services detected - Exchange (or a hybrid management remnant) lives here. Mail workstream + recipient-management design required:'
    Write-Line ($exch | Select-Object Name, Status | Format-Table -AutoSize)
} else {
    Write-Line 'No on-prem Exchange services.'
}

# ============================================================================
# 14. NETWORK / AUTH POSTURE / DEPENDENCY MAP
# ============================================================================
Write-Section '14. NETWORK / REMOTE ACCESS / DEPENDENCY MAP'
Write-Line (Get-NetIPConfiguration -ErrorAction SilentlyContinue |
    Select-Object InterfaceAlias,
        @{N = 'IPv4'; E = { $_.IPv4Address.IPAddress } },
        @{N = 'Gateway'; E = { $_.IPv4DefaultGateway.NextHop } },
        @{N = 'DNS'; E = { $_.DNSServer.ServerAddresses -join ',' } } |
    Format-Table -AutoSize)
$rras = Get-Service RemoteAccess -ErrorAction SilentlyContinue
if ($rras) { Write-Line "RRAS/VPN service: $($rras.Status) / $($rras.StartType)" }

Write-Line 'Hosts file entries (hardcoded overrides break silently after migration):'
$hostsLines = Get-Content "$env:WINDIR\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue |
    Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' }
if ($hostsLines) { Write-Line ($hostsLines -join "`r`n"); Write-Line 'FLAG: non-default hosts entries present - map each to its post-migration answer.' }
else { Write-Line '  (none - default hosts file)' }

$procById = @{}
Get-Process | ForEach-Object { $procById[$_.Id] = $_.ProcessName }
$listenConns = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue
$listenPorts = @{}
$listenConns | ForEach-Object { $listenPorts[[int]$_.LocalPort] = $true }

Write-Line 'Listening TCP ports -> owning process (what depends ON this box):'
Write-Line ($listenConns |
    Where-Object { $_.LocalAddress -notmatch '^(::1|127\.)' } |
    Sort-Object LocalPort -Unique |
    Select-Object LocalAddress, LocalPort,
        @{N = 'PID'; E = { $_.OwningProcess } },
        @{N = 'Process'; E = { $procById[[int]$_.OwningProcess] } } |
    Format-Table -AutoSize)

Write-Line 'Established OUTBOUND connections -> remote endpoint by process (what this box depends on: license servers, vendor clouds, replication partners):'
Write-Line (Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
    Where-Object { $_.RemoteAddress -notmatch '^(::1|127\.|0\.0\.0\.0)' -and -not $listenPorts.ContainsKey([int]$_.LocalPort) } |
    Group-Object RemoteAddress, RemotePort, OwningProcess |
    ForEach-Object {
        $first = $_.Group[0]
        [pscustomobject]@{
            RemoteAddress = $first.RemoteAddress
            RemotePort    = $first.RemotePort
            Process       = $procById[[int]$first.OwningProcess]
            Connections   = $_.Count
        }
    } | Sort-Object Connections -Descending | Select-Object -First 40 | Format-Table -AutoSize)

# ============================================================================
# 15. GPP MAPPED DRIVES + LOGON SCRIPTS (workstation UNC dependencies)
# ============================================================================
Write-Section '15. GPP MAPPED DRIVES + LOGON SCRIPTS'
if ($isDC) {
    $sysvolPolicies = "\\$($cs.Domain)\SYSVOL\$($cs.Domain)\Policies"
    if (Test-Path $sysvolPolicies) {
        $driveXml = Get-ChildItem -Path $sysvolPolicies -Recurse -Filter 'Drives.xml' -ErrorAction SilentlyContinue
        if ($driveXml) {
            Write-Line 'GPP drive mappings (every UNC here is a file-cutover line item):'
            foreach ($f in $driveXml) {
                try {
                    [xml]$x = Get-Content -LiteralPath $f.FullName -ErrorAction Stop
                    foreach ($d in $x.Drives.Drive) {
                        Write-Line ("  {0}: -> {1}  [GPO GUID path: {2}]" -f $d.Properties.letter, $d.Properties.path, ($f.DirectoryName -replace [regex]::Escape($sysvolPolicies), ''))
                    }
                } catch { Write-Line "  Could not parse $($f.FullName): $($_.Exception.Message)" }
            }
        } else { Write-Line 'No GPP Drives.xml found in SYSVOL.' }
        Write-Line 'NETLOGON script files:'
        Write-Line (Get-ChildItem -Path "\\$($cs.Domain)\NETLOGON" -ErrorAction SilentlyContinue |
            Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize)
    } else { Write-Line 'SYSVOL path not reachable.' }
    if (Get-Command Get-ADUser -ErrorAction SilentlyContinue) {
        Write-Line 'Users with legacy scriptPath set:'
        Write-Line (Get-ADUser -Filter { Enabled -eq $true } -Properties scriptPath |
            Where-Object { $_.scriptPath } |
            Group-Object scriptPath | Select-Object Count, Name | Format-Table -AutoSize)
    }
} else {
    Write-Line 'Not a DC - GPP/logon-script enumeration runs on the DC.'
}

# ============================================================================
# 16. NTLM AUTHENTICATION AUDIT (cloud-only blocker + H2 2026 NTLM deprecation)
# ============================================================================
Write-Section "16. NTLM AUTH AUDIT (Security 4624, last $NtlmAuditDays days, capped 5000 events)"
if ($NtlmAuditDays -gt 0) {
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName = 'Security'; Id = 4624
            StartTime = (Get-Date).AddDays(-$NtlmAuditDays)
        } -MaxEvents 5000 -ErrorAction Stop
        $ntlmHits = foreach ($e in $events) {
            $x = [xml]$e.ToXml()
            $get = { param($n) ($x.Event.EventData.Data | Where-Object { $_.Name -eq $n }).'#text' }
            $lm = & $get 'LmPackageName'
            if ($lm -and $lm -ne '-') {
                [pscustomobject]@{
                    NtlmVersion = $lm
                    Account     = & $get 'TargetUserName'
                    Source      = & $get 'WorkstationName'
                    SourceIP    = & $get 'IpAddress'
                }
            }
        }
        if ($ntlmHits) {
            Write-Line 'NTLM logons by version/source (these break under cloud-only Kerberos/modern auth AND under the H2 2026 NTLM deprecation):'
            Write-Line ($ntlmHits | Group-Object NtlmVersion, Source, Account |
                Sort-Object Count -Descending |
                Select-Object Count, Name -First 40 | Format-Table -AutoSize)
            $v1 = @($ntlmHits | Where-Object { $_.NtlmVersion -eq 'NTLM V1' })
            if ($v1.Count -gt 0) { Write-Line "FLAG: $($v1.Count) NTLMv1 logons observed - hard blocker, remediate regardless of migration path." }
        } else {
            Write-Line 'No NTLM logons in sampled window (Kerberos-only within sample - good sign, but sample is capped; not proof of zero NTLM).'
        }
    } catch {
        Write-Line "Security log query failed: $($_.Exception.Message)"
    }
} else {
    Write-Line 'Disabled via ntlmAuditDays=0.'
}

# ============================================================================
# 17. BACKUP POSTURE (feeds Phase 5 hold + Azure Backup design)
# ============================================================================
Write-Section '17. BACKUP POSTURE'
Write-Line 'Backup product services detected:'
$bkp = Get-Service -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'Veeam|Lockhart|CloudBerry|MSP360|ShadowProtect|StorageCraft|Datto|Acronis|Backup Exec|Unitrends' -or $_.Name -eq 'obengine' }
if ($bkp) { Write-Line ($bkp | Select-Object Name, DisplayName, Status, StartType | Format-Table -AutoSize) }
else { Write-Line '  No known third-party backup services found.' }
if ($installedRoles | Where-Object { $_.Name -eq 'Windows-Server-Backup' }) {
    Write-Line 'Windows Server Backup versions (last lines):'
    $wb = & "$env:WINDIR\System32\wbadmin.exe" get versions 2>&1
    Write-Line (($wb | Select-Object -Last 12) -join "`r`n")
}
Write-Line 'VSS writers in failed state (pre-existing backup health):'
$vssFailed = (& "$env:WINDIR\System32\vssadmin.exe" list writers 2>&1 | Out-String) -split 'Writer name:' |
    Where-Object { $_ -match 'State:\s+\[\d+\]\s+(?!Stable)' }
if ($vssFailed) { Write-Line (($vssFailed | ForEach-Object { ($_ -split "`n")[0].Trim() }) -join "`r`n") }
else { Write-Line '  All VSS writers stable (or none listed).' }

# ============================================================================
# 18. SCHEDULED TASKS / 19. LOCAL ADMINS / 20. CERTIFICATES
# ============================================================================
Write-Section '18. SCHEDULED TASKS (non-Microsoft, enabled)'
Write-Line (Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskPath -notmatch '\\Microsoft\\' -and $_.State -ne 'Disabled' } |
    Select-Object TaskName, TaskPath, State | Format-Table -AutoSize)

Write-Section '19. LOCAL ADMINISTRATORS'
Write-Line (Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue |
    Select-Object Name, ObjectClass, PrincipalSource | Format-Table -AutoSize)

Write-Section '20. LOCAL MACHINE CERTIFICATES (My store)'
Write-Line (Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
    Select-Object Subject, NotAfter, @{N = 'DnsNames'; E = { $_.DnsNameList -join ',' } } |
    Format-Table -AutoSize)

# ============================================================================
# Wrap-up
# ============================================================================
Write-Section 'DISCOVERY COMPLETE'
Write-Line "Context was: $($contexts -join ' + ')"
if ($IsHyperVGuest) { Write-Line 'NEXT: run this script on the physical host identified in Section 1.' }
if ($IsHyperVHost)  { Write-Line 'NEXT: run this script inside EACH guest VM listed in Section 12.' }
Write-Line 'Then: manual collection (bandwidth, tenant/licensing, LOB vendor statement) + decision tree per KB 3893.'
Write-Line 'Reminder: for gov-contractor clients this output is potentially CUI - Halo ticket / IT Glue only, never BookStack.'

if ($SaveReportToDisk) {
    $reportPath = Join-Path $OutDir "AzMigDiscovery-$env:COMPUTERNAME-$Stamp.txt"
    try {
        $script:ReportLines | Set-Content -Path $reportPath -Encoding UTF8
        Write-Output "Full report saved: $reportPath"
    } catch {
        Write-Output "WARN: report save failed: $($_.Exception.Message)"
    }
    try { Stop-Transcript | Out-Null } catch { Write-Output 'WARN: transcript was not running.' }
}
exit 0
