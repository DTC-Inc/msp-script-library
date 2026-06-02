## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                                          - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description                                  - Ticket # or initials for audit trail
## $env:RMMScriptPath                                - Optional log directory base provided by the RMM
##
## Host-class fields READ via Ninja-Property-Get (written by msft-windows-host-classification.ps1):
## $env:CustomFieldHostClassIsHyperVHost             - default: "hostClassIsHyperVHost"
## $env:CustomFieldHostClassIsWindowsServer          - default: "hostClassIsWindowsServer"
## $env:CustomFieldHostClassIsDomainController       - default: "hostClassIsDomainController"
##
## Anthropic API (REQUIRED only when hard signals come back PENDING):
## $env:anthropicApiKey                              - Anthropic API key. Set in the RMM script preset (or Read-Host in interactive mode).
## $env:ClaudeJitterMaxSeconds                       - Fleet jitter. Max random delay (seconds) before the Claude call so a
##                                                     mass RMM run doesn't hit the API all at once. Default 600 (10 min).
##                                                     10 min ONLY fits Tier 2+ (1000 RPM); at Tier 1 (50 RPM) ~8000 endpoints
##                                                     need ~5 hours (~18000s). Set 0 to disable.
##
## Backup-discovery fields WRITTEN by this script --------------------------
## $env:CustomFieldBackupDiscoveryHasDatabase        - Boolean (1/0)  default: "backupDiscoveryHasDatabase"
## $env:CustomFieldBackupDiscoveryNeedsBackup        - Boolean (1/0)  default: "backupDiscoveryNeedsBackup"
## $env:CustomFieldBackupDiscoveryDecisionReason     - Text          default: "backupDiscoveryDecisionReason"
## $env:CustomFieldBackupDiscoveryAIVerdict          - Text          default: "backupDiscoveryAIVerdict"  ("not-required" / "pending" / "needed" / "not-needed")
## $env:CustomFieldBackupDiscoveryDetails            - WYSIWYG/HTML  default: "backupDiscoveryDetails"
## $env:CustomFieldBackupDiscoveryAIPayload          - Multi-line    default: "backupDiscoveryAIPayload"

# Backup Eligibility Discovery (SYSTEM context)
#
# Companion to msft-windows/msft-windows-host-classification.ps1. The
# inventory script writes the host-class fields (hostClassIs*); this
# script READS them via Ninja-Property-Get and decides whether the
# machine needs to be backed up. Falls back to local detection when the
# Ninja read returns null/missing/error so the script is resilient to
# "inventory hasn't run yet" cases.
#
# Decision rule (hard signals first; Claude is asked when hard signals
# can't decide):
#   - Hyper-V host                              -> NO  (the VMs get backed up)
#   - Domain Controller                         -> YES
#   - Windows Server (bare metal or VM)         -> YES
#   - Non-embedded database services present    -> YES
#   - Otherwise (workstation, no DC/server/DB)  -> CLAUDE (Opus 4.7)
#
# When the hard signals can't decide, the script gathers soft signals
# (local user profile data census, SMB file shares) and calls the
# Anthropic Messages API directly with the payload. Claude returns
# yes/no + reasoning + a SHORT_SUMMARY line; the script writes the
# final needsBackup and AIVerdict fields.
#
# Claude failure handling: the script will not exit until it has either
# (a) gotten a parseable verdict from Claude or (b) exhausted its retry
# budget on transient failures. Auth/config errors are fatal immediately
# (no retry). The script's job is to produce a verdict; if it can't, it
# exits non-zero so the RMM job lights up red.
#
# Exit codes:
#   0  -- normal completion: hard signals decided, or Claude returned a
#         parseable verdict. The verdict itself (yes/no) is data and
#         lives in the custom fields, not in the exit code.
#   1  -- Claude was needed but unreachable/unparseable after retries.
#   2  -- Claude was needed but authentication / configuration failed
#         (anthropicApiKey missing or rejected with 401/403/400).

$ScriptLogName = "bdr-discovery-needs-backup-detect.log"

# --- Default RMM environment variables if not provided -------------------

if ([string]::IsNullOrEmpty($env:CustomFieldHostClassIsHyperVHost))       { $env:CustomFieldHostClassIsHyperVHost       = "hostClassIsHyperVHost" }
if ([string]::IsNullOrEmpty($env:CustomFieldHostClassIsWindowsServer))    { $env:CustomFieldHostClassIsWindowsServer    = "hostClassIsWindowsServer" }
if ([string]::IsNullOrEmpty($env:CustomFieldHostClassIsDomainController)) { $env:CustomFieldHostClassIsDomainController = "hostClassIsDomainController" }

if ([string]::IsNullOrEmpty($env:CustomFieldBackupDiscoveryHasDatabase))    { $env:CustomFieldBackupDiscoveryHasDatabase    = "backupDiscoveryHasDatabase" }
if ([string]::IsNullOrEmpty($env:CustomFieldBackupDiscoveryNeedsBackup))    { $env:CustomFieldBackupDiscoveryNeedsBackup    = "backupDiscoveryNeedsBackup" }
if ([string]::IsNullOrEmpty($env:CustomFieldBackupDiscoveryDecisionReason)) { $env:CustomFieldBackupDiscoveryDecisionReason = "backupDiscoveryDecisionReason" }
if ([string]::IsNullOrEmpty($env:CustomFieldBackupDiscoveryAIVerdict))      { $env:CustomFieldBackupDiscoveryAIVerdict      = "backupDiscoveryAIVerdict" }
if ([string]::IsNullOrEmpty($env:CustomFieldBackupDiscoveryDetails))        { $env:CustomFieldBackupDiscoveryDetails        = "backupDiscoveryDetails" }
if ([string]::IsNullOrEmpty($env:CustomFieldBackupDiscoveryAIPayload))      { $env:CustomFieldBackupDiscoveryAIPayload      = "backupDiscoveryAIPayload" }

# --- Input handling: RMM vs interactive ----------------------------------

if ($env:RMM -ne "1") {
    $ValidInput = 0
    while ($ValidInput -ne 1) {
        $env:Description = Read-Host "Please enter the ticket # and/or your initials for audit trail"
        if ($env:Description) { $ValidInput = 1 } else { Write-Host "Invalid input. Please try again." }
    }
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"
} else {
    if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
        $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$env:WINDIR\logs\$ScriptLogName"
    }
    if ([string]::IsNullOrEmpty($env:Description)) {
        Write-Host "Description is null. This was most likely run automatically from the RMM."
        $env:Description = "RMM Automated Scan"
    }
}

$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

Start-Transcript -Path $LogPath

Write-Host "============================================"
Write-Host "Backup Eligibility Discovery"
Write-Host "============================================"
Write-Host ""
Write-Host "Description : $env:Description"
Write-Host "Log path    : $LogPath"
Write-Host "RMM         : $env:RMM"
Write-Host "Running as  : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host "Scan time   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "Host        : $env:COMPUTERNAME"
Write-Host ""

# =====================================================================
# Helpers
# =====================================================================

