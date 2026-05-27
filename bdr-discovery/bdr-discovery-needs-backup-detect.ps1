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

    $dbPatterns = @(
        'MSSQL*','SQLAgent*','SQLBrowser','SQLWriter',
        'MySQL*','MariaDB*',
        'postgresql*','postgres-*',
        'OracleService*',
        'MongoDB','Redis'
    )

    # Path patterns for KNOWN-embedded DBs -- service ImagePath under one of
    # these means the DB stores app/state, not customer data. Be generous;
    # AI evaluator can override.
    $embeddedHostApps = @(
        'Veeam','NinjaRMM','NinjaOne','Acronis','Sophos','Huntress',
        'ManageEngine','ConnectWise','LabTech','Automate','Kaseya','Datto',
        'N-able','SolarWinds','BackupExec','CarbonBlack','CrowdStrike',
        'Blackpoint','SentinelOne','Webroot','Bitdefender','Cynet',
        'PrintAudit','PaperCut'
    )

    foreach ($pat in $dbPatterns) {
        $svcs = Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE '$($pat.Replace('*','%'))'" -ErrorAction SilentlyContinue
        foreach ($s in $svcs) {
            $imagePath = "$($s.PathName)".Trim('"').Trim()
            $isEmbedded = $false
            $hostApp = ""
            foreach ($app in $embeddedHostApps) {
                if ($imagePath -like "*$app*") {
                    $isEmbedded = $true
                    $hostApp = $app
                    break
                }
            }
            $details.matched = $true
            if (-not $isEmbedded) { $details.matchedNonEmbedded = $true }
            $details.services += [pscustomobject]@{
                Name      = $s.Name
                State     = $s.State
                StartMode = $s.StartMode
                Account   = $s.StartName
                Path      = $imagePath
                Embedded  = $isEmbedded
                HostApp   = $hostApp
            }
        }
    }
    return $details
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
    # Email stores + saved messages
    '.pst','.ost','.eml','.msg','.mbox',
    # Microsoft Access / generic local databases / dumps + backups
    '.accdb','.mdb','.db','.sqlite','.sqlite3','.dbf','.sql','.bak',
    # QuickBooks / accounting
    '.qbw','.qbb','.qbm','.qba','.qbo','.iif',
    # Designer / creative
    '.psd','.ai','.indd','.afdesign','.afphoto','.sketch','.fig',
    # CAD / engineering
    '.dwg','.dxf','.cad','.stp','.step','.iges','.igs','.skp',
    # Medical / dental imaging (DICOM is industry standard)
    '.dcm','.dicom',
    # Virtual disks -- local VMs almost always hold business data
    '.vhd','.vhdx','.vmdk','.vdi','.qcow2','.ova','.ovf',
    # Archives (often contain dumps / exports)
    '.zip','.7z','.rar','.tar','.gz','.tgz','.iso'
)

function Get-LocalUserProfileSummary {
    $profiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Special -and $_.LocalPath -like "C:\Users\*" }
    $result = @()
    foreach ($p in $profiles) {
        $userName = Split-Path -Leaf $p.LocalPath
        if ($userName -in @('Public','Default','Default User','All Users','defaultuser0')) { continue }

        $totalBytes = 0
        $extCounts = @{}
        $dirs = @('Desktop','Documents','Pictures','Videos','Downloads')
        foreach ($d in $dirs) {
            $path = Join-Path $p.LocalPath $d
            if (-not (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) { continue }
            try {
                $files = Get-ChildItem -LiteralPath $path -File -Recurse -Force -ErrorAction SilentlyContinue
                foreach ($f in $files) {
                    $totalBytes += $f.Length
                    $ext = $f.Extension.ToLowerInvariant()
                    if ($soft_DataExtensions -contains $ext) {
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
                if ($soft_DataExtensions -contains $ext) {
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
# Run backup-specific discovery
# =====================================================================

Write-Host "Running database-service detection..."
$db = Test-HasDatabase

Write-Host ""
Write-Host "Running soft-signal checks (may take a minute on large profiles/shares)..."
$profiles = Get-LocalUserProfileSummary
$shares   = Get-NonAdminShareSummary

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
    $nonEmbeddedNames = ($db.services | Where-Object { -not $_.Embedded } | Select-Object -ExpandProperty Name) -join ', '
    $decision = $true
    $reason   = "Non-embedded database service(s) present: $nonEmbeddedNames"
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
database) have already been evaluated. You only see workstations the
hard signals could not decide on. Your job is to decide if this
workstation holds *unreplaceable* user data that warrants a backup.

Decision rules:
- Backup IS needed when any of the following are clearly true:
  * Active user profile(s) with non-trivial counts of documents,
    spreadsheets, presentations, PDFs, PSTs, OneNote, or designer
    files (.psd, .ai, .indd, .dwg, .cad, .qbw/.qbb, .accdb, .mdb).
  * Virtual-disk files present (.vhd, .vhdx, .vmdk, .vdi, .qcow2,
    .ova, .ovf) -- local VMs almost always hold business data and
    are unreplaceable. Treat as a strong YES signal even with small
    counts.
  * DICOM / dental-imaging files present (.dcm, .dicom) -- patient
    records are PHI under HIPAA, strong YES signal.
  * Local database files present (.sqlite, .sqlite3, .db, .dbf,
    .sql, .bak) outside of obvious app caches.
  * Non-admin SMB file share whose contents look like business data
    (not a re-installable software cache or a media-only library).
  * Combined business-data footprint over ~5 GB across profiles or
    shares.
- Backup is NOT needed when:
  * All profiles are stale (empty or never-logged-in placeholder
    accounts) AND no business shares.
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
        }
        soft_signals   = [pscustomobject]@{
            user_profiles = $profiles
            file_shares   = $shares
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
if ($db.matched) {
    [void]$htmlBuilder.Append("<ul style='margin-top:4px;'>")
    foreach ($s in $db.services) {
        $tag = if ($s.Embedded) { "<em>embedded ($($s.HostApp))</em>" } else { "<strong>unreplaceable?</strong>" }
        [void]$htmlBuilder.Append("<li>$($s.Name) ($($s.State)) -- $tag</li>")
    }
    [void]$htmlBuilder.Append("</ul>")
}
[void]$htmlBuilder.Append("</td></tr>")
[void]$htmlBuilder.Append("<tr><td>Local User Profiles</td><td>$($profiles.Count)</td></tr>")
[void]$htmlBuilder.Append("<tr><td>Non-admin File Shares</td><td>$($shares.Count)</td></tr>")
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
    }
    decision          = [pscustomobject]@{
        needs_backup = if ($null -eq $needsBackup) { $null } else { [bool]$needsBackup }
        reason       = $reason
        source       = $decisionSource
        ai_verdict   = $aiVerdict
    }
    claude_verdict    = $claudeVerdictBlock
    soft_signals      = [pscustomobject]@{
        user_profiles = $profiles
        file_shares   = $shares
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
