# msp-script-library

PowerShell automation, deployment, configuration, and management scripts for Managed Service Provider environments. Designed for both interactive use and RMM-driven execution.

## Overview

This library contains scripts that any MSP should be able to deploy. Every script supports two execution modes: interactive (a tech runs it directly with prompts) and RMM (NinjaRMM, ConnectWise Automate, ConnectWise Control, or any platform that can pass environment variables and run PowerShell). The same script works in both modes.

For deep architectural detail, see [`CLAUDE.md`](CLAUDE.md). For PR workflow and branch conventions, see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Naming Conventions

Two axes, don't conflate them:

- **Code identifiers** (variables, functions, parameters): camelCase by default unless the language specifies otherwise. PowerShell uses PascalCase for functions and camelCase for variables; Python uses snake_case.
- **Filesystem and URLs** (file names, folder names, log names, paths, slugs): kebab-case. This includes script files, log files, and any artifact written to disk or referenced by URL.

Folders follow `category-vendor` or `category-app` (kebab-case throughout). File names are lowercase with hyphens (e.g., `chrome-remote-desktop-detect-system.ps1`). Kebab-case is shell-friendly (no quoting), URL-safe, and forces a clean split between "this is a path/slug" vs "this is a code identifier."

## Quick Start

**Run a script interactively** (for testing or one-off use):
```powershell
.\app-google-chrome\chrome-remote-desktop-detect-system.ps1
# The script will prompt for $env:Description and $env:OrgName.
```

**Run a script in RMM mode** (mimicking a NinjaRMM execution):
```powershell
$env:RMM = "1"
$env:Description = "Test run"
$env:OrgName = "DTC"
.\app-google-chrome\chrome-remote-desktop-detect-system.ps1
```

**Deploy via NinjaRMM:**
1. Create a script in NinjaRMM and paste the script body
2. Add the required preset variables in the script's "Script Variables" section (at minimum: `RMM=1`, `Description`, `OrgName`)
3. Add any per-script variables (custom field names, paths, etc.) listed in the script's header comment block
4. Schedule or run on demand

## Repository Structure

Scripts are organized by category prefix:

| Prefix | Purpose |
|---|---|
| `app-*` | Application-specific scripts (Adobe, Chrome, Eaglesoft, Duo, etc.) |
| `bdr-*` | Backup and Disaster Recovery (Veeam, MSP360) |
| `db-*` | Database scripts (MySQL, etc.) |
| `iaas-*` | Infrastructure as a Service (Azure, Backblaze, Dynu) |
| `mw-*` | Middleware / Microsoft 365 |
| `msft-*` | Microsoft Windows system scripts |
| `net-*` | Networking |
| `oem-*` | OEM vendor configuration (Dell, HP, etc.) |
| `rmm-*` | RMM platform agents (NinjaOne, Automate, Control) |
| `sec-*` | Security tools (Huntress, CrowdStrike Falcon, Cynet) |
| `s3-api-lib/` | Reusable S3 API function library |

