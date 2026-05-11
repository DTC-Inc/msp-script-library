# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is an MSP (Managed Service Provider) script library containing PowerShell scripts for automation, deployment, configuration, and management tasks across various platforms and vendors. Scripts are designed to be executed both interactively and via RMM (Remote Monitoring and Management) platforms.

## Code Architecture

### Script Structure Standard

All scripts follow a consistent three-part structure defined in `script-template-powershell.ps1`:

1. **RMM Variable Declaration Section** (top of file)
   - Comment block listing all required RMM variables
   - Format: `## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM`
   - Each variable should be documented as a comment (e.g., `## $variableName`)

2. **Input Handling Section**
   - **All RMM-supplied variables come via environment variables** (`$env:VarName`). NinjaRMM passes script preset variables to PowerShell as environment variables, so the script must read them via `$env:` at every use site. Bare `$VarName` references resolve to `$null` in true RMM mode and silently fall through to the interactive branch.
   - Detects execution context via `$env:RMM` — environment variables are strings, so compare against `"1"` not `1`. Anything other than `"1"` is interactive mode.
   - Interactive mode: Prompts user with `Read-Host` for required inputs with validation loop. Write the result back to `$env:Description` so the rest of the script can keep referencing `$env:` consistently.
   - RMM mode: Uses pre-set environment variables passed by the RMM platform. Defaults for any optional variables (custom field names, state file paths, etc.) should be set at the top of the script by writing to `$env:` directly:
     ```powershell
     if ([string]::IsNullOrEmpty($env:CustomFieldFooBoolean)) {
         $env:CustomFieldFooBoolean = "fooDetected"
     }
     ```
   - Sets `$LogPath` based on context:
     - **SYSTEM-context script, interactive:** `$env:WINDIR\logs\`
     - **SYSTEM-context script, RMM:** `$env:RMMScriptPath\logs\` (fallback to `$env:WINDIR\logs\` if `$env:RMMScriptPath` is null)
     - **User-context script:** `$env:LOCALAPPDATA\dtc-logs\` — `$env:WINDIR\logs\` requires admin and a user-context script will fail to write there
   - Always captures `$env:Description` for audit trail

3. **Script Logic Section**
   - Wrapped in `Start-Transcript` / `Stop-Transcript` for full logging
   - Logs key variables at start (Description, LogPath, RMM mode)
   - Contains actual automation logic

### Naming Conventions

- **Code Style**: camelCase for variables and functions (exceptions: Python uses snake_case per language convention)
- **File Naming**: lowercase with hyphens, e.g., `veeam-add-backup-repo.ps1`
- **Folder Structure**: `category-vendor` or `category-app` format

### Category Organization

Scripts are organized by category prefixes:
- `app-*`: Application-specific scripts (Duo, Adobe, Teramind, etc.)
- `bdr-*`: Backup and Disaster Recovery (Veeam, MSP360)
- `db-*`: Database engines (MySQL, etc.)
- `iaas-*`: Infrastructure as a Service (Azure, Backblaze, Dynu)
- `mw-*`: Middleware/Microsoft 365 scripts
- `msft-*`: Microsoft Windows system scripts
- `net-*`: Networking scripts
- `oem-*`: OEM vendor configuration (Dell, HP, etc.)
- `rmm-*`: RMM platform agents (NinjaRMM, Automate, Control)
- `sec-*`: Security tools (Huntress, CrowdStrike Falcon, Cynet)
- `s3-api-lib/`: Reusable S3 API function library

## Development Standards

### When Creating New Scripts

1. **Always start from `script-template-powershell.ps1`** - Copy this template for new scripts
2. **Document RMM variables** - List all required variables in the top comment block
3. **Support dual execution modes** - Script must work both interactively and via RMM
4. **Implement input validation** - Use `$ValidInput` loop pattern for interactive mode
5. **Enable full logging** - Use `Start-Transcript` at the beginning and `Stop-Transcript` at the end
6. **Set appropriate `$ScriptLogName`** - Use descriptive filename matching the script purpose

### Script Modifications

When modifying existing scripts:
- Preserve the three-section structure
- Maintain backward compatibility with RMM variable names
- Keep logging verbosity high for troubleshooting
- Test both interactive and RMM execution paths

### Common Patterns

**Manufacturer Detection** (from `oem/windows-oem-config.ps1`):
```powershell
$manufacturer = (Get-WmiObject -Class Win32_ComputerSystem).Manufacturer
if ($manufacturer -like "Dell*") {
    # Dell-specific logic
}
```

**Service Existence Check** (from `sec-huntress/HuntressAgentInstall.ps1`):
```powershell
function Confirm-ServiceExists ($service) {
    if (Get-Service $service -ErrorAction SilentlyContinue) {
        return $true
    }
    return $false
}
```

**File/Path Validation Before Installation**:
```powershell
$installPath = "C:\Program Files\Vendor\app.exe"
if (Test-Path -Path $installPath) {
    Write-Host "Already installed. Skipping installation."
    exit 0
}
```

**Download and Execute Pattern**:
```powershell
$output = "$env:WINDIR\temp\installer.exe"
Invoke-WebRequest -Uri $downloadURL -OutFile $output
Start-Process -FilePath $output -Args "/S" -Wait -NoNewWindow
```

### Application Detection Patterns

When detecting whether an application is installed or active, **check every install vector** — applications can land in many places depending on how they were installed. A check that only looks at HKLM uninstall keys will miss per-user Chrome extensions, sideloaded installers, Microsoft Store apps, and anything that shipped via `%LOCALAPPDATA%`.

Canonical example: `app-google-chrome/chrome-remote-desktop-detect-system.ps1` and `chrome-remote-desktop-detect-user.ps1`.

**System-visible install detection** (run from SYSTEM):
```powershell
# 1. HKLM uninstall registry — system-wide MSI installs
function Test-AppInstalledHKLM {
    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($path in $registryPaths) {
        $apps = Get-ItemProperty $path -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -like "*App Name*"
        }
        if ($apps) { return $true }
    }
    return $false
}