# Ninja-Property-Get returns the error string as the apparent value
# when the field doesn't exist (documented in CLAUDE.md). Wrap it: if
# the return looks like an error message or is null/empty, treat as
# missing and return $null so the caller can fall back.
function Read-NinjaPropertyOrNull {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $null }
    if ($env:RMM -ne "1") { return $null }
    if (-not (Get-Command Ninja-Property-Get -ErrorAction SilentlyContinue)) { return $null }
    try {
        $raw = Ninja-Property-Get -Name $Name -ErrorAction Stop
    } catch {
        Write-Host "  Ninja-Property-Get failed for '$Name': $_"
        return $null
    }
    if ($null -eq $raw) { return $null }
    $str = "$raw".Trim()
    if ($str -eq "") { return $null }
    if ($str -like "Unable to find the specified field*") {
        Write-Host "  '$Name' is not defined in the tenant -- will detect locally."
        return $null
    }
    return $str
}

# Coerce a Ninja boolean field read (which may come back as "1"/"0"/"true"/"false")
# into a real bool. Returns $null if the value can't be coerced.
function ConvertTo-NinjaBool {
    param($Value)
    if ($null -eq $Value) { return $null }
    $s = "$Value".Trim().ToLowerInvariant()
    if ($s -in @("1","true","yes","on"))  { return $true }
    if ($s -in @("0","false","no","off")) { return $false }
    return $null
}

# =====================================================================
# Host-class signals -- prefer Ninja-Property-Get, fall back to local detection
# =====================================================================

function Detect-IsHyperVHost {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    $isServer = $false
    if ($os) { $isServer = ([int]$os.ProductType -eq 2 -or [int]$os.ProductType -eq 3) }
    $vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if ($vmms -and $isServer) { return $true }
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        try {
            $hv = Get-WindowsFeature -Name Hyper-V -ErrorAction Stop
            if ($hv.Installed) { return $true }
        } catch {}
    }
    return $false
}

function Detect-IsWindowsServer {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if (-not $os) { return $false }
    return ([int]$os.ProductType -eq 2 -or [int]$os.ProductType -eq 3)
}

function Detect-IsDomainController {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
    if ($os -and [int]$os.ProductType -eq 2) { return $true }
    if (Get-Service -Name NTDS -ErrorAction SilentlyContinue) { return $true }
    if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
        try {
            $adds = Get-WindowsFeature -Name AD-Domain-Services -ErrorAction Stop
            if ($adds.Installed) { return $true }
        } catch {}
    }
    return $false
}

function Resolve-HostClassSignal {
    param(
        [string]$FieldName,
        [scriptblock]$LocalDetector,
        [string]$Label
    )
    $raw = Read-NinjaPropertyOrNull -Name $FieldName
    $fromNinja = ConvertTo-NinjaBool -Value $raw
    if ($null -ne $fromNinja) {
        Write-Host ("  {0}: {1}  (source: Ninja '{2}')" -f $Label, $fromNinja, $FieldName)
        return [pscustomobject]@{ Value = $fromNinja; Source = "ninja" }
    }
    $local = [bool](& $LocalDetector)
    Write-Host ("  {0}: {1}  (source: local detection -- inventory script may not have run yet)" -f $Label, $local)
    return [pscustomobject]@{ Value = $local; Source = "local" }
}

Write-Host "Resolving host-class signals..."
$hyperVHost = Resolve-HostClassSignal -FieldName $env:CustomFieldHostClassIsHyperVHost       -LocalDetector { Detect-IsHyperVHost }       -Label "isHyperVHost"
$winServer  = Resolve-HostClassSignal -FieldName $env:CustomFieldHostClassIsWindowsServer    -LocalDetector { Detect-IsWindowsServer }    -Label "isWindowsServer"
$dc         = Resolve-HostClassSignal -FieldName $env:CustomFieldHostClassIsDomainController -LocalDetector { Detect-IsDomainController } -Label "isDomainController"
Write-Host ""

# =====================================================================
# Backup-specific signal: database services with embedded classification
# =====================================================================

function Test-HasDatabase {
    $details = [ordered]@{ matched = $false; matchedNonEmbedded = $false; services = @() }

    # Database engine catalog. Each engine matches on service Name and/or
    # DisplayName (dental engines register under names that don't look like
    # "SQL" at all, so DisplayName matching is required -- the old Name-only
    # filter missed every proprietary dental engine). CustomerData=$true means
    # the engine, when present, IS by definition the practice's live data
    # (dental PMS, QuickBooks company file). Those never store mere app
    # telemetry, so they force a hard YES regardless of install path. The
    # enterprise SQL engines (CustomerData=$false) stay subject to the
    # embedded-host-app path check below, because RMM/AV/backup products
    # routinely bundle SQL Express to hold only their own state.
    $engines = @(
        # --- Enterprise SQL engines (path-checked for embedded host apps) ---
        @{ Label='Microsoft SQL Server'; Customer=$false; Name=@('MSSQL*');                  Display=@('*SQL Server (*') },
        @{ Label='MySQL / MariaDB';      Customer=$false; Name=@('MySQL*','MariaDB*');        Display=@('*MySQL*','*MariaDB*') },
        @{ Label='PostgreSQL';           Customer=$false; Name=@('postgresql*','postgres-*'); Display=@('*PostgreSQL*') },
        @{ Label='Oracle';               Customer=$false; Name=@('OracleService*');           Display=@('*OracleService*') },
        @{ Label='MongoDB';              Customer=$false; Name=@('MongoDB');                   Display=@('*MongoDB*') },
        @{ Label='Redis';                Customer=$false; Name=@('Redis');                     Display=@('*Redis*') },
        # --- Dental PMS + QuickBooks engines (always customer data -> hard YES) ---
        # SQL Anywhere is the general Eaglesoft/Sybase engine (service SQLANYs_*).
        @{ Label='SAP SQL Anywhere (Eaglesoft / Sybase)'; Customer=$true; Name=@('SQLANYs_*'); Display=@('*SQL Anywhere*','*Sybase*') },
        # Eaglesoft server-side service (Patterson DB engine) as a belt-and-suspenders label.
        @{ Label='Eaglesoft (Patterson) database';        Customer=$true; Name=@();            Display=@('*Patterson*Database*','*Eaglesoft*Database*') },
        # Dentrix G5/G6/early-G7 engine.
        @{ Label='Pervasive / Actian PSQL (Dentrix)';     Customer=$true; Name=@('Pervasive*','psqlWGE','psqlSRV'); Display=@('*Pervasive*','*Actian*') },
        # Oldest Dentrix engine: FairCom c-tree behind the "Dentrix Ace Server" service.
        @{ Label='Dentrix Ace Server / FairCom c-tree';   Customer=$true; Name=@('DentrixAceServer','FairCom*'); Display=@('*Dentrix Ace Server*','*FairCom*','*c-tree*') },
        # DEXIS / DTX Studio proprietary core (imaging + patient DB).
        @{ Label='DTX Studio Core (DEXIS)';               Customer=$true; Name=@();            Display=@('*DTX Studio Core*') },
        # QuickBooks multi-user host (company file).
        @{ Label='QuickBooks Database Server';            Customer=$true; Name=@('QuickBooksDB*'); Display=@('*QuickBooks*Database*') }
    )

    # Companion / helper services -- recorded for context but NEVER a trigger on
    # their own. SQLWriter (VSS writer), SQLBrowser (UDP name resolution),
    # SQLAgent (job scheduler), QBCFMonitorService (QB file monitor) and the
    # full-text/telemetry helpers all install alongside an engine and can be
    # present with no customer database on THIS box, so they must not flip the
    # backup decision by themselves -- the real engine service does that.
    $companionPatterns = @('SQLWriter','SQLBrowser','SQLAgent*','QBCFMonitorService','MSSQLFDLauncher*','SQLTELEMETRY*')

    # Path patterns for KNOWN-embedded DBs -- a CustomerData=$false engine whose
    # ImagePath sits under one of these stores app/state, not customer data.
    $embeddedHostApps = @(
        'Veeam','NinjaRMM','NinjaOne','Acronis','Sophos','Huntress',
        'ManageEngine','ConnectWise','LabTech','Automate','Kaseya','Datto',
        'N-able','SolarWinds','BackupExec','CarbonBlack','CrowdStrike',
        'Blackpoint','SentinelOne','Webroot','Bitdefender','Cynet',
        'PrintAudit','PaperCut'
    )

    $allSvcs = Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue
    foreach ($s in $allSvcs) {
        $name = "$($s.Name)"
        $disp = "$($s.DisplayName)"

        # Does this service match a catalog engine (by Name OR DisplayName)?
        $engine = $null
        foreach ($e in $engines) {
            $hit = $false
            foreach ($p in $e.Name)    { if ($name -like $p) { $hit = $true; break } }
            if (-not $hit) { foreach ($p in $e.Display) { if ($disp -like $p) { $hit = $true; break } } }
            if ($hit) { $engine = $e; break }
        }

        # Is it a companion/helper (checked independently -- a companion never
        # triggers, even if its name also matches an engine pattern e.g. MSSQLFDLauncher)?
        $isCompanion = $false
        foreach ($c in $companionPatterns) { if ($name -like $c) { $isCompanion = $true; break } }

        if (-not $engine -and -not $isCompanion) { continue }

        $imagePath = "$($s.PathName)".Trim('"').Trim()

        if ($isCompanion) {
            $details.services += [pscustomobject]@{
                Name=$name; DisplayName=$disp; State=$s.State; StartMode=$s.StartMode
                Account=$s.StartName; Path=$imagePath
                Engine=$(if ($engine) { $engine.Label } else { 'SQL companion service' })
                Embedded=$false; HostApp=''; Companion=$true; CustomerData=$false
            }
            continue
        }

        # Real engine. Embedded check applies only to enterprise SQL.
        $isEmbedded = $false
        $hostApp = ''
        if (-not $engine.Customer) {
            foreach ($app in $embeddedHostApps) {
                if ($imagePath -like "*$app*") { $isEmbedded = $true; $hostApp = $app; break }
            }
        }

        $details.matched = $true
        if (-not $isEmbedded) { $details.matchedNonEmbedded = $true }
        $details.services += [pscustomobject]@{
            Name=$name; DisplayName=$disp; State=$s.State; StartMode=$s.StartMode
            Account=$s.StartName; Path=$imagePath
            Engine=$engine.Label
            Embedded=$isEmbedded; HostApp=$hostApp; Companion=$false
            CustomerData=[bool]$engine.Customer
        }
    }
    return $details
}

