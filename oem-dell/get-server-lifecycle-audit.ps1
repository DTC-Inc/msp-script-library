<#
.SYNOPSIS
    Read-only server lifecycle audit collector for upgrade-vs-replace quoting.
.DESCRIPTION
    Gathers every input a senior technician needs to quote and review a PowerEdge
    server OS upgrade vs. replacement: identity/hardware, boot/firmware (2022 gate),
    iDRAC remote-recovery readiness, OS, disk, roles, SQL edition, dental/LOB stack,
    and CAL sizing counts. Model-agnostic (T130/T230/T330/T340/T440/etc.). Makes NO
    changes to the system. Pairs with KB page 3801 (decision gates and quote paths).

    Output is a single paste-ready text report on the Output stream (captured by
    NinjaOne stdout and the transcript log). The engineer applies the KB 3801 gates.
.PARAMETER ClientName
    Client/practice name for the report header. Resolution order:
    explicit -ClientName, then $env:ClientName (NinjaOne RMM variable named ClientName),
    then an interactive prompt ONLY when a user session is present, then 'UNSPECIFIED'.
    Not mandatory by design - a mandatory parameter would hang an unattended NinjaOne run.
.EXAMPLE
    .\get-server-lifecycle-audit.ps1 -ClientName 'Centreville Endo'
.EXAMPLE
    # NinjaOne: define a script variable named ClientName; it arrives as $env:ClientName.
.NOTES
    Author: Zach Boogher
    Repo:   msp-script-library/ninjaone/audit/get-server-lifecycle-audit.ps1  (propose ninjaone/audit/ in PR)
    Standards: KB 3299 (PowerShell Engineering Patterns), KB 3344 (Contributing a Script)
    Read-only; inherently idempotent. PowerShell 3.0+ compatible (audits downlevel WMF 3/4 hosts).
#>

#Requires -Version 3.0

