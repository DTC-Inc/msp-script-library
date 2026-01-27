# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is an MSP (Managed Service Provider) script library containing PowerShell scripts for automation, deployment, configuration, and management tasks across various platforms and vendors. Scripts are designed to be executed both interactively and via RMM (Remote Monitoring and Management) platforms.

## Git Workflow and Branching Strategy

**CRITICAL: All changes must be made in enhancement or problem branches, never directly to `main`.**

### Branch Protection
- The `main` branch represents production code deployed to customer environments
- All script modifications must go through enhancement/problem branches and pull requests
- Direct commits to `main` are prohibited to prevent untested code from reaching production

### Workflow for All Changes

1. **Create an Enhancement or Problem Branch**
   ```bash
   git checkout -b enhancement/descriptive-name
   # or
   git checkout -b problem/descriptive-name
   ```
   Branch naming convention: `enhancement/` or `problem/` prefix followed by descriptive name
   - `enhancement/` - New features, improvements, or enhancements
   - `problem/` - Bug fixes, hotfixes, or any issue resolution

   Examples:
   - `enhancement/admin-user-180day-deletion`
   - `problem/iso-dismount-error`
   - `problem/script-hanging-rmm`

2. **Make Changes on the Branch**
   - Make all code modifications on the enhancement or problem branch
   - Commit changes with descriptive messages
   - Test thoroughly in both interactive and RMM modes

3. **Push Branch**
   ```bash
   git push -u origin enhancement/descriptive-name
   ```

4. **Create Pull Request**
   - Create PR from your branch to `main`
   - Include description of changes, testing performed, and RMM compatibility
   - Wait for review and approval before merging

5. **Merge to Main**
   - Only merge after testing and approval
   - Delete branch after successful merge

### If Changes Are Accidentally Committed to Main

If changes are committed and pushed to `main` before creating a proper branch:

```bash
# Revert the commit from main
git revert <commit-hash> --no-edit
git push

# Create enhancement/problem branch and restore the changes
git checkout -b enhancement/descriptive-name
git cherry-pick <commit-hash>
git push -u origin enhancement/descriptive-name
```

### Exception: Documentation Updates

Minor documentation updates to `CLAUDE.md` or `README.md` may be committed directly to `main` if they do not affect script functionality.

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

### User Notification for Impactful Scripts

When a script will perform actions that impact the user (closing applications, rebooting, installing updates that require restarts, etc.), **always display a visible warning to the user** before taking action. This gives users time to save their work.

**Required RMM Variables for User Notifications**:
```powershell
## $NotificationDelaySeconds - Delay before impactful action (default: 120 / 2 minutes)
## $SupportPhone - Phone number to display in notification (optional)
## $SupportEmail - Email address to display in notification (optional)
```

**User Notification Pattern** (works when running as SYSTEM from RMM):

The standard `msg.exe` command often fails on modern Windows workstations. Use this scheduled task + toast notification pattern instead, which displays a Windows toast notification in the user's session without triggering AV/malware detection:

```powershell
function Send-UserNotification {
    param(
        [string]$Title,
        [string]$Message
    )

    try {
        # Escape single quotes for embedding in script
        $toastTitle = $Title -replace "'", "''"
        $toastBody = $Message -replace "'", "''"

        # Build toast notification PowerShell script (no external files needed)
        $toastScript = @"
`$null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
`$null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
`$toastXml = @'
<toast duration="long" scenario="urgent">
    <visual>
        <binding template="ToastGeneric">
            <text>$toastTitle</text>
            <text>$toastBody</text>
        </binding>
    </visual>
    <audio src="ms-winsoundevent:Notification.Looping.Alarm2" loop="false"/>
</toast>
'@
`$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
`$xml.LoadXml(`$toastXml)
`$toast = New-Object Windows.UI.Notifications.ToastNotification `$xml
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Microsoft.Windows.Shell.RunDialog').Show(`$toast)
"@
        # Encode the script for safe execution
        $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($toastScript))

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
- No external files created (avoids AV/malware detection that VBS triggers)
- Uses Windows 10/11 native toast notification API via encoded PowerShell command
- Scheduled task auto-deletes after 30 minutes via trigger EndBoundary
- Uses `scenario="urgent"` for high-priority notification appearance
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

## Testing Scripts

- **Interactive Testing**: Run script directly in PowerShell without setting `$RMM` variable
- **RMM Simulation**: Set `$RMM=1` and pre-define required variables before running script
- **Log Verification**: Always check transcript logs in `$ENV:WINDIR\logs\` after execution

## Repository Context

- **Primary Use Case**: Deployment and automation scripts for MSP environments
- **Execution Context**: Windows endpoints, servers, and management consoles
- **RMM Platforms**: Designed for integration with NinjaRMM, ConnectWise Automate, ConnectWise Control
- **Target Audience**: MSP technicians and automation engineers