# SoftDent (Carestream; lineage DMD -> PracticeWorks -> Kodak -> Carestream)
# stores its core PMS data as FairCom c-tree FLAT FILES -- no monitorable
# service and no distinctive file extension -- so service/extension scans can't
# find it. Its config lives under HKLM\SOFTWARE\PWInc (PracticeWorks Inc), and
# the PWSvr (license/data server) component marks the box that hosts the shared
# data set. That registry hive is the only reliable "this machine IS the
# SoftDent server" signal. Exact value names vary by version, so we detect the
# PWInc hive, infer the server role from a PWSvr subkey / PWsvr service-process,
# and surface any registry value that resolves to an existing directory as the
# likely data path. Confirm value names against a live SoftDent server.
function Test-SoftDentServer {
    $result = [ordered]@{ Installed=$false; IsServer=$false; DataPath=$null; Keys=@() }
    $roots = @('HKLM:\SOFTWARE\PWInc','HKLM:\SOFTWARE\WOW6432Node\PWInc')

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $result.Installed = $true
        $result.Keys += $root

        # Server role: a PWSvr (or *Server*) subkey under PWInc.
        try {
            foreach ($sk in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                if ($sk.PSChildName -like 'PWSvr*' -or $sk.PSChildName -like '*Server*') { $result.IsServer = $true }
            }
        } catch {}

        # Scan root + one level of subkeys for a value that is an existing dir.
        $scanKeys = @($root)
        try { $scanKeys += (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PSPath) } catch {}
        foreach ($k in $scanKeys) {
            try {
                $props = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
                if ($null -eq $props) { continue }
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -in @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider')) { continue }
                    $v = "$($p.Value)"
                    if ($v -match '^[A-Za-z]:\\' -and (Test-Path -LiteralPath $v -PathType Container -ErrorAction SilentlyContinue)) {
                        if (-not $result.DataPath) { $result.DataPath = $v }
                    }
                }
            } catch {}
        }
    }

    # PWsvr.exe process / service is a strong server-role corroborator.
    if ($result.Installed -and -not $result.IsServer) {
        if (Get-Process -Name 'PWsvr' -ErrorAction SilentlyContinue) {
            $result.IsServer = $true
        } elseif (Get-CimInstance -ClassName Win32_Service -Filter "Name='PWsvr' OR Name='PWLicenseServer'" -ErrorAction SilentlyContinue) {
            $result.IsServer = $true
        }
    }
    return $result
}

# =====================================================================
# Soft signals (for downstream AI evaluation)
# =====================================================================

# Extension census fed to Claude. Grouped for readability; the script
# treats them all the same (a count per extension under the user
# profile / share). When in doubt, add: Claude weights the mix, the
# cost of an extra extension key in the census is negligible.
$soft_DataExtensions = @(
    # Office -- Word / Excel / PowerPoint (incl. macro-enabled + templates)
    '.docx','.doc','.docm','.dotx','.dotm',
    '.xlsx','.xls','.xlsm','.xlsb','.xltx','.xltm',
    '.pptx','.ppt','.pptm','.potx','.potm',
    # Office -- OneNote / generic text / PDFs
    '.one','.onepkg','.pdf','.csv','.tsv','.txt','.rtf','.md',
    # Email stores + saved messages (OST omitted -- it's an offline
    # cache of an Exchange/M365 mailbox and the cloud is the source
    # of truth; mailbox is already backed up online.)
    '.pst','.eml','.msg','.mbox',
    # Microsoft Access / generic local databases / dumps + backups
    '.accdb','.mdb','.db','.sqlite','.sqlite3','.dbf','.sql','.bak',
    # QuickBooks / accounting
    '.qbw','.qbb','.qbm','.qba','.qbo','.iif',
    # Designer / creative
    '.psd','.ai','.indd','.afdesign','.afphoto','.sketch','.fig',
    # CAD / engineering
    '.dwg','.dxf','.cad','.stp','.step','.iges','.igs','.skp',
    # Medical / dental imaging. DICOM (.dcm/.dicom) is the industry standard
    # most dental suites export to (Sidexis, CS, Dentrix/Eaglesoft imaging).
    # .dex is DEXIS's proprietary loose-file X-ray format. All are
    # unreplaceable patient records and HIPAA-relevant.
    '.dcm','.dicom','.dex',
    # Virtual disks -- local VMs almost always hold business data
    '.vhd','.vhdx','.vmdk','.vdi','.qcow2','.ova','.ovf',
    # Archives (often contain dumps / exports)
    '.zip','.7z','.rar','.tar','.gz','.tgz','.iso'
)