# 2. Program Files install path
function Test-AppInstallPath {
    $installPaths = @(
        "${env:ProgramFiles}\Vendor\App",
        "${env:ProgramFiles(x86)}\Vendor\App"
    )
    foreach ($path in $installPaths) {
        if (Test-Path $path) { return $true }
    }
    return $false
}

# 3. Windows service
function Test-AppService {
    $service = Get-Service -Name "appservice" -ErrorAction SilentlyContinue
    return [bool]$service
}

# 4. Running process
function Test-AppProcess {
    $process = Get-Process -Name "app" -ErrorAction SilentlyContinue
    return [bool]$process
}
```

**User-visible install detection** (run from user context — see Cross-Context Detection below):
```powershell
# HKCU uninstall registry — per-user installs (e.g., Chrome extensions)
function Test-AppInstalledHKCU {
    $registryPaths = @(
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($path in $registryPaths) {
        $apps = Get-ItemProperty $path -ErrorAction SilentlyContinue | Where-Object {
            $_.DisplayName -like "*App Name*"
        }
        if ($apps) { return $true }
    }
    return $false
}

# %LOCALAPPDATA% install path — per-user app data
function Test-AppUserAppData {
    $appPath = Join-Path $env:LOCALAPPDATA "Vendor\App"
    return (Test-Path $appPath)
}
```

**Why check both HKCU and HKLM:** A SYSTEM-context script reading `HKCU:` resolves to SYSTEM's profile, which is empty. To catch per-user installs you must run a separate script in user context. See "Cross-Context Detection" below.

### NinjaRMM Custom Field Patterns

NinjaRMM custom fields come in several types and have important runtime constraints. Pick the right type up front and respect the constraints.

**Field types and use cases:**

| Type | Use for | Notes |
|---|---|---|
| **Checkbox / Boolean** | Yes/no presence flags ("Detected", "Compliant") | Write `1` or `0`. NinjaRMM stores as boolean. |
| **Text** | Short status strings, dropdown values | Limited to 200 chars. Use for things like "User + System", "Failed", "Vulnerable". |
| **WYSIWYG / HTML** | Rich formatted reports for technician dashboards | No 200-char limit. Use for detailed multi-line output, tables, lists, color-coded status. |
| **Multi-line text** | Logs, transcripts, free-form notes | Larger character limit than single-line text. |

**Standard write pattern** — `Ninja-Property-Set` works for all field types; the cmdlet figures out the type from the field's NinjaRMM configuration:
```powershell
if ($env:RMM -eq "1") {
    try {
        Ninja-Property-Set -Name $env:CustomFieldFooDetected -Value $detected
        Write-Host "Wrote $detected to '$env:CustomFieldFooDetected'"
    } catch {
        Write-Host "ERROR: Failed to write '$env:CustomFieldFooDetected' - $_"
    }
}
```

**HTML field generation** — build the string with `[System.Text.StringBuilder]` for clarity, write the final string with `Ninja-Property-Set`:
```powershell
$htmlBuilder = [System.Text.StringBuilder]::new()
[void]$htmlBuilder.Append('<p><strong>App Status:</strong> ')
if ($detected) {
    [void]$htmlBuilder.Append('<span style="color:#b22222;">Detected</span></p>')
    [void]$htmlBuilder.Append('<ul>')
    [void]$htmlBuilder.Append('<li><strong>Where:</strong> System, User</li>')
    [void]$htmlBuilder.Append('</ul>')
} else {
    [void]$htmlBuilder.Append('<span style="color:#228b22;">Not Detected</span></p>')
}
$detailsHtml = $htmlBuilder.ToString()
Ninja-Property-Set -Name $env:CustomFieldFooDetails -Value $detailsHtml
```

**`Ninja-Property-Set` and `Ninja-Property-Get` only work in SYSTEM context.** They shell out to `ninjarmm-cli.exe` which lives in a SYSTEM-only path. From a user-context script the cmdlets fall over with `"Failed to start ninjarmm-cli. Unable to find ninjarmm-cli.exe."` and — worse — that error string comes back as the apparent return value of `Ninja-Property-Get`, so naive read-modify-write logic will happily store the error message in the custom field. **Never call these cmdlets from a user-context script.** See the cross-context pattern below.

**Naming convention for custom field RMM variables:** `$env:CustomField<Domain><Description>`:
- `$env:CustomFieldGoogleChromeRemoteDesktopDetected`
- `$env:CustomFieldGoogleChromeRemoteDesktopContextFoundIn`
- `$env:CustomFieldGoogleChromeRemoteDesktopFoundDetails`

The default value (the actual NinjaRMM field name) should be camelCase matching the variable name without the `CustomField` prefix:
```powershell
if ([string]::IsNullOrEmpty($env:CustomFieldGoogleChromeRemoteDesktopDetected)) {
    $env:CustomFieldGoogleChromeRemoteDesktopDetected = "googleChromeRemoteDesktopDetected"
}
```

### Cross-Context Detection (User + System Split)

Some detection tasks need both SYSTEM-visible state (HKLM, services, processes) and per-user state (HKCU, `%LOCALAPPDATA%`). Because:
1. `Ninja-Property-Set` only works in SYSTEM context
2. SYSTEM context can't see per-user `HKCU` or `%LOCALAPPDATA%`

… you can't do everything in one script. The pattern is **two scripts plus a shared JSON file**:

**File layout:**
- `category/<thing>-detect-system.ps1` — runs as SYSTEM, daily and at boot triggers
- `category/<thing>-detect-user.ps1` — runs in user context, login trigger
- Shared JSON state: `$env:PUBLIC\$env:OrgName\rmm-db\<thing>-user-active.json`

**Why `$env:PUBLIC\$env:OrgName\rmm-db\`:**
- `$env:PUBLIC` resolves to `C:\Users\Public`, which is universally writable by all authenticated users with inherited permissions, so the user-context script can write without ACL setup
- `$env:OrgName` namespaces it per organization (e.g., `DTC`) so the same scripts are white-label friendly across MSP deployments — the org name is supplied as a required RMM preset variable
- `rmm-db\` makes it clear this is "shared state managed by RMM scripts"
- Each script gets its own JSON file in `rmm-db\` — keeps schemas isolated, avoids cross-script collisions

**Required RMM variable for any cross-context script:**
```powershell
## $env:OrgName - REQUIRED. Organizational identifier used to namespace shared state under %PUBLIC% (e.g., "DTC")
```

Validate it early and fail fast in RMM mode:
```powershell
if ([string]::IsNullOrEmpty($env:OrgName)) {
    if ($env:RMM -eq "1") {
        Write-Host "ERROR: \$env:OrgName is required but not set. Configure the OrgName variable in your RMM script preset."
        exit 99
    } else {
        while ([string]::IsNullOrEmpty($env:OrgName)) {
            $env:OrgName = Read-Host "Please enter the OrgName (organizational identifier, e.g. 'DTC')"
        }
    }
}
```

**Why JSON over SQLite:**
- PowerShell handles JSON natively (`ConvertFrom-Json` / `ConvertTo-Json`) — no module install, no vendored binaries
- State files are small (<1 KB) and single-endpoint scope, so SQLite's ACID guarantees and queryability aren't worth the deployment friction
- Human-readable for troubleshooting; per-script files mean no schema migrations
- Race conditions on a single endpoint are rare (login events are sequential) and the worst case is one user's entry briefly missing until their next login fixes it

**JSON schema** — keep it simple, username keyed to ISO8601 timestamp:
```json
{
  "WilmaGarraway": "2026-04-07T13:45:00Z",
  "BobSmith":      "2026-04-06T09:12:00Z"
}
```

**User-context script responsibilities:**
1. Detect the per-user state (HKCU + `%LOCALAPPDATA%`)
2. Read the JSON (treat missing/corrupt as empty hashtable)
3. If active, add/update own entry with current timestamp; if not active, remove own entry
4. Write JSON back
5. **Never call `Ninja-Property-Set` or `Ninja-Property-Get`**

**SYSTEM-context script responsibilities (sole writer to NinjaRMM):**
1. Run system-side detection (HKLM, Program Files, services, processes)
2. Read the JSON to learn which users are active
3. Compute final field values:
   - Boolean: `$systemActive -or $userActive`
   - Context label: `"System"`, `"User"`, or `"User + System"`
   - HTML details: pretty list of system hits + active usernames
4. Write all NinjaRMM custom fields (one writer = no race conditions, no merge logic)

**JSON helper functions** (lift these into any cross-context script):
```powershell
function Read-UserState {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @{} }
    try {
        $raw = Get-Content -Raw -Path $Path -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
        $hash = @{}
        foreach ($prop in $json.PSObject.Properties) {
            $hash[$prop.Name] = $prop.Value
        }
        return $hash
    } catch {
        Write-Host "  Could not read existing state file (treating as empty): $_"
        return @{}
    }
}