See [Naming Conventions](#naming-conventions) above for folder and file naming rules.

## Script Conventions

### Standard Template

Every PowerShell script follows the same three-part structure (see `script-template-powershell.ps1`):

1. **RMM Variable Declaration** — comment block at the top listing every variable the script reads from the RMM
2. **Input Handling** — detect interactive vs RMM mode, set log path, capture audit trail
3. **Script Logic** — wrapped in `Start-Transcript` / `Stop-Transcript`

### RMM Variables Come Via `$env:`

NinjaRMM (and most other PowerShell-aware RMM platforms) pass script preset variables to PowerShell as **environment variables**. Read them via `$env:VarName` at every use site:

```powershell
if ($env:RMM -ne "1") {
    # Interactive mode: prompt
    $env:Description = Read-Host "Ticket number or initials"
} else {
    # RMM mode: variables come pre-set
    if ([string]::IsNullOrEmpty($env:Description)) {
        $env:Description = "RMM Automated Scan"
    }
}
```

Bare `$RMM` references resolve to `$null` in true RMM mode. Always use `$env:`.

For optional variables (custom field names, state paths, etc.) set defaults at the top of the script by writing back to `$env:`:
```powershell
if ([string]::IsNullOrEmpty($env:CustomFieldFooDetected)) {
    $env:CustomFieldFooDetected = "fooDetected"
}
```

### Required Variable: `$env:OrgName`

Any script that maintains shared state on disk (cross-context detection, multi-user state, etc.) requires `$env:OrgName` — an organizational identifier used to namespace state under `%PUBLIC%`. This makes the scripts white-label friendly across MSP deployments. Set it in your RMM script preset (e.g., `OrgName=DTC`). The script will fail fast in RMM mode if it's missing.

### Logging

Every script wraps its logic in `Start-Transcript` / `Stop-Transcript`. Log paths depend on the execution context:

- **SYSTEM-context script:** `$env:WINDIR\logs\<script-name>.log` (or `$env:RMMScriptPath\logs\` if the RMM provided one)
- **User-context script:** `$env:LOCALAPPDATA\$env:OrgName-logs\<script-name>.log` — `$env:WINDIR\logs\` requires admin and a user-context script will fail to write there

## Common Patterns

### Application Detection (HKLM, HKCU, Program Files, Services, Processes)

Applications can land in many places. To reliably detect installation, check **every install vector**:

| Check | Where |
|---|---|
| HKLM uninstall registry | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*` and `WOW6432Node\` |
| HKCU uninstall registry | `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*` (per-user installs, e.g., Chrome extensions) |
| Program Files | `${env:ProgramFiles}\Vendor\App` and `${env:ProgramFiles(x86)}\Vendor\App` |
| User AppData | `$env:LOCALAPPDATA\Vendor\App` |
| Windows service | `Get-Service -Name "service-name"` |
| Running process | `Get-Process -Name "process-name"` |

A SYSTEM-context script can see HKLM, Program Files, services, and processes. It **cannot** see another user's HKCU or `%LOCALAPPDATA%` — those resolve to SYSTEM's empty profile. Per-user install detection requires a user-context script. See "Cross-Context Detection" below.

### NinjaRMM Custom Field Types

| Type | Use for | Notes |
|---|---|---|
| **Checkbox / Boolean** | Yes/no flags ("Detected", "Compliant") | Write `1` or `0` |
| **Text** | Short status strings, dropdown values | 200-char limit |
| **WYSIWYG / HTML** | Rich formatted reports | No 200-char limit, supports HTML |
| **Multi-line text** | Logs, transcripts, free-form notes | Larger limit than single-line text |

`Ninja-Property-Set` works for all field types — it figures out the type from the field's NinjaRMM configuration. Same cmdlet, different value formats.

**Critical:** `Ninja-Property-Set` and `Ninja-Property-Get` only work in **SYSTEM context**. They shell out to `ninjarmm-cli.exe` which lives in a SYSTEM-only path. From a user-context script the cmdlets fall over with `"Failed to start ninjarmm-cli. Unable to find ninjarmm-cli.exe."` and that error string comes back as the apparent return value of `Ninja-Property-Get`, so naive read-modify-write logic will store the error message in your custom field. **Never call these cmdlets from a user-context script.** Use the cross-context pattern below instead.

### Cross-Context Detection (User + System Split)

When you need both system-visible state (HKLM, services) and per-user state (HKCU, `%LOCALAPPDATA%`), and you need to write the unified result to NinjaRMM, you cannot do it in a single script. Two scripts plus a shared JSON file:

```
category/<thing>-detect-system.ps1   # runs as SYSTEM, daily + boot
category/<thing>-detect-user.ps1     # runs in user context, at login
```

Shared state file:
```
$env:PUBLIC\$env:OrgName\rmm-db\<thing>-user-active.json
```

JSON format — username keyed to ISO8601 last-detected timestamp:
```json
{
  "WilmaGarraway": "2026-04-07T13:45:00Z",
  "BobSmith":      "2026-04-06T09:12:00Z"
}
```

**Why this layout:**
- `$env:PUBLIC` (`C:\Users\Public`) is universally writable by all users with inherited permissions, no ACL setup needed
- `$env:OrgName` (a required RMM variable) namespaces per organization for white-labeling
- `rmm-db\` is the convention for "shared state managed by RMM scripts"
- Each script gets its own JSON file in `rmm-db\` — schemas stay isolated

**Why JSON over SQLite:**
- PowerShell handles JSON natively (`ConvertFrom-Json` / `ConvertTo-Json`) — no module install, no vendored binaries
- State files are tiny (<1 KB) and single-endpoint scope
- Human-readable for troubleshooting, per-script files mean no schema migrations
- Race conditions on a single endpoint are rare (login events are sequential)

**Responsibilities:**

| Script | Reads | Writes | Calls Ninja cmdlets? |
|---|---|---|---|
| User-context | HKCU, `%LOCALAPPDATA%`, JSON | JSON (own entry only) | **No** |
| SYSTEM-context (sole writer) | HKLM, Program Files, service, process, JSON | NinjaRMM custom fields | Yes |

**Canonical example:** `app-google-chrome/chrome-remote-desktop-detect-system.ps1` and `app-google-chrome/chrome-remote-desktop-detect-user.ps1`. They detect Chrome Remote Desktop in both contexts and write three custom fields:

| Field | Type | Value |
|---|---|---|
| `googleChromeRemoteDesktopDetected` | Boolean | `1` if detected anywhere, else `0` |
| `googleChromeRemoteDesktopContextFoundIn` | Text | `"System"`, `"User"`, or `"User + System"` |
| `googleChromeRemoteDesktopFoundDetails` | HTML | Pretty list of system hits + active usernames with last-seen timestamps |

See [`CLAUDE.md`](CLAUDE.md) for the full pattern documentation including helper function snippets.

## Testing

- **Interactive testing**: Run the script directly without `$env:RMM`. The script prompts for required input.
- **RMM simulation**: Set the environment variables before invoking the script (see Quick Start above).
- **Log verification**: Check the transcript log path printed in the script header.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for branch naming, PR workflow, and review process.

In short:
- All changes go through `enhancement/<name>` or `problem/<name>` branches
- Open a PR back to the default branch — no direct commits
- Use the **enhancement** label for new functionality (not "feature")
- Test in both interactive and RMM modes before requesting review