# Raster image formats counted in the census SEPARATELY from $soft_DataExtensions
# because they need a size gate. Windows is full of these as icons, thumbnails,
# and UI sprites (under AppData / Program Files), which would drown out a real
# signal. We only count files at or above $ImageCensusFloorBytes so the census
# reflects actual photos, scans, clinical images, and X-ray exports -- not chrome.
# (The per-profile sweep already restricts to Desktop/Documents/Pictures/Videos/
# Downloads, so most icon caches are out of scope before the floor even applies.)
$soft_ImageExtensions = @(
    '.png','.jpg','.jpeg','.bmp','.gif','.tif','.tiff','.heic','.heif','.webp'
)

# Real photos, scanned documents, and dental X-ray image exports are virtually
# always well over 100 KB; icons, thumbnails, and sprites are well under it.
# Tune here if a client's real images skew smaller.
$ImageCensusFloorBytes = 100KB

# Decide whether a file should be counted in the extension census. Image types
# are gated by size to exclude icons/thumbnails; everything else in the data list
# counts regardless of size (a 4 KB .accdb stub still signals a local database).
function Test-CensusCountable {
    param([string]$Extension, [long]$SizeBytes)
    if ($soft_ImageExtensions -contains $Extension) {
        return ($SizeBytes -ge $ImageCensusFloorBytes)
    }
    return ($soft_DataExtensions -contains $Extension)
}

function Get-LocalUserProfileSummary {
    $profiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Special -and $_.LocalPath -like "C:\Users\*" }
    $result = @()
    foreach ($p in $profiles) {
        $userName = Split-Path -Leaf $p.LocalPath
        if ($userName -in @('Public','Default','Default User','All Users','defaultuser0')) { continue }

        $totalBytes = 0
        $extCounts = @{}
        # PSTs / VHDs / QuickBooks files etc. can live anywhere on disk
        # and are caught by the cross-drive Find-CriticalFiles scan
        # below. This per-profile sweep only estimates user-data
        # footprint inside the well-known user folders.
        $dirs = @('Desktop','Documents','Pictures','Videos','Downloads')
        foreach ($d in $dirs) {
            $path = Join-Path $p.LocalPath $d
            if (-not (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) { continue }
            try {
                $files = Get-ChildItem -LiteralPath $path -File -Recurse -Force -ErrorAction SilentlyContinue
                foreach ($f in $files) {
                    $totalBytes += $f.Length
                    $ext = $f.Extension.ToLowerInvariant()
                    if (Test-CensusCountable -Extension $ext -SizeBytes $f.Length) {
                        if (-not $extCounts.ContainsKey($ext)) { $extCounts[$ext] = 0 }
                        $extCounts[$ext] += 1
                    }
                }
            } catch {
                Write-Host "  Could not enumerate $($path): $_"
            }
        }

        $lastUsed = $null
        if ($p.LastUseTime) { $lastUsed = $p.LastUseTime.ToString("o") }

        $result += [pscustomobject]@{
            User              = $userName
            LocalPath         = $p.LocalPath
            LastUseTime       = $lastUsed
            TotalUserDataMB   = [math]::Round($totalBytes / 1MB, 1)
            DataExtensions    = $extCounts
        }
    }
    return ,$result
}

function Get-NonAdminShareSummary {
    $result = @()
    $shares = Get-SmbShare -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ShareType -eq 'FileSystemDirectory' -and
            $_.Name -notin @('ADMIN$','IPC$','print$') -and
            $_.Name -notlike '*$' -and
            $_.Path -and (Test-Path -LiteralPath $_.Path -ErrorAction SilentlyContinue)
        }
    foreach ($s in $shares) {
        $totalBytes = 0
        $extCounts = @{}
        try {
            $files = Get-ChildItem -LiteralPath $s.Path -File -Recurse -Force -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                $totalBytes += $f.Length
                $ext = $f.Extension.ToLowerInvariant()
                if (Test-CensusCountable -Extension $ext -SizeBytes $f.Length) {
                    if (-not $extCounts.ContainsKey($ext)) { $extCounts[$ext] = 0 }
                    $extCounts[$ext] += 1
                }
            }
        } catch {
            Write-Host "  Could not enumerate share $($s.Name) at $($s.Path): $_"
        }
        $result += [pscustomobject]@{
            Name              = $s.Name
            Path              = $s.Path
            Description       = $s.Description
            TotalSizeMB       = [math]::Round($totalBytes / 1MB, 1)
            DataExtensions    = $extCounts
        }
    }
    return ,$result
}

# =====================================================================
# Cross-drive scan for high-signal file types that often live OUTSIDE
# the well-known user folders and SMB shares: PSTs on D:\, VHDs in
# C:\Hyper-V\, QuickBooks files on a custom drive, etc. We walk every
# fixed drive once, skipping the dirs that never contain user data.
# =====================================================================

function Find-CriticalFiles {
    $criticalExt = @{
        '.pst'   = 'Outlook archive'
        '.vhd'   = 'Virtual disk'
        '.vhdx'  = 'Virtual disk'
        '.vmdk'  = 'VMware disk'
        '.vdi'   = 'VirtualBox disk'
        '.qcow2' = 'QEMU disk'
        '.ova'   = 'VM appliance'
        '.ovf'   = 'VM appliance'
        '.qbw'   = 'QuickBooks data'
        '.qbb'   = 'QuickBooks backup'
        '.qbm'   = 'QuickBooks portable'
        '.qba'   = 'QuickBooks accountant'
        '.accdb' = 'Access database'
        '.mdb'   = 'Access database (legacy)'
        '.dcm'   = 'DICOM image'
        '.dicom' = 'DICOM image'
        '.dex'   = 'DEXIS X-ray image'
    }
    $skipDirNames = @('Windows','$Recycle.Bin','System Volume Information','PerfLogs')

    $drives = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
    $result = @()

    foreach ($drive in $drives) {
        $root = "$($drive.DeviceID)\"
        Write-Host "  Scanning $root for unreplaceable file types..."
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        $candidates = @()
        try {
            $candidates += Get-ChildItem -LiteralPath $root -File -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Host "    Could not enumerate root $($root): $_"
        }

        $topDirs = Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $skipDirNames -notcontains $_.Name }
        foreach ($d in $topDirs) {
            try {
                $candidates += Get-ChildItem -LiteralPath $d.FullName -File -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Host "    Could not enumerate $($d.FullName): $_"
            }
        }

        foreach ($f in $candidates) {
            $ext = $f.Extension.ToLowerInvariant()
            if (-not $criticalExt.ContainsKey($ext)) { continue }
            $result += [pscustomobject]@{
                Path      = $f.FullName
                Extension = $ext
                Kind      = $criticalExt[$ext]
                SizeMB    = [math]::Round($f.Length / 1MB, 1)
                Modified  = $f.LastWriteTime.ToString("o")
            }
        }
        Write-Host ("  {0} done in {1}s" -f $root, [math]::Round($sw.Elapsed.TotalSeconds, 1))
    }
    return ,$result
}