function Write-UserState {
    param([string]$Path, [hashtable]$State)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
    ($State | ConvertTo-Json -Depth 5) | Set-Content -Path $Path -Force
}
```

**Stale entry handling** — for most cases, the user-context script removes its own entry on uninstall and that's enough. If you need stricter staleness (e.g., for users who never log in again), have the SYSTEM script age out entries older than N days when it reads the JSON. Keep it optional — don't add complexity until you need it.

**Canonical example:** `app-google-chrome/chrome-remote-desktop-detect-system.ps1` and `app-google-chrome/chrome-remote-desktop-detect-user.ps1`.

### User Notification for Impactful Scripts

When a script will perform actions that impact the user (closing applications, rebooting, installing updates that require restarts, etc.), **always display a visible warning to the user** before taking action. This gives users time to save their work.

**Required RMM Variables for User Notifications**:
```powershell
## $NotificationDelaySeconds - Delay before impactful action (default: 120 / 2 minutes)
## $SupportPhone - Phone number to display in notification (optional)
## $SupportEmail - Email address to display in notification (optional)
```

**User Notification Pattern** (works when running as SYSTEM from RMM):

The standard `msg.exe` command often fails on modern Windows workstations. Use this scheduled task + balloon notification pattern instead, which displays a system tray balloon tip in the user's session. This method is more reliable than Windows toast notifications and doesn't trigger AV/malware detection like VBScript:

```powershell
function Send-UserNotification {
    param(
        [string]$Title,
        [string]$Message,
        [int]$DurationSeconds = 30
    )

    try {
        # Escape quotes for embedding in script
        $balloonTitle = $Title -replace '"', '`"'
        $balloonBody = $Message -replace '"', '`"'

        # PowerShell script to show balloon notification using Windows Forms
        $balloonScript = @"
Add-Type -AssemblyName System.Windows.Forms
`$balloon = New-Object System.Windows.Forms.NotifyIcon
`$balloon.Icon = [System.Drawing.SystemIcons]::Warning
`$balloon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
`$balloon.BalloonTipTitle = "$balloonTitle"
`$balloon.BalloonTipText = "$balloonBody"
`$balloon.Visible = `$true
`$balloon.ShowBalloonTip($($DurationSeconds * 1000))
Start-Sleep -Seconds $DurationSeconds
`$balloon.Dispose()
"@
        # Encode the script for safe execution
        $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($balloonScript))

        # Create scheduled task to run in user context (works when script runs as SYSTEM)
        $taskName = "UserNotification_$(Get-Random)"
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -EncodedCommand $encodedScript"
        $principal = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Limited
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date)
        $trigger.EndBoundary = (Get-Date).AddMinutes(30).ToString("yyyy-MM-ddTHH:mm:ss")
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -DeleteExpiredTaskAfter 00:00:01

        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName

        Write-Host "  [SUCCESS] User notification displayed"
        return $true
    } catch {
        Write-Host "  [WARNING] Could not display user notification: $_"
        return $false
    }
}
```

**Key Points**:
- Uses `System.Windows.Forms.NotifyIcon` - a reliable, mature API that works consistently
- No external files created (avoids AV/malware detection that VBS triggers)
- Runs via scheduled task in user context (works when main script runs as SYSTEM)
- Scheduled task auto-deletes after 30 minutes via trigger EndBoundary
- Balloon tip shows in system tray with warning icon
- Always include a configurable delay (`$NotificationDelaySeconds`) before the impactful action

**Example Usage**:
```powershell
# Before closing applications
if ($runningProcs.Count -gt 0 -and $ForceClose -eq 1) {
    Send-UserNotification -Title "Security Update" -Message "Applications will close in 2 minutes. Please save your work!"
    Start-Sleep -Seconds $NotificationDelaySeconds
    # Now close applications...
}
```

### API Integration Best Practices

**Anthropic API Integration** (from `msft-windows-upgrade-diagnostics.ps1`):

When integrating with external APIs that produce text output for RMM custom fields:

1. **Character Limit Awareness**: RMM custom fields often have strict limits (as low as 200 characters)
2. **Dual-Output Strategy**: Provide both detailed analysis (for logs) and concise summary (for custom fields)
3. **Proactive Token Limiting**: Set API `max_tokens` to 2000 to produce reasonable full output (~8000 chars)
4. **Structured Summary Extraction**: Request AI to include a SHORT_SUMMARY line for easy extraction

```powershell
# Request AI to provide SHORT_SUMMARY in output
$prompt = @"
Please analyze this data and provide:
1. Detailed analysis with reasoning
2. SHORT_SUMMARY: [concise 150 char summary on single line]
"@

# Set max_tokens for full detailed output
$requestBody = @{
    model = "claude-sonnet-4-20250514"
    max_tokens = 2000  # ~8000 chars for detailed analysis
    messages = @(
        @{
            role = "user"
            content = $prompt
        }
    )
} | ConvertTo-Json -Depth 10

# Store full output for transcript/logs
$AIOutput = $response.content[0].text

# Extract short summary for RMM custom field (under 200 chars)
$AIOutputShort = ""
if ($AIOutput -match 'SHORT_SUMMARY:\s*(.+)') {
    $AIOutputShort = $Matches[1].Trim()
    if ($AIOutputShort.Length -gt 190) {
        $AIOutputShort = $AIOutputShort.Substring(0, 190) + "..."
    }
} else {
    $AIOutputShort = "See full transcript for analysis"
}

# Use $AIOutput for transcript logs, $AIOutputShort for RMM custom fields
```

**Token-to-Character Ratio**: Claude tokens average ~4-5 characters per token in English text
- 2000 tokens ≈ 8000-10000 characters (good for full detailed output)
- Summary extraction via regex ensures custom field compliance

**RMM Platform Considerations**:
- **NinjaRMM**: Custom fields limited to 200 characters
- **ConnectWise Automate**: Variable limits depend on field type (often 255 chars)
- **Datto RMM**: Check specific field limits in platform documentation
- **Best Practice**: Always provide dual output (detailed + summary) to maximize value

### Veeam-Specific Patterns

Veeam scripts require loading the PowerShell module:
```powershell
$MyModulePath = "C:\Program Files\Veeam\Backup and Replication\Console\"
$env:PSModulePath = $env:PSModulePath + "$([System.IO.Path]::PathSeparator)$MyModulePath"
if ($Modules = Get-Module -ListAvailable -Name Veeam.Backup.PowerShell) {
    try {
        $Modules | Import-Module -WarningAction SilentlyContinue
    }
    catch {
        throw "Failed to load Veeam Modules"
    }
}
```

Version detection for conditional command execution:
```powershell
$veeamVersion = [version](Get-Item 'C:\Program Files\Veeam\Backup and Replication\Backup\Packages\VeeamDeploymentDll.dll').VersionInfo.ProductVersion
$requiredVersion = [version]"12.3.1.1139"
if ($veeamVersion -ge $requiredVersion) {
    # Use newer command syntax
} else {
    # Use legacy command syntax
}
```

### OEM Vendor Scripts

OEM scripts (`oem-dell/`, `oem-hp/`, `oem-lenovo/`) deploy and operate the vendor lifecycle tools for endpoint hardware ... BIOS configuration, driver/firmware updates, and consumer-software debloat. Each OEM follows the same four-leaf shape and the same patterns.

#### The four-leaf shape

Every OEM lives at the repo root under `oem-<vendor>/` and ships exactly four scripts, each independently runnable from RMM. RMM presets compose them per device-class:

| Leaf | Purpose | Internet check? |
|---|---|---|
| `<oem>-configure.ps1` | Apply BIOS settings from `$env:BIOS_*` env vars. Operates on already-installed Command Configure / equivalent tooling. | No |
| `<oem>-command-update-install.ps1` | Install or upgrade the vendor update tool (Dell Command Update, HP Image Assistant, Lenovo System Update). | Yes |
| `<oem>-command-update-run.ps1` | Scan + apply driver/firmware updates via the vendor CLI. Operates on already-installed tooling. | No |
| `<oem>-debloat.ps1` | Uninstall the vendor's consumer software (e.g. SupportAssist, MyDell). Keeps the lifecycle tools. | No |

Each leaf is self-contained: its OEM detection, vendor-tool detection, and translation tables are inlined directly in the file. No `lib/` subfolder, no `src/`, no build system. Helpers that multiple leaves need get duplicated across those leaves.

#### `configure` not `baseline`

The leaf is named `<oem>-configure.ps1`, not `<oem>-baseline.ps1`. The RMM operator's env-var set is the desired state. There is no static policy file in the repo. The naming is explicit so contributors don't go looking for a `.cctk` / `.repset` / WMI policy that doesn't exist.

#### `$env:BIOS_*` canonical settings table

Settings are operator-set via canonical environment variables. Each `<oem>-configure.ps1` carries its own per-OEM translation map inline that maps canonical names to vendor-native syntax. Unknown canonical names or unsupported values are logged and skipped so forward-looking presets don't break the run.

| Canonical variable | Type / allowed values | Dell | HP | Lenovo |
|---|---|---|---|---|
| `$env:BIOS_AdminPassword` | string (current admin pw, required to apply settings) | yes | yes | yes |
| `$env:BIOS_AdminPasswordNew` | string (new admin pw to set; empty = no change) | yes | yes | yes |
| `$env:BIOS_TPMEnabled` | `Enabled` / `Disabled` | yes | yes | yes |
| `$env:BIOS_TPMActivation` | `Activated` / `Deactivated` | yes | n/a (HP couples activation with enable) | yes |
| `$env:BIOS_SecureBoot` | `Enabled` / `Disabled` | yes | yes | yes |
| `$env:BIOS_VirtualizationCPU` | `Enabled` / `Disabled` | yes | yes | yes |
| `$env:BIOS_VirtualizationIOMMU` | `Enabled` / `Disabled` | yes | yes | yes |
| `$env:BIOS_WakeOnLAN` | `Enabled` / `Disabled` / `LANOnly` / `LANWLAN` | yes (Dell maps `Enabled` -> `lan`) | yes | yes |
| `$env:BIOS_BootMode` | `UEFI` / `Legacy` | yes | yes | yes |

Operators set the vars they want to apply; leave the rest blank. Each `<oem>-configure.ps1` iterates the canonical names, looks each up in its inline translation table, and emits the vendor-native call.

#### Internet check pattern (install leaves only)

`*-command-update-install.ps1` is the only leaf that needs vendor download connectivity. It checks before pulling the installer and skips cleanly when offline:

```powershell
function Test-InternetAvailable {
    try {
        $resp = Invoke-WebRequest -Uri 'https://www.msftconnecttest.com/connecttest.txt' `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        return ($resp.StatusCode -eq 200)
    } catch {
        return $false
    }
}