[CmdletBinding()]
param(
    [string]$ClientName
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-DTCServerLifecycleAudit {
    [CmdletBinding()]
    param(
        [string]$ClientName = 'UNSPECIFIED'
    )

    $lines = New-Object -TypeName 'System.Collections.Generic.List[string]'

    $lines.Add('========================================================================')
    $lines.Add((" SERVER LIFECYCLE AUDIT  (read-only)   {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm')))
    $lines.Add((" Client : {0}" -f $ClientName))
    $lines.Add((" Host   : {0}" -f $env:COMPUTERNAME))
    $lines.Add(' Apply KB 3801 Section 4 gates. Verify warranty + iDRAC license out-of-band.')
    $lines.Add('========================================================================')

    # ----- IDENTITY / HARDWARE -----
    $lines.Add('')
    $lines.Add('== IDENTITY / HARDWARE ==')
    $cs   = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS
    $cpu  = Get-CimInstance -ClassName Win32_Processor
    $cores = ($cpu | Measure-Object -Property NumberOfCores -Sum).Sum
    $logical = ($cpu | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    $ramGB = [math]::Round((Get-CimInstance -ClassName Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum / 1GB, 0)
    $memArray = Get-CimInstance -ClassName Win32_PhysicalMemoryArray | Select-Object -First 1
    $slotsUsed = (Get-CimInstance -ClassName Win32_PhysicalMemory | Measure-Object).Count
    $maxRamGB = $null
    if ($memArray.MaxCapacityEx) { $maxRamGB = [math]::Round($memArray.MaxCapacityEx / 1MB, 0) }
    elseif ($memArray.MaxCapacity) { $maxRamGB = [math]::Round($memArray.MaxCapacity / 1MB, 0) }

    $lines.Add(("Manufacturer    : {0}" -f $cs.Manufacturer))
    $lines.Add(("Model           : {0}" -f $cs.Model))
    $lines.Add(("Service Tag     : {0}   (look up warranty/ship date at dell.com/support)" -f $bios.SerialNumber))
    $lines.Add(("BIOS version    : {0}" -f $bios.SMBIOSBIOSVersion))
    $lines.Add(("CPU             : {0}" -f (($cpu | Select-Object -First 1).Name).Trim()))
    $lines.Add(("Sockets/Cores   : {0} socket(s), {1} physical, {2} logical" -f ($cpu | Measure-Object).Count, $cores, $logical))
    $lines.Add(("RAM installed   : {0} GB   (slots used {1} of {2})" -f $ramGB, $slotsUsed, $memArray.MemoryDevices))
    if ($maxRamGB) { $lines.Add(("RAM max         : {0} GB   (firmware-reported; confirm against model spec)" -f $maxRamGB)) }

    # Generation / iDRAC inference from the 3-digit model number (T340 -> 14G/iDRAC9, T330 -> 13G/iDRAC8)
    $genText = 'verify'
    $idracGen = 'verify'
    if ($cs.Model -match '[A-Za-z](\d)(\d)0(\b|$)') {
        $gen = 10 + [int]$Matches[2]
        $genText = "{0}G" -f $gen
        if ($gen -le 13) { $idracGen = 'iDRAC8' } else { $idracGen = 'iDRAC9' }
    }
    $lines.Add(("Generation      : {0} (inferred from model)" -f $genText))

    # ----- iDRAC / REMOTE-RECOVERY READINESS -----
    $lines.Add('')
    $lines.Add('== iDRAC / REMOTE-RECOVERY READINESS  (required before any in-place OS upgrade) ==')
    $lines.Add(("iDRAC gen       : {0} (inferred from model)" -f $idracGen))
    $ism = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'iDRAC Service Module' -or $_.Name -eq 'dcism' }
    if ($ism) { $lines.Add(("iDRAC Svc Module: present [{0}]  (OS<->iDRAC pass-through available)" -f ($ism | Select-Object -First 1).Status)) }
    else { $lines.Add('iDRAC Svc Module: not installed (host cannot read iDRAC over USB pass-through)') }
    $idracNic = Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Remote NDIS|iDRAC' }
    if ($idracNic) { $lines.Add(("iDRAC USB NIC   : present ({0})  (iDRAC reachable from host)" -f ($idracNic | Select-Object -First 1).Name)) }
    else { $lines.Add('iDRAC USB NIC   : not detected (OS-to-iDRAC pass-through off, or no iDRAC)') }

    # racadm (native command) - read iDRAC license if the binary is present
    $racadm = Get-Command -Name 'racadm.exe' -ErrorAction SilentlyContinue
    $racPath = $null
    if ($racadm) { $racPath = $racadm.Source }
    if (-not $racPath) {
        foreach ($p in 'C:\Program Files\Dell\SysMgt\iDRACTools\racadm\racadm.exe', 'C:\Program Files\Dell\SysMgt\rac5\racadm.exe') {
            if (Test-Path $p) { $racPath = $p; break }
        }
    }
    $idracLicense = 'UNKNOWN'
    if ($racPath) {
        $lic = & $racPath 'license' 'view' 2>$null
        if ($LASTEXITCODE -eq 0 -and $lic) {
            $licLine = $lic | Where-Object { $_ -match 'License Description|Enterprise|Express|Datacenter' } | Select-Object -First 1
            if ($licLine) { $idracLicense = ($licLine -replace '\s+', ' ').Trim() }
        }
        $nic = & $racPath 'getniccfg' 2>$null
        if ($LASTEXITCODE -eq 0 -and $nic) {
            $ip = $nic | Where-Object { $_ -match 'IP Address' } | Select-Object -First 1
            if ($ip) { $lines.Add(("iDRAC NIC cfg   : {0}" -f ($ip -replace '\s+', ' ').Trim())) }
        }
    }
    $lines.Add(("iDRAC license   : {0}" -f $idracLicense))
    $lines.Add('READINESS NOTE : Virtual Console + Virtual Media (remote OS-upgrade monitoring and')
    $lines.Add('                 catastrophic-failure recovery) require iDRAC Enterprise or Datacenter.')
    $lines.Add('                 Express does NOT include them. If UNKNOWN, confirm in the iDRAC web UI')
    $lines.Add('                 before committing to an in-place upgrade.')

    # ----- OPERATING SYSTEM -----
    $lines.Add('')
    $lines.Add('== OPERATING SYSTEM ==')
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $lines.Add(("OS              : {0}" -f $os.Caption))
    $lines.Add(("Version/Build   : {0}" -f $os.Version))
    $lines.Add(("Architecture    : {0}" -f $os.OSArchitecture))
    $lines.Add(("Installed       : {0}" -f $os.InstallDate))

    # ----- BOOT / FIRMWARE (2022 eligibility) -----
    $lines.Add('')
    $lines.Add('== BOOT / FIRMWARE  (in-place 2022 on 14G needs TPM 2.0 + UEFI + Secure Boot) ==')
    $bootMode = 'UNKNOWN'
    try {
        $sb = Confirm-SecureBootUEFI
        $bootMode = 'UEFI'
        $lines.Add('Boot firmware   : UEFI')
        if ($sb) { $lines.Add('Secure Boot     : ON') } else { $lines.Add('Secure Boot     : OFF') }
    } catch {
        $bootMode = 'LEGACY'
        $lines.Add('Boot firmware   : LEGACY/BIOS (not UEFI) -> BIOS->UEFI conversion is its own project')
        $lines.Add('Secure Boot     : N/A (legacy boot)')
    }
    try {
        $tpm = Get-Tpm
        $lines.Add(("TPM present     : {0}" -f $tpm.TpmPresent))
        $lines.Add(("TPM ready       : {0}" -f $tpm.TpmReady))
        $tpmSpec = (Get-CimInstance -Namespace 'root\cimv2\security\microsofttpm' -ClassName Win32_Tpm -ErrorAction SilentlyContinue).SpecVersion
        $lines.Add(("TPM spec        : {0}" -f $tpmSpec))
    } catch {
        $lines.Add('TPM             : query failed (run elevated; or no TPM present)')
    }

    # ----- DISK / STORAGE (SSD-swap input) -----
    $lines.Add('')
    $lines.Add('== DISK / STORAGE ==')
    try {
        Get-PhysicalDisk | Sort-Object -Property DeviceId | ForEach-Object {
            $lines.Add(("PhysDisk {0}: {1} GB  Media={2}  Bus={3}  Health={4}" -f $_.DeviceId, [math]::Round($_.Size / 1GB, 0), $_.MediaType, $_.BusType, $_.HealthStatus))
        }
    } catch { $lines.Add('PhysDisk        : Get-PhysicalDisk unavailable on this OS') }
    Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $lines.Add(("Volume {0} : {1} GB free of {2} GB" -f $_.DeviceID, [math]::Round($_.FreeSpace / 1GB, 1), [math]::Round($_.Size / 1GB, 1)))
    }

    # ----- SERVER ROLES (CAL + workload drivers) -----
    $lines.Add('')
    $lines.Add('== SERVER ROLES ==')
    $domainRole = $cs.DomainRole   # 4/5 = DC
    $isDC = $domainRole -in 4, 5
    if ($isDC) { $lines.Add(("Domain role     : {0} (DOMAIN CONTROLLER)" -f $domainRole)) }
    else { $lines.Add(("Domain role     : {0} (member/standalone)" -f $domainRole)) }
    $features = $null
    try { Import-Module ServerManager -ErrorAction Stop; $features = Get-WindowsFeature | Where-Object { $_.Installed } } catch { $features = $null }
    if ($features) {
        $watch = 'AD-Domain-Services', 'DNS', 'DHCP', 'FS-FileServer', 'Hyper-V', 'RDS-RD-Server', 'RDS-Connection-Broker', 'RDS-Gateway', 'Remote-Desktop-Services', 'Web-Server', 'Print-Services'
        $features | Where-Object { $watch -contains $_.Name } | ForEach-Object { $lines.Add(("Role/Feature    : {0}  ({1})" -f $_.DisplayName, $_.Name)) }
        $rds = $features | Where-Object { $_.Name -like 'RDS-*' -or $_.Name -eq 'Remote-Desktop-Services' }
        if ($rds) { $lines.Add('RDS role active : TRUE   -> RDS User CALs (SFT-083 2022 / SFT-112 2025) apply') }
        else { $lines.Add('RDS role active : FALSE  -> do NOT quote RDS User CALs') }
        if ($features | Where-Object { $_.Name -eq 'Hyper-V' }) { $lines.Add('Hyper-V HOST    : TRUE   -> treat per host build standard, not a simple upgrade') }
    } else {
        $lines.Add('Roles           : Get-WindowsFeature unavailable (non-Server SKU or module missing) - confirm manually')
    }

    # ----- SQL (license trigger) -----
    $lines.Add('')
    $lines.Add('== SQL SERVER INSTANCES  (SFT-107 applies ONLY for a licensed edition; Express/LocalDB are free) ==')
    $sqlInstances = New-Object -TypeName 'System.Collections.Generic.List[string]'
    try {
        $instKey = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop
        $instKey.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
            $instId = $_.Value
            $setup = Get-ItemProperty -Path ("HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\{0}\Setup" -f $instId) -ErrorAction SilentlyContinue
            $sqlInstances.Add($_.Name)
            $lines.Add(("SQL instance    : {0}   Edition='{1}'   Version={2}" -f $_.Name, $setup.Edition, $setup.Version))
        }
    } catch {
        Write-Verbose "SQL instance enumeration skipped: $_"
    }
    if ($sqlInstances.Count -eq 0) { $lines.Add('SQL instance    : none detected via registry') }
    $lines.Add('NOTE: PBS Endo IS SQL-backed and is a known SFT-107 driver. SoftDent/Dentrix use')
    $lines.Add('      FairCom c-tree (no SQL license). Quote SFT-107 only when Edition reads')
    $lines.Add('      Standard/Web/Enterprise; confirm exact edition + version first.')

    # ----- DENTAL / LOB SOFTWARE -----
    $lines.Add('')
    $lines.Add('== DENTAL / LOB SOFTWARE DETECTED  (map each to its compat page in Dental Apps Book 70) ==')
    $patterns = 'SoftDent', 'Carestream', 'CS Imaging', 'PracticeWorks', 'Dentrix', 'Eaglesoft', 'Open Dental', 'OpenDental', 'PBS Endo', 'PBSEndo', 'DEXIS', 'Sidexis', 'EZDent', 'Vatech', 'EzServer', 'Apteryx', 'Romexis', 'Planmeca', 'MiPACS'
    $uninstallPaths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $installed = foreach ($path in $uninstallPaths) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | ForEach-Object { [pscustomobject]@{ Name = $_.DisplayName; Version = $_.DisplayVersion } }
    }
    $matched = $installed | Where-Object { $name = $_.Name; ($patterns | Where-Object { $name -match [regex]::Escape($_) }) } | Sort-Object -Property Name -Unique
    if ($matched) { $matched | ForEach-Object { $lines.Add(("Installed app   : {0}  v{1}" -f $_.Name, $_.Version)) } }
    else { $lines.Add('Installed app   : no known dental LOB matched in uninstall registry (verify; some do not register)') }
    Get-Service -ErrorAction SilentlyContinue | Where-Object { $svc = $_.DisplayName; ($patterns | Where-Object { $svc -match [regex]::Escape($_) }) } | ForEach-Object { $lines.Add(("Service         : {0} [{1}]" -f $_.DisplayName, $_.Status)) }
    if (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -in 'ctreesql', 'DentrixACEServer', 'FairComEdge' }) { $lines.Add('DB engine       : FairCom c-tree present (no SQL license needed)') }

    # ----- CAL SIZING INPUTS -----
    $lines.Add('')
    $lines.Add('== CAL SIZING INPUTS  (Device CALs billed per device; marked individually, do NOT round to 5-packs) ==')
    if ($isDC) {
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            $userCount = (Get-ADUser -Filter 'Enabled -eq $true' | Measure-Object).Count
            $wsCount = (Get-ADComputer -Filter "OperatingSystem -notlike '*Server*'" | Measure-Object).Count
            $lines.Add(("AD enabled users     : {0}" -f $userCount))
            $lines.Add(("AD workstations      : {0}" -f $wsCount))
            $lines.Add(("Device CALs needed   : {0}  (1 per device, marked individually - do NOT round to 5-packs)  [SFT-109 for 2022 / SFT-111 for 2025]" -f $wsCount))
        } catch { $lines.Add('AD counts            : ActiveDirectory module unavailable - count users/devices at the DC') }
    } else {
        $lines.Add('Not a DC - pull enabled user + workstation counts from the domain DC to size CALs.')
    }

    # ----- DECISION INPUTS SUMMARY -----
    $lines.Add('')
    $lines.Add('== DECISION INPUTS -> KB 3801 Section 4 gates (senior tech makes the call) ==')
    $lines.Add(("Gate 1 OS ceiling   : model {0} ({1}) -> ceiling per KB 3801 matrix vs dental-stack OS support" -f $cs.Model, $genText))
    $lines.Add(("Gate 2 current OS   : {0}" -f $os.Caption))
    $lines.Add(("Gate 3 hardware     : warranty -> look up tag {0} at dell.com/support" -f $bios.SerialNumber))
    $lines.Add(("Gate 4 capacity     : {0} GB RAM, {1} cores (max {2} GB per firmware)" -f $ramGB, $cores, $maxRamGB))
    $lines.Add(("Upgrade gate (2022) : Boot={0}; iDRAC license={1} (Enterprise/Datacenter needed for remote recovery)" -f $bootMode, $idracLicense))
    $lines.Add('========================================================================')

    return ($lines -join "`r`n")
}

# ---- main (skipped when dot-sourced for Pester: '. .\get-server-lifecycle-audit.ps1') ----
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $ClientName) { $ClientName = $env:ClientName }
    if (-not $ClientName -and [Environment]::UserInteractive) { $ClientName = Read-Host -Prompt 'Client name' }
    if (-not $ClientName) { $ClientName = 'UNSPECIFIED' }

    $logDir = 'C:\DTC\Logs'
    $logPath = Join-Path -Path $logDir -ChildPath ("server-lifecycle-audit-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    Start-Transcript -Path $logPath -Append | Out-Null

    try {
        Write-Output ("Auditing {0} for client '{1}'" -f $env:COMPUTERNAME, $ClientName)
        $report = Get-DTCServerLifecycleAudit -ClientName $ClientName
        Write-Output $report
        exit 0
    } catch {
        Write-Error ("FAILED: {0}" -f $_)
        Write-Error $_.ScriptStackTrace
        exit 1
    } finally {
        Stop-Transcript | Out-Null
    }
}