# =====================================================================
# Run backup-specific discovery
# =====================================================================

Write-Host "Running database-service detection..."
$db = Test-HasDatabase

Write-Host "Running SoftDent registry detection..."
$softdent = Test-SoftDentServer
if ($softdent.Installed) {
    Write-Host ("  SoftDent present (server: {0}{1})" -f $softdent.IsServer, $(if ($softdent.DataPath) { ", data: $($softdent.DataPath)" } else { "" }))
}

Write-Host ""
Write-Host "Running soft-signal checks (may take a few minutes on large drives)..."
$profiles      = Get-LocalUserProfileSummary
$shares        = Get-NonAdminShareSummary
$criticalFiles = Find-CriticalFiles
Write-Host ("Cross-drive scan found {0} unreplaceable file(s)." -f $criticalFiles.Count)

# =====================================================================
# Decision rule -- hard signals
# =====================================================================

$decision       = $null
$reason         = $null
$decisionSource = $null

if ($hyperVHost.Value) {
    $decision = $false
    $reason   = "Hyper-V host (the VMs get backed up, not the host)"
    $decisionSource = "hard-signals"
} elseif ($dc.Value) {
    $decision = $true
    $reason   = "Domain Controller"
    $decisionSource = "hard-signals"
} elseif ($winServer.Value) {
    $decision = $true
    $reason   = "Windows Server"
    $decisionSource = "hard-signals"
} elseif ($db.matchedNonEmbedded) {
    $nonEmbedded = $db.services | Where-Object { -not $_.Embedded -and -not $_.Companion }
    $nonEmbeddedNames = ($nonEmbedded | ForEach-Object { "$($_.Name) [$($_.Engine)]" }) -join ', '
    $decision = $true
    $reason   = "Non-embedded database service(s) present: $nonEmbeddedNames"
    $decisionSource = "hard-signals"
} elseif ($softdent.IsServer) {
    $decision = $true
    $reason   = "SoftDent server -- FairCom c-tree data host (registry PWInc/PWSvr)$(if ($softdent.DataPath) { " at $($softdent.DataPath)" })"
    $decisionSource = "hard-signals"
} else {
    $decision       = $null  # hard signals can't decide; ask Claude below
    $reason         = "Workstation with no DC/server/DB signal -- asking Claude (Opus 4.7)"
    $decisionSource = "claude-pending"
}

# =====================================================================
# Claude triage (only when hard signals can't decide)
# =====================================================================

function Invoke-ClaudeBackupTriage {
    param(
        [Parameter(Mandatory)] [string] $ApiKey,
        [Parameter(Mandatory)] [string] $PayloadJson,
        [int] $MaxAttempts      = 5,        # 5 attempts on transient failures
        [int] $MaxParseAttempts = 3,        # 3 attempts when the body parses but lacks DECISION
        [int] $TimeoutSec       = 120,
        [int[]] $BackoffSec     = @(5, 15, 30, 60, 120)
    )

    # The system prompt is fixed across every endpoint in a fleet scan,
    # so mark it as a prompt-cache breakpoint. Anthropic caches up to
    # 5 minutes by default (and 1 hour with extended); for an RMM
    # fleet run that lands within a 5-min window the cache reads cost
    # ~10% of an uncached read.
    $systemPrompt = @"
You are a backup-eligibility triage assistant for an MSP that backs up
Windows endpoints (HIPAA + CMMC environments). The hard signals
(Hyper-V host / Windows Server / Domain Controller / non-embedded
database engine -- including dental PMS engines like SQL Anywhere,
Pervasive/Actian, Dentrix Ace/c-tree, QuickBooks DB Server -- and a
SoftDent c-tree server detected via registry) have already been
evaluated. You only see workstations the hard signals could not decide
on. Your job is to decide if this workstation holds *unreplaceable*
user data that warrants a backup.

Note on QuickBooks: a QB *Database Server* service is a hard signal
handled upstream (that box hosts the live company file). Here you may
still see loose .qbw/.qbb/.qbm/.qba files in `critical_files` -- those
are scoped as soft signals because they may be copies, but a company
file (.qbw) that appears to be the only copy still warrants a backup.

You will receive an inventory JSON with three soft-signal blocks:
`user_profiles` (data footprint in well-known user folders),
`file_shares` (non-admin SMB shares), and `critical_files` (a
cross-drive scan that lists every unreplaceable file type
*anywhere* on the machine: .pst, .vhd/.vhdx/.vmdk/.vdi/.qcow2/.ova,
.qbw/.qbb/.qbm/.qba, .accdb/.mdb, .dcm/.dicom, .dex). OST files are
deliberately NOT scanned -- they are offline caches of an
Exchange/M365 mailbox and the cloud is the source of truth.

The `.dcm`/`.dicom`/`.dex` types are dental/medical patient imaging
(DICOM exports and DEXIS X-rays) -- HIPAA-relevant and unreplaceable.

The per-extension counts inside `user_profiles` and `file_shares`
include raster image formats (.png/.jpg/.jpeg/.bmp/.tif/.gif/.heic/
.webp) only when the file is at least 100 KB, so those counts
represent ACTUAL photos, scans, and clinical images -- not icons,
thumbnails, or UI sprites. A large count there is real image data.

Decision rules:
- Backup IS needed when any of the following are clearly true:
  * The `critical_files` list is non-empty. Every entry there is a
    file type that exists ONLY on this endpoint and cannot be
    re-derived. A single PST or VHDX is enough.
  * Active user profile(s) with non-trivial counts of documents,
    spreadsheets, presentations, PDFs, OneNote, or designer files
    (.psd, .ai, .indd, .dwg, .cad).
  * Non-trivial counts of real images (.png/.jpg/.bmp/.tif, already
    size-filtered to exclude icons) in a user profile or share -- e.g.
    clinical/intraoral photos, scanned records, a photographer's
    library. Treat these as unreplaceable user data.
  * Non-admin SMB file share whose contents look like business data
    (not a re-installable software cache or a media-only library).
  * Combined business-data footprint over ~5 GB across profiles or
    shares.
- Backup is NOT needed when:
  * `critical_files` is empty AND all profiles are stale (empty or
    never-logged-in placeholder accounts) AND no business shares.
  * The only files are obviously replaceable: OS, application data,
    media collections that aren't business-relevant, downloads of
    public installers.

Be decisive. If you genuinely cannot decide, default to NEEDED -- the
cost of a missed backup is much higher than the cost of an extra
backup target.

Respond in exactly this format (no extra text outside these three
lines, no code fences):

DECISION: yes
REASONING: <one or two sentences explaining the call>
SHORT_SUMMARY: <single line, <=150 chars, suitable for an RMM text field>

DECISION must be the literal "yes" (backup is needed) or "no" (not
needed). SHORT_SUMMARY must be on a single line starting with the
literal token "SHORT_SUMMARY:".
"@

    $body = @{
        model      = "claude-opus-4-7"
        max_tokens = 1024
        system     = @(
            @{
                type          = "text"
                text          = $systemPrompt
                cache_control = @{ type = "ephemeral" }
            }
        )
        messages   = @(
            @{
                role    = "user"
                content = "Inventory JSON for this endpoint:`n$PayloadJson"
            }
        )
    } | ConvertTo-Json -Depth 10 -Compress

    $headers = @{
        "x-api-key"         = $ApiKey
        "anthropic-version" = "2023-06-01"
        "content-type"      = "application/json"
    }

    $result = [pscustomobject]@{
        Decision     = $null   # $true / $false / $null on failure
        Reasoning    = $null
        ShortSummary = $null
        RawText      = $null
        UsageJson    = $null
        Error        = $null
        # Outcome: success | auth | bad-request | transient | unparseable
        # auth + bad-request = fatal (no retry, exit 2)
        # transient / unparseable = retried up to limit, then exit 1
        Outcome      = $null
        Attempts     = 0
    }

    $parseAttempts = 0

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result.Attempts = $attempt
        Write-Host "  Claude call attempt $attempt of $MaxAttempts..."
        $statusCode = $null
        $errMsg     = $null
        $resp       = $null

        try {
            $resp = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" `
                -Method Post -Headers $headers -Body $body -TimeoutSec $TimeoutSec
        } catch {
            $errMsg = "$($_.Exception.Message)"
            try {
                $statusCode = [int]$_.Exception.Response.StatusCode.value__
            } catch {
                $statusCode = $null
            }
        }

        if ($null -ne $resp) {
            # HTTP 200 -- parse the response.
            if ($null -ne $resp.usage) {
                $result.UsageJson = ($resp.usage | ConvertTo-Json -Depth 5 -Compress)
            }
            $text = ""
            if ($resp.content -and $resp.content.Count -gt 0) {
                $text = "$($resp.content[0].text)"
            }
            $result.RawText = $text

            $decisionLocal = $null
            $reasoningLocal = $null
            $summaryLocal = $null
            foreach ($line in $text -split "`r?`n") {
                if ($line -match '^\s*DECISION:\s*(.+)$') {
                    $val = $Matches[1].Trim().ToLowerInvariant()
                    if ($val -like "yes*")   { $decisionLocal = $true }
                    elseif ($val -like "no*"){ $decisionLocal = $false }
                } elseif ($line -match '^\s*REASONING:\s*(.+)$') {
                    $reasoningLocal = $Matches[1].Trim()
                } elseif ($line -match '^\s*SHORT_SUMMARY:\s*(.+)$') {
                    $s = $Matches[1].Trim()
                    if ($s.Length -gt 190) { $s = $s.Substring(0, 190) + "..." }
                    $summaryLocal = $s
                }
            }

            if ($null -ne $decisionLocal) {
                $result.Decision     = $decisionLocal
                $result.Reasoning    = $reasoningLocal
                $result.ShortSummary = $summaryLocal
                $result.Outcome      = "success"
                return $result
            }

            # Parseable HTTP response but no DECISION line -- retry with the
            # parse-specific budget.
            $parseAttempts++
            $result.Error = "Claude returned 200 but no parseable DECISION line."
            Write-Host "  $($result.Error) (parse attempt $parseAttempts of $MaxParseAttempts)"
            if ($parseAttempts -ge $MaxParseAttempts) {
                $result.Outcome = "unparseable"
                return $result
            }
            $sleep = $BackoffSec[[Math]::Min($attempt - 1, $BackoffSec.Count - 1)]
            Write-Host "  Sleeping $sleep s before retry."
            Start-Sleep -Seconds $sleep
            continue
        }

        # No response object -- HTTP error or network failure.
        $result.Error = "HTTP $statusCode -- $errMsg"
        Write-Host "  Claude call failed: $($result.Error)"

        # Fatal classes -- do not retry.
        if ($statusCode -eq 401 -or $statusCode -eq 403) {
            $result.Outcome = "auth"
            return $result
        }
        if ($null -ne $statusCode -and $statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -ne 429 -and $statusCode -ne 408) {
            $result.Outcome = "bad-request"
            return $result
        }

        # Transient -- retry if budget remains.
        if ($attempt -ge $MaxAttempts) {
            $result.Outcome = "transient"
            return $result
        }
        $sleep = $BackoffSec[[Math]::Min($attempt - 1, $BackoffSec.Count - 1)]
        Write-Host "  Transient failure; sleeping $sleep s before retry."
        Start-Sleep -Seconds $sleep
    }

    # Loop exited without returning -- shouldn't happen, but guard anyway.
    if ([string]::IsNullOrEmpty($result.Outcome)) { $result.Outcome = "transient" }
    return $result
}