if (-not (Test-InternetAvailable)) {
    Write-Host "No internet connectivity detected ... skipping vendor install. Exit 0."
    if ($TranscriptStarted) { Stop-Transcript }
    exit 0
}
```

The other three leaves (`*-configure`, `*-command-update-run`, `*-debloat`) operate on already-installed tooling and intentionally do **not** include the internet check. They should still run on an endpoint that's momentarily offline.

#### Self-contained guidance

Each OEM leaf is independently runnable from RMM and inlines its own helpers (manufacturer check, vendor-tool detection, BIOS translation table, internet check where needed). The trade-off versus a shared `lib/` is intentional:

- Duplicated helpers across Dell + HP + Lenovo land in the 30-50 line range.
- Reading any one script tells you exactly what it does without grepping for includes or fat-script build output.
- No build system to operate, no `published/` branch, no marker syntax to learn.

If you find yourself wanting to share a helper across many scripts, copy it. Sweep drift via a Pester test or a periodic refactor PR ... not a build pipeline.

The standard gate sequence after the RMM-vs-interactive section:

1. Manufacturer check ... `if (-not (Test-DellHardware)) { Write-Host "Not a Dell endpoint. Skipping."; exit 0 }`
2. (Install leaves only) `if (-not (Test-InternetAvailable)) { Write-Host "Offline. Skipping vendor install."; exit 0 }`
3. Vendor-tool presence check where required (e.g. `Test-DCUInstalled` for `dell-command-update-run`).
4. Do the actual work.

Canonical example: `oem-dell/dell-configure.ps1`, `oem-dell/dell-command-update-install.ps1`, `oem-dell/dell-command-update-run.ps1`, `oem-dell/dell-debloat.ps1`.

## Testing Scripts

- **Interactive Testing**: Run script directly in PowerShell without setting `$env:RMM`. The script will prompt for `$env:Description` via `Read-Host`.
- **RMM Simulation**: Set the RMM environment variables before invoking the script:
  ```powershell
  $env:RMM = "1"
  $env:Description = "Test run"
  $env:CustomFieldFooBoolean = "fooDetected"  # if applicable
  .\your-script.ps1
  ```
  Remember: NinjaRMM passes preset variables as environment variables, so this is the correct way to mimic real RMM execution.
- **Log Verification**: Always check transcript logs after execution. SYSTEM-context scripts log to `$env:WINDIR\logs\`; user-context scripts log to `$env:LOCALAPPDATA\dtc-logs\`.

## Repository Context

- **Primary Use Case**: Deployment and automation scripts for MSP environments
- **Execution Context**: Windows endpoints, servers, and management consoles
- **RMM Platforms**: Designed for integration with NinjaRMM, ConnectWise Automate, ConnectWise Control
- **Target Audience**: MSP technicians and automation engineers

## Git Workflow

See [DTC KB ... Change Taxonomy](https://kb.dtctoday.com/books/developer-operations-devops/page/change-taxonomy) for the canonical reference. This file mirrors the rules; the KB is authoritative.

**Branching Model:**
* `main` ... default branch and release branch. Production code deployed to customer environments lives here.
* This repo has no `development` branch. Feature/fix PRs target `main` directly.
* All changes go through a typed branch and a pull request ... no direct commits to `main` (exception: minor `CLAUDE.md` / `README.md` doc updates that do not affect script functionality).

**CRITICAL: All changes must be made in a typed branch, never directly to `main`.**

### Change Taxonomy (two-tier ... Halo / GitHub / branch)

Every change to this repo maps to one of four categories under two parent types. The category drives the branch prefix, the GitHub labels, and the default semver bump (future-state: this repo has no semver versioning today, but the bump column is recorded for when it does). `Refactor` spans both parent types ... see the table.

| Halo Type | Halo Category | GitHub labels | Branch prefix | Default semver |
|---|---|---|---|---|
| `Problem` | `Bug` | `type:problem` + `category:bug` | `bug/{name}` | Patch |
| `Problem` | `Refactor` | `type:problem` + `category:refactor` | `refactor/{name}` | Patch |
| `Enhancement` | `Feature` | `type:enhancement` + `category:feature` | `feature/{name}` | Minor |
| `Enhancement` | `Improvement` | `type:enhancement` + `category:improvement` | `improvement/{name}` | Minor |
| `Enhancement` | `Refactor` | `type:enhancement` + `category:refactor` | `refactor/{name}` | Minor |

How to pick:
- **Bug** ... the script doesn't do what it was designed to do. Null check missing, wrong path, broken regex, off-by-one.
- **Refactor** ... a redesign of how something is shaped. Spans both parent types ... `Problem/Refactor` when the original design was wrong (broken-shape redo, patch bump); `Enhancement/Refactor` when the original design works but is clunky (working-but-clunky redo, minor bump). Same branch prefix and same `category:refactor` label either way; the parent type column disambiguates motivation and semver.
- **Improvement** ... an existing capability done better. Hardening, polish, clearer error output, integrity checks added to existing downloads.
- **Feature** ... net-new capability. A new script, new delivery mechanism, new integration target.

**`BREAKING:` PR title prefix** forces a major version bump regardless of category. (Future-state: applies once this repo carries a semver version.)

**Name branches after the change, not the fix.** Good: `bug/iso-dismount-fails-on-server-2022`, `feature/jsdelivr-script-delivery`. Bad: `bug/my-fix`, `feature/wip`.

**`dependabot/*` branches** ... categorize by the upstream change. CVE or upstream defect → `bug`. Major-version bump that takes new capability → `improvement` or `feature`.

**Legacy prefixes:** `enhancement/` and `problem/` are deprecated by this taxonomy. Existing branches with these prefixes are accepted as-is and can merge under their original names; new work uses the four-prefix model above (`bug/`, `refactor/`, `improvement/`, `feature/`).

### GitHub Labels

Two-tier label set, one of each per PR:

**Type labels:** `type:problem`, `type:enhancement`

**Category labels:** `category:bug`, `category:refactor`, `category:improvement`, `category:feature`

The legacy single-tier labels (`bug`, `enhancement`, `feature`) remain on the repo for issues opened under the old convention. New issues and PRs use the two-tier labels.

### Workflow for All Changes

1. **Create a typed branch off `main`**
   ```bash
   git checkout main
   git pull
   git checkout -b feature/descriptive-name
   # or bug/, refactor/, improvement/ per the taxonomy above
   ```

   Examples:
   - `feature/jsdelivr-script-delivery`
   - `improvement/vendor-download-integrity`
   - `bug/iso-dismount-error`
   - `refactor/rmm-input-handler-shared-helper`

2. **Make changes on the branch**
   - Make all code modifications on the typed branch
   - Commit changes with descriptive messages
   - Test thoroughly in both interactive and RMM modes

3. **Push branch**
   ```bash
   git push -u origin feature/descriptive-name
   ```

4. **Create pull request**
   - Open PR from your branch to `main`
   - Apply the two labels from the taxonomy table (one `type:*` + one `category:*`)
   - Include description of changes, testing performed, and RMM compatibility
   - Wait for review and approval before merging

5. **Merge to `main`**
   - Only merge after testing and approval
   - Delete the branch after successful merge

### If Changes Are Accidentally Committed to Main

```bash
# Revert the commit from main
git revert <commit-hash> --no-edit
git push

# Create the typed branch and restore the changes
git checkout -b feature/descriptive-name
git cherry-pick <commit-hash>
git push -u origin feature/descriptive-name
```

### Exception: Documentation Updates

Minor documentation updates to `CLAUDE.md` or `README.md` may be committed directly to `main` if they do not affect script functionality.
