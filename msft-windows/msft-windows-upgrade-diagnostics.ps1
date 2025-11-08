## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $RMM
## $anthropicApiKey

### ————— MSP RMM VARIABLE INITIALIZATION GOES HERE —————
# Example for NinjaRMM:
# $RMM = 1 (automatic)
# $anthropicApiKey = Ninja custom field or organization variable
#
# Example for ConnectWise Automate:
# $RMM = 1
# $anthropicApiKey = %anthropicapikey%
#
# Example for Datto RMM:
# $RMM = 1
# $anthropicApiKey = $env:anthropicApiKey
### ————— END RMM VARIABLE INITIALIZATION —————

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-upgrade-diagnostics.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        # Remember to make ValidInput = 1 whenever correct input is given.
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }

    # Prompt for API key in interactive mode
    $ValidInput = 0
    while ($ValidInput -ne 1) {
        $anthropicApiKey = Read-Host "Please enter your Anthropic API key" -AsSecureString
        $tempKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($anthropicApiKey))
        if ($tempKey) {
            $anthropicApiKey = $tempKey
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }

    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

} else {
    # Store the logs in the RMMScriptPath
    if ($null -eq $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"

    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

    }

    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "No Description"
    }
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"

<#
.SYNOPSIS
    Reads Windows Panther setup error logs and sends them to Anthropic AI for diagnostic analysis.

.DESCRIPTION
    This script detects Windows upgrade/installation errors by reading the Panther logs,
    then sends them to Claude (Anthropic AI) for intelligent diagnostic reasoning.

    The AI provides:
    - Most likely root cause with high confidence
    - Detailed reasoning and evidence
    - Actionable next steps to resolve the issue
    - Brief summary of other possible causes

.NOTES
    Author: Nathaniel Smith / Claude Code
    Requires: Anthropic API key
    Panther Log Locations:
    - C:\Windows\Panther\setuperr.log
    - C:\Windows\Panther\setupact.log
    - C:\$Windows.~BT\Sources\Panther\setuperr.log
#>

### ————— VALIDATE REQUIRED VARIABLES —————
if ([string]::IsNullOrWhiteSpace($anthropicApiKey)) {
    Write-Error "CRITICAL: anthropicApiKey variable is not set. This must be configured in your RMM or set manually."
    Stop-Transcript
    exit 1
}

### ————— PANTHER LOG LOCATIONS —————
$pantherLocations = @(
    "$env:SystemRoot\Panther\setuperr.log",
    "$env:SystemRoot\Panther\setupact.log",
    "$env:SystemDrive\`$Windows.~BT\Sources\Panther\setuperr.log",
    "$env:SystemDrive\`$Windows.~BT\Sources\Panther\setupact.log"
)

Write-Output "Searching for Windows Panther setup logs..."

### ————— FIND AND READ PANTHER LOGS —————
$logContent = ""
$foundLogs = @()

foreach ($logPath in $pantherLocations) {
    if (Test-Path $logPath) {
        Write-Output "Found log: $logPath"
        $foundLogs += $logPath
        try {
            $content = Get-Content -Path $logPath -Raw -ErrorAction Stop
            if ($content) {
                $logContent += "`n`n=== LOG: $logPath ===`n`n"
                $logContent += $content
            }
        } catch {
            Write-Warning "Could not read ${logPath}: $($_)"
        }
    }
}

if ($foundLogs.Count -eq 0) {
    Write-Output "No Panther logs found. This may indicate:"
    Write-Output "  - No Windows upgrade has been attempted recently"
    Write-Output "  - Upgrade completed successfully without errors"
    Write-Output "  - Logs have been cleaned up"
    Stop-Transcript
    exit 0
}

if ([string]::IsNullOrWhiteSpace($logContent)) {
    Write-Output "Panther logs exist but are empty or unreadable."
    Stop-Transcript
    exit 0
}

Write-Output "`nFound $($foundLogs.Count) log file(s) with content."
Write-Output "Total log size: $($logContent.Length) characters"

### ————— PREPARE API REQUEST —————
Write-Output "`nPreparing diagnostic request to Anthropic AI..."

# Truncate log if too large (keep last 100KB to get most recent errors)
$maxLogSize = 100000
if ($logContent.Length -gt $maxLogSize) {
    Write-Output "Log content is large ($($logContent.Length) chars), truncating to last $maxLogSize characters..."
    $logContent = $logContent.Substring($logContent.Length - $maxLogSize)
}

$prompt = @"
You are a Windows upgrade diagnostics expert. I need you to analyze Windows Panther setup error logs and provide diagnostic reasoning.

ANALYZE THESE WINDOWS SETUP LOGS:

$logContent

---

Please provide:

1. **PRIMARY DIAGNOSIS** (Most Likely Root Cause):
   - State your highest confidence diagnosis with a confidence level (e.g., "HIGH CONFIDENCE: 85%")
   - Provide detailed reasoning based on specific error codes, patterns, and log evidence
   - Explain WHY this is the most likely cause
   - Quote specific error messages or codes that support this diagnosis

2. **RECOMMENDED ACTIONS** (Next Steps):
   - Provide 3-5 actionable steps to resolve the primary diagnosis
   - Be specific with commands, registry paths, file locations, etc.
   - Prioritize steps by likelihood of success

3. **ALTERNATIVE POSSIBILITIES** (Brief):
   - List 2-3 other possible causes with lower confidence levels
   - One sentence each explaining why they're less likely

4. **SHORT SUMMARY** (REQUIRED - Must be on a line starting with "SHORT_SUMMARY:"):
   - On a single line, provide a 150 character or less conclusive summary
   - Format: "SHORT_SUMMARY: [error_code/type] - [root cause] - [quick action]"
   - Example: "SHORT_SUMMARY: 0xC1900101-0x20017 - Driver incompatibility (Realtek) - Update/remove driver"

Focus heavily on the PRIMARY DIAGNOSIS with detailed evidence and reasoning. Keep alternative possibilities brief.

If no errors are found, state that clearly.
"@

$requestBody = @{
    model = "claude-sonnet-4-20250514"
    max_tokens = 2000  # ~8000 chars to stay under 9000 char RMM field limit
    messages = @(
        @{
            role = "user"
            content = $prompt
        }
    )
} | ConvertTo-Json -Depth 10

### ————— CALL ANTHROPIC API —————
Write-Output "Sending logs to Claude for analysis..."

try {
    $headers = @{
        "x-api-key" = $anthropicApiKey
        "anthropic-version" = "2023-06-01"
        "content-type" = "application/json"
    }

    $response = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" `
        -Method Post `
        -Headers $headers `
        -Body $requestBody `
        -ErrorAction Stop

    Write-Output "`n=========================================="
    Write-Output "AI DIAGNOSTIC ANALYSIS"
    Write-Output "==========================================`n"

    $AIOutput = $response.content[0].text
    Write-Output $AIOutput

    Write-Output "`n=========================================="
    Write-Output "END OF ANALYSIS"
    Write-Output "==========================================`n"

    # Extract short summary from AI output (for RMM custom fields with character limits)
    $AIOutputShort = ""
    if ($AIOutput -match 'SHORT_SUMMARY:\s*(.+)') {
        $AIOutputShort = $Matches[1].Trim()
        # Ensure it's under 200 characters
        if ($AIOutputShort.Length -gt 190) {
            $AIOutputShort = $AIOutputShort.Substring(0, 190) + "..."
        }
        Write-Output "Short Summary: $AIOutputShort"
    } else {
        # Fallback if AI didn't provide short summary
        $AIOutputShort = "See full transcript for diagnosis"
        Write-Output "Warning: AI did not provide SHORT_SUMMARY. Using fallback."
    }

    ### ————— TUNNEL OUTPUT VARIABLE TO YOUR RMM HERE —————
    # The AI diagnostic output is stored in TWO variables:
    # - $AIOutput: Full detailed analysis (for transcript/logs)
    # - $AIOutputShort: Concise summary under 200 chars (for RMM custom fields)
    #
    # Example for NinjaRMM:
    # if (Get-Command 'Ninja-Property-Set' -ErrorAction SilentlyContinue) {
    #     Ninja-Property-Set -Name 'windowsUpgradeAIDiagnostic' -Value $AIOutputShort
    # }
    #
    # Example for ConnectWise Automate:
    # Set-ItemProperty -Path "HKLM:\SOFTWARE\LabTech\Service" -Name "WinUpgradeDiag" -Value $AIOutputShort
    #
    # Example for Datto RMM:
    # Write-Host "<-Start Result->"
    # Write-Host "DIAGNOSIS: $AIOutputShort"
    # Write-Host "<-End Result->"
    ### ————— END RMM OUTPUT TUNNEL —————

} catch {
    $errorMsg = $_.Exception.Message
    $statusCode = $_.Exception.Response.StatusCode.value__
    $statusDesc = $_.Exception.Response.StatusDescription

    Write-Error "Failed to get AI analysis: $errorMsg"
    Write-Error "Status Code: $statusCode"
    Write-Error "Status Description: $statusDesc"

    if ($_.ErrorDetails.Message) {
        Write-Error "API Error Details: $($_.ErrorDetails.Message)"
    }

    Stop-Transcript
    exit 1
}

Write-Output "`nDiagnostic analysis completed successfully."
Write-Output "Logs analyzed from: $($foundLogs -join ', ')"

Stop-Transcript