$claudeResult = $null
$claudeFailureExit = 0  # 0 = no failure or hard-signals path; 1 = transient/unparseable; 2 = auth/config

if ($null -eq $decision) {
    Write-Host "Hard signals can't decide -- calling Claude (Opus 4.7) for triage..."

    # Slim payload for Claude: omit the half-baked decision wrapper (it's null
    # anyway) so the model focuses on the signals it actually needs.
    $claudeInput = [pscustomobject]@{
        schema_version = 1
        scanned_at     = (Get-Date).ToString("o")
        computer_name  = $env:COMPUTERNAME
        host_class     = [pscustomobject]@{
            is_hyperv_host       = [bool]$hyperVHost.Value
            is_windows_server    = [bool]$winServer.Value
            is_domain_controller = [bool]$dc.Value
        }
        backup_signals = [pscustomobject]@{
            has_database        = [bool]$db.matched
            has_non_embedded_db = [bool]$db.matchedNonEmbedded
            database_services   = $db.services
            softdent            = $softdent
        }
        soft_signals   = [pscustomobject]@{
            user_profiles  = $profiles
            file_shares    = $shares
            critical_files = $criticalFiles
        }
    } | ConvertTo-Json -Depth 8 -Compress

    if ([string]::IsNullOrWhiteSpace($env:anthropicApiKey)) {
        if ($env:RMM -ne "1") {
            $secure = Read-Host "Anthropic API key (input hidden)" -AsSecureString
            $env:anthropicApiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
        }
    }
    if ([string]::IsNullOrWhiteSpace($env:anthropicApiKey)) {
        Write-Host "  ERROR: anthropicApiKey is not set. Configure it as an RMM script preset variable."
        $decisionSource    = "claude-failed-config"
        $reason            = "Claude triage required but anthropicApiKey is not configured."
        $claudeFailureExit = 2
    } else {
        # Fleet jitter -- smear the API call across a window so a mass RMM run
        # of N endpoints doesn't burst the Anthropic rate limit all at once.
        # Only here (RMM mode, Claude actually needed, key present). At Tier 1
        # (50 RPM) 600s is far too short for thousands of endpoints; see the
        # $env:ClaudeJitterMaxSeconds note in the header.
        if ([string]::IsNullOrEmpty($env:ClaudeJitterMaxSeconds)) { $env:ClaudeJitterMaxSeconds = "600" }
        $jitterMax = 0
        if (-not [int]::TryParse($env:ClaudeJitterMaxSeconds, [ref]$jitterMax)) { $jitterMax = 600 }
        if ($env:RMM -eq "1" -and $jitterMax -gt 0) {
            $jitter = Get-Random -Minimum 0 -Maximum ($jitterMax + 1)
            Write-Host "  Fleet jitter: sleeping $jitter s (random 0..$jitterMax) before calling Claude..."
            Start-Sleep -Seconds $jitter
        }

        $claudeResult = Invoke-ClaudeBackupTriage -ApiKey $env:anthropicApiKey -PayloadJson $claudeInput
        switch ($claudeResult.Outcome) {
            "success" {
                $decision = $claudeResult.Decision
                $reason   = if ($claudeResult.Reasoning) { "Claude: $($claudeResult.Reasoning)" } else { "Claude verdict (no reasoning line)" }
                $decisionSource = "claude"
                Write-Host "  Claude DECISION: $(if ($decision) { 'yes' } else { 'no' })  (attempt $($claudeResult.Attempts))"
                if ($claudeResult.ShortSummary) { Write-Host "  SHORT_SUMMARY: $($claudeResult.ShortSummary)" }
                if ($claudeResult.UsageJson)    { Write-Host "  usage: $($claudeResult.UsageJson)" }
            }
            "auth" {
                Write-Host "  Claude authentication failed (HTTP 401/403). The key is invalid or doesn't have access."
                $decisionSource    = "claude-failed-auth"
                $reason            = "Claude triage failed: authentication rejected (key invalid or scoped out). $($claudeResult.Error)"
                $claudeFailureExit = 2
            }
            "bad-request" {
                Write-Host "  Claude rejected the request (HTTP 4xx). The payload or model name is likely wrong."
                $decisionSource    = "claude-failed-bad-request"
                $reason            = "Claude triage failed: bad request. $($claudeResult.Error)"
                $claudeFailureExit = 2
            }
            "unparseable" {
                Write-Host "  Claude returned 200 but never produced a parseable DECISION line in $($claudeResult.Attempts) attempts."
                $decisionSource    = "claude-failed-unparseable"
                $reason            = "Claude triage failed: response missing DECISION line after $($claudeResult.Attempts) attempts."
                $claudeFailureExit = 1
            }
            "transient" {
                Write-Host "  Claude unreachable (transient errors / timeouts) after $($claudeResult.Attempts) attempts."
                $decisionSource    = "claude-failed-transient"
                $reason            = "Claude triage failed: transient errors persisted across $($claudeResult.Attempts) attempts. Last error: $($claudeResult.Error)"
                $claudeFailureExit = 1
            }
            default {
                Write-Host "  Claude call returned an unexpected outcome: '$($claudeResult.Outcome)'."
                $decisionSource    = "claude-failed-unknown"
                $reason            = "Claude triage failed: unknown outcome. $($claudeResult.Error)"
                $claudeFailureExit = 1
            }
        }
    }
    Write-Host ""
}

