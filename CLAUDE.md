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
   - Detects execution context via `$RMM` variable (1 = RMM mode, undefined = interactive mode)
   - Interactive mode: Prompts user with `Read-Host` for required inputs with validation loop
   - RMM mode: Uses pre-set variables passed by RMM platform
   - Sets `$LogPath` based on context:
     - Interactive: `$ENV:WINDIR\logs\`
     - RMM: `$RMMScriptPath\logs\` (fallback to `$ENV:WINDIR\logs\` if null)
   - Always captures `$Description` for audit trail

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

## Testing Scripts

- **Interactive Testing**: Run script directly in PowerShell without setting `$RMM` variable
- **RMM Simulation**: Set `$RMM=1` and pre-define required variables before running script
- **Log Verification**: Always check transcript logs in `$ENV:WINDIR\logs\` after execution

## Repository Context

- **Primary Use Case**: Deployment and automation scripts for MSP environments
- **Execution Context**: Windows endpoints, servers, and management consoles
- **RMM Platforms**: Designed for integration with NinjaRMM, ConnectWise Automate, ConnectWise Control
- **Target Audience**: MSP technicians and automation engineers