# =====================================================================
# Output (final, post-Claude)
# =====================================================================

$hasDatabaseBit = if ($db.matched) { 1 } else { 0 }
$needsBackup    = if ($decision -eq $true) { 1 } elseif ($decision -eq $false) { 0 } else { $null }
$aiVerdict      = if     ($decision -eq $true  -and $decisionSource -eq "claude")        { "needed" }
                  elseif ($decision -eq $false -and $decisionSource -eq "claude")        { "not-needed" }
                  elseif ($decision -ne $null  -and $decisionSource -eq "hard-signals")  { "not-required" }
                  elseif ($claudeFailureExit -eq 2)                                       { "failed-config" }
                  elseif ($claudeFailureExit -eq 1)                                       { "failed-retry-later" }
                  else                                                                    { "pending" }

Write-Host ""
Write-Host "============================================"
Write-Host "RESULT"
Write-Host "============================================"
Write-Host ("isHyperVHost (read)      : {0}  (source: {1})" -f $hyperVHost.Value, $hyperVHost.Source)
Write-Host ("isWindowsServer (read)   : {0}  (source: {1})" -f $winServer.Value,  $winServer.Source)
Write-Host ("isDomainController (read): {0}  (source: {1})" -f $dc.Value,         $dc.Source)
Write-Host ("hasDatabase              : {0}  (non-embedded: {1})" -f $hasDatabaseBit, ([int]$db.matchedNonEmbedded))
$needsBackupDisplay = if ($null -eq $needsBackup) { "PENDING" } else { "$needsBackup" }
Write-Host ("needsBackup              : {0}" -f $needsBackupDisplay)
Write-Host ("decisionSource           : {0}" -f $decisionSource)
Write-Host ("aiVerdict                : {0}" -f $aiVerdict)
Write-Host ("reason                   : {0}" -f $reason)
Write-Host "============================================"
Write-Host ""

# --- HTML summary --------------------------------------------------------

function New-StatusPill {
    param([bool]$On, [string]$OnText = 'Yes', [string]$OffText = 'No')
    if ($On) { return "<span style='color:#b22222;'><strong>$OnText</strong></span>" }
    return "<span style='color:#228b22;'>$OffText</span>"
}

$htmlBuilder = [System.Text.StringBuilder]::new()
[void]$htmlBuilder.Append("<p><strong>Backup Discovery</strong> -- $env:COMPUTERNAME -- $(Get-Date -Format 'yyyy-MM-dd HH:mm') </p>")
[void]$htmlBuilder.Append('<table style="border-collapse:collapse;"><tbody>')
[void]$htmlBuilder.Append("<tr><td><strong>Needs Backup</strong></td><td>")
if ($null -eq $needsBackup) {
    [void]$htmlBuilder.Append("<span style='color:#a68900;'><strong>PENDING</strong></span>")
} elseif ($needsBackup -eq 1) {
    [void]$htmlBuilder.Append("<span style='color:#b22222;'><strong>YES</strong></span>")
} else {
    [void]$htmlBuilder.Append("<span style='color:#228b22;'><strong>NO</strong></span>")
}
[void]$htmlBuilder.Append(" <small>(decision source: $decisionSource)</small></td></tr>")
[void]$htmlBuilder.Append("<tr><td>Decision Reason</td><td>$reason</td></tr>")
if ($claudeResult -and $claudeResult.ShortSummary) {
    [void]$htmlBuilder.Append("<tr><td>Claude Summary</td><td><em>$($claudeResult.ShortSummary)</em></td></tr>")
}
[void]$htmlBuilder.Append("<tr><td>Hyper-V Host</td><td>$(New-StatusPill -On:$hyperVHost.Value) <small>($($hyperVHost.Source))</small></td></tr>")
[void]$htmlBuilder.Append("<tr><td>Windows Server</td><td>$(New-StatusPill -On:$winServer.Value) <small>($($winServer.Source))</small></td></tr>")
[void]$htmlBuilder.Append("<tr><td>Domain Controller</td><td>$(New-StatusPill -On:$dc.Value) <small>($($dc.Source))</small></td></tr>")
[void]$htmlBuilder.Append("<tr><td>Database Services</td><td>$(New-StatusPill -On:($db.matched))")
if ($db.services.Count -gt 0) {
    [void]$htmlBuilder.Append("<ul style='margin-top:4px;'>")
    foreach ($s in $db.services) {
        $tag = if ($s.Companion)        { "<em>companion (informational)</em>" }
               elseif ($s.Embedded)     { "<em>embedded ($($s.HostApp))</em>" }
               elseif ($s.CustomerData) { "<strong>customer data</strong>" }
               else                     { "<strong>unreplaceable?</strong>" }
        [void]$htmlBuilder.Append("<li>$($s.Name) [$($s.Engine)] ($($s.State)) -- $tag</li>")
    }
    [void]$htmlBuilder.Append("</ul>")
}
[void]$htmlBuilder.Append("</td></tr>")
[void]$htmlBuilder.Append("<tr><td>SoftDent (registry)</td><td>")
if ($softdent.Installed) {
    [void]$htmlBuilder.Append("$(New-StatusPill -On:$softdent.IsServer -OnText:'Server (c-tree data host)' -OffText:'client only')")
    if ($softdent.DataPath) { [void]$htmlBuilder.Append(" <small><code>$($softdent.DataPath)</code></small>") }
} else {
    [void]$htmlBuilder.Append("<span style='color:#228b22;'>not present</span>")
}
[void]$htmlBuilder.Append("</td></tr>")
[void]$htmlBuilder.Append("<tr><td>Local User Profiles</td><td>$($profiles.Count)</td></tr>")
[void]$htmlBuilder.Append("<tr><td>Non-admin File Shares</td><td>$($shares.Count)</td></tr>")
[void]$htmlBuilder.Append("<tr><td>Unreplaceable Files (cross-drive)</td><td>$(New-StatusPill -On:($criticalFiles.Count -gt 0) -OnText:"$($criticalFiles.Count) found" -OffText:'0')")
if ($criticalFiles.Count -gt 0) {
    [void]$htmlBuilder.Append("<ul style='margin-top:4px;'>")
    foreach ($cf in ($criticalFiles | Sort-Object -Property SizeMB -Descending | Select-Object -First 25)) {
        [void]$htmlBuilder.Append("<li><code>$($cf.Path)</code> -- <em>$($cf.Kind)</em>, $($cf.SizeMB) MB</li>")
    }
    if ($criticalFiles.Count -gt 25) {
        [void]$htmlBuilder.Append("<li>... and $($criticalFiles.Count - 25) more (see AI payload)</li>")
    }
    [void]$htmlBuilder.Append("</ul>")
}
[void]$htmlBuilder.Append("</td></tr>")
[void]$htmlBuilder.Append('</tbody></table>')

$detailsHtml = $htmlBuilder.ToString()

# --- Final AI payload (multi-line JSON) ----------------------------------

$claudeVerdictBlock = $null
if ($claudeResult) {
    $claudeVerdictBlock = [pscustomobject]@{
        called        = $true
        decision      = if ($null -eq $claudeResult.Decision) { $null } else { [bool]$claudeResult.Decision }
        reasoning     = $claudeResult.Reasoning
        short_summary = $claudeResult.ShortSummary
        error         = $claudeResult.Error
        usage         = $claudeResult.UsageJson
        model         = "claude-opus-4-7"
    }
}

$aiPayload = [pscustomobject]@{
    schema_version    = 1
    scanned_at        = (Get-Date).ToString("o")
    computer_name     = $env:COMPUTERNAME
    host_class        = [pscustomobject]@{
        is_hyperv_host           = [bool]$hyperVHost.Value
        is_hyperv_host_src       = $hyperVHost.Source
        is_windows_server        = [bool]$winServer.Value
        is_windows_server_src    = $winServer.Source
        is_domain_controller     = [bool]$dc.Value
        is_domain_controller_src = $dc.Source
    }
    backup_signals    = [pscustomobject]@{
        has_database        = [bool]$db.matched
        has_non_embedded_db = [bool]$db.matchedNonEmbedded
        database_services   = $db.services
        softdent            = $softdent
    }
    decision          = [pscustomobject]@{
        needs_backup = if ($null -eq $needsBackup) { $null } else { [bool]$needsBackup }
        reason       = $reason
        source       = $decisionSource
        ai_verdict   = $aiVerdict
    }
    claude_verdict    = $claudeVerdictBlock
    soft_signals      = [pscustomobject]@{
        user_profiles  = $profiles
        file_shares    = $shares
        critical_files = $criticalFiles
    }
}
$aiPayloadJson = $aiPayload | ConvertTo-Json -Depth 10 -Compress

Write-Host "AI payload (JSON, $($aiPayloadJson.Length) chars):"
Write-Host $aiPayloadJson
Write-Host ""

# --- NinjaRMM custom field writes ----------------------------------------

function Write-NinjaField {
    param([string]$Name, $Value)
    if ([string]::IsNullOrEmpty($Name)) { return }
    try {
        Ninja-Property-Set -Name $Name -Value $Value
        Write-Host "  Wrote '$Name'"
    } catch {
        Write-Host "  ERROR writing '$Name': $_"
    }
}

# NinjaRMM single-line Text fields cap at 200 chars. Truncate to 190 to
# leave room for the ellipsis. Full text still lives in the HTML details
# field, the AI payload JSON, and the transcript.
function Limit-NinjaText {
    param([string]$Value, [int]$Max = 190)
    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    if ($Value.Length -le $Max) { return $Value }
    return $Value.Substring(0, $Max) + "..."
}

$reasonShort = Limit-NinjaText -Value $reason
$aiVerdictShort = Limit-NinjaText -Value $aiVerdict  # values are tokens, but cheap insurance

if ($env:RMM -eq "1") {
    Write-Host "Writing NinjaRMM custom fields..."
    Write-NinjaField -Name $env:CustomFieldBackupDiscoveryHasDatabase    -Value $hasDatabaseBit
    Write-NinjaField -Name $env:CustomFieldBackupDiscoveryDecisionReason -Value $reasonShort
    Write-NinjaField -Name $env:CustomFieldBackupDiscoveryDetails        -Value $detailsHtml
    Write-NinjaField -Name $env:CustomFieldBackupDiscoveryAIPayload      -Value $aiPayloadJson
    Write-NinjaField -Name $env:CustomFieldBackupDiscoveryAIVerdict      -Value $aiVerdictShort

    # needsBackup: only write when a decision was reached (hard signals or
    # Claude). Leave it alone when verdict is "pending" so the next scan
    # can retry the API call without flipping the field falsely.
    if ($null -ne $needsBackup) {
        Write-NinjaField -Name $env:CustomFieldBackupDiscoveryNeedsBackup -Value $needsBackup
    }
} else {
    Write-Host "Interactive mode -- skipping Ninja-Property-Set calls."
    Write-Host ""
    Write-Host "Would have written:"
    Write-Host ("  {0} = {1}" -f $env:CustomFieldBackupDiscoveryHasDatabase,    $hasDatabaseBit)
    Write-Host ("  {0} = '{1}'" -f $env:CustomFieldBackupDiscoveryDecisionReason, $reasonShort)
    Write-Host ("  {0} = (HTML, see transcript)" -f $env:CustomFieldBackupDiscoveryDetails)
    Write-Host ("  {0} = (JSON, see transcript)" -f $env:CustomFieldBackupDiscoveryAIPayload)
    Write-Host ("  {0} = '{1}'" -f $env:CustomFieldBackupDiscoveryAIVerdict, $aiVerdictShort)
    if ($null -ne $needsBackup) {
        Write-Host ("  {0} = {1}" -f $env:CustomFieldBackupDiscoveryNeedsBackup, $needsBackup)
    } else {
        Write-Host ("  {0} left unchanged (verdict pending)" -f $env:CustomFieldBackupDiscoveryNeedsBackup)
    }
}

Stop-Transcript

if ($claudeFailureExit -ne 0) {
    Write-Host "Exiting with code $claudeFailureExit because Claude triage did not produce a verdict."
    exit $claudeFailureExit
}
exit 0
