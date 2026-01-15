## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $RMM
## $anthropicApiKey

### ————— MSP RMM VARIABLE INITIALIZATION GOES HERE —————
# Example for NinjaRMM:
# $RMM = 1
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

$ScriptLogName = "msft-windows-bsod-diagnostics.log"

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
    Collects Windows BSOD crash logs and sends to Anthropic AI for diagnostic analysis.

.DESCRIPTION
    This script analyzes Blue Screen of Death (BSOD) crashes by collecting system event logs,
    bug check data, hardware error logs, and minidump information. The data is sent to Claude
    (Anthropic AI) for intelligent diagnostic reasoning.

    Data collected:
    - Event Viewer System log (Bug Check events ID 1001, 1003)
    - Kernel-Power critical errors (Event ID 41)
    - WHEA hardware error logs (Windows Hardware Error Architecture)
    - Minidump file list and recent crash timestamps
    - Critical system errors from last 30 days

    The AI provides:
    - Most likely root cause with high confidence based on bug check codes and patterns
    - Detailed reasoning and evidence from event logs
    - Actionable next steps to resolve the issue (driver updates, hardware tests, etc.)
    - Brief summary of other possible causes

.NOTES
    Author: Nathaniel Smith / Claude Code
    Requires: Anthropic API key
    Data Sources:
    - Event Viewer: System log (BugCheck, Kernel-Power, WHEA-Logger)
    - Minidump files: C:\Windows\Minidump\
    - Memory dump: C:\Windows\Memory.dmp
#>

### ————— VALIDATE REQUIRED VARIABLES —————
if ([string]::IsNullOrWhiteSpace($anthropicApiKey)) {
    Write-Error "CRITICAL: anthropicApiKey variable is not set. This must be configured in your RMM or set manually."
    Stop-Transcript
    exit 1
}

### ————— COLLECT BSOD DATA —————
Write-Output "Collecting BSOD crash data from Windows Event Logs and minidumps..."

$crashData = ""
$foundData = @()

# Collect Bug Check events (Event ID 1001) - Contains stop code and parameters
Write-Output "Searching for Bug Check events (Event ID 1001)..."
try {
    $bugCheckEvents = Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        ID = 1001
    } -MaxEvents 20 -ErrorAction SilentlyContinue

    if ($bugCheckEvents) {
        $foundData += "BugCheck Events"
        $crashData += "`n`n=== BUG CHECK EVENTS (EVENT ID 1001) ===`n`n"
        $crashData += "Found $($bugCheckEvents.Count) Bug Check event(s)`n`n"

        foreach ($event in $bugCheckEvents) {
            $crashData += "Time: $($event.TimeCreated)`n"
            $crashData += "Message:`n$($event.Message)`n"
            $crashData += "---`n"
        }
    } else {
        Write-Output "No Bug Check events found."
    }
} catch {
    Write-Output "Could not retrieve Bug Check events: $_"
}

# Collect BlueScreen events (Event ID 1003) - Additional BSOD context
Write-Output "Searching for BlueScreen events (Event ID 1003)..."
try {
    $blueScreenEvents = Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'
        ID = 1001
    } -MaxEvents 20 -ErrorAction SilentlyContinue

    if ($blueScreenEvents) {
        $foundData += "BlueScreen Events"
        $crashData += "`n`n=== BLUESCREEN EVENTS (WER) ===`n`n"
        $crashData += "Found $($blueScreenEvents.Count) BlueScreen event(s)`n`n"

        foreach ($event in $blueScreenEvents) {
            $crashData += "Time: $($event.TimeCreated)`n"
            $crashData += "Message:`n$($event.Message)`n"
            $crashData += "---`n"
        }
    }
} catch {
    Write-Output "Could not retrieve BlueScreen events: $_"
}

# Collect Kernel-Power critical errors (Event ID 41) - Unexpected shutdowns
Write-Output "Searching for Kernel-Power critical errors (Event ID 41)..."
try {
    $kernelPowerEvents = Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        ProviderName = 'Microsoft-Windows-Kernel-Power'
        ID = 41
    } -MaxEvents 20 -ErrorAction SilentlyContinue

    if ($kernelPowerEvents) {
        $foundData += "Kernel-Power Events"
        $crashData += "`n`n=== KERNEL-POWER CRITICAL ERRORS (EVENT ID 41) ===`n`n"
        $crashData += "Found $($kernelPowerEvents.Count) Kernel-Power critical error(s)`n`n"

        foreach ($event in $kernelPowerEvents) {
            $crashData += "Time: $($event.TimeCreated)`n"
            $crashData += "Message:`n$($event.Message)`n"
            $crashData += "---`n"
        }
    }
} catch {
    Write-Output "Could not retrieve Kernel-Power events: $_"
}

# Collect WHEA (Windows Hardware Error Architecture) errors
Write-Output "Searching for WHEA hardware errors..."
try {
    $wheaEvents = Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        ProviderName = 'Microsoft-Windows-WHEA-Logger'
    } -MaxEvents 50 -ErrorAction SilentlyContinue

    if ($wheaEvents) {
        $foundData += "WHEA Hardware Errors"
        $crashData += "`n`n=== WHEA HARDWARE ERRORS ===`n`n"
        $crashData += "Found $($wheaEvents.Count) WHEA hardware error(s)`n`n"

        foreach ($event in $wheaEvents) {
            $crashData += "Time: $($event.TimeCreated)`n"
            $crashData += "Event ID: $($event.Id)`n"
            $crashData += "Level: $($event.LevelDisplayName)`n"
            $crashData += "Message:`n$($event.Message)`n"
            $crashData += "---`n"
        }
    }
} catch {
    Write-Output "Could not retrieve WHEA events: $_"
}

# Collect critical system errors from last 30 days
Write-Output "Searching for recent critical system errors..."
try {
    $startTime = (Get-Date).AddDays(-30)
    $criticalErrors = Get-WinEvent -FilterHashtable @{
        LogName = 'System'
        Level = 1  # Critical
        StartTime = $startTime
    } -MaxEvents 100 -ErrorAction SilentlyContinue

    if ($criticalErrors) {
        $foundData += "Critical System Errors"
        $crashData += "`n`n=== RECENT CRITICAL SYSTEM ERRORS (LAST 30 DAYS) ===`n`n"
        $crashData += "Found $($criticalErrors.Count) critical error(s)`n`n"

        foreach ($event in $criticalErrors) {
            $crashData += "Time: $($event.TimeCreated)`n"
            $crashData += "Source: $($event.ProviderName)`n"
            $crashData += "Event ID: $($event.Id)`n"
            $crashData += "Message:`n$($event.Message)`n"
            $crashData += "---`n"
        }
    }
} catch {
    Write-Output "Could not retrieve critical system errors: $_"
}

# Check for minidump files
Write-Output "Checking for minidump files..."
$minidumpPath = "$env:SystemRoot\Minidump"
if (Test-Path $minidumpPath) {
    $minidumps = Get-ChildItem -Path $minidumpPath -Filter "*.dmp" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending

    if ($minidumps) {
        $foundData += "Minidump Files"
        $crashData += "`n`n=== MINIDUMP FILES ===`n`n"
        $crashData += "Found $($minidumps.Count) minidump file(s) in $minidumpPath`n`n"

        foreach ($dump in $minidumps | Select-Object -First 10) {
            $crashData += "File: $($dump.Name)`n"
            $crashData += "Created: $($dump.CreationTime)`n"
            $crashData += "Size: $([math]::Round($dump.Length / 1KB, 2)) KB`n"
            $crashData += "---`n"
        }
    } else {
        Write-Output "Minidump directory exists but contains no .dmp files."
    }
} else {
    Write-Output "Minidump directory not found: $minidumpPath"
}

# Check for full memory dump
$memoryDumpPath = "$env:SystemRoot\Memory.dmp"
if (Test-Path $memoryDumpPath) {
    $memoryDump = Get-Item $memoryDumpPath
    $foundData += "Memory Dump"
    $crashData += "`n`n=== FULL MEMORY DUMP ===`n`n"
    $crashData += "File: $($memoryDump.Name)`n"
    $crashData += "Created: $($memoryDump.CreationTime)`n"
    $crashData += "Size: $([math]::Round($memoryDump.Length / 1MB, 2)) MB`n"
}

# Collect system information
Write-Output "Collecting system information..."
try {
    $computerSystem = Get-WmiObject -Class Win32_ComputerSystem
    $os = Get-WmiObject -Class Win32_OperatingSystem
    $bios = Get-WmiObject -Class Win32_BIOS

    $crashData += "`n`n=== SYSTEM INFORMATION ===`n`n"
    $crashData += "Computer: $($computerSystem.Name)`n"
    $crashData += "Manufacturer: $($computerSystem.Manufacturer)`n"
    $crashData += "Model: $($computerSystem.Model)`n"
    $crashData += "OS: $($os.Caption) $($os.Version)`n"
    $crashData += "Install Date: $($os.InstallDate)`n"
    $crashData += "Last Boot: $($os.LastBootUpTime)`n"
    $crashData += "BIOS Version: $($bios.SMBIOSBIOSVersion)`n"
    $crashData += "BIOS Date: $($bios.ReleaseDate)`n"
} catch {
    Write-Output "Could not collect system information: $_"
}

if ($foundData.Count -eq 0) {
    Write-Output "No BSOD crash data found on this system."
    Write-Output "This may indicate:"
    Write-Output "  - No recent crashes or blue screens"
    Write-Output "  - Crash logs have been cleared"
    Write-Output "  - Event log service is not running properly"
    Stop-Transcript
    exit 0
}

if ([string]::IsNullOrWhiteSpace($crashData)) {
    Write-Output "Crash data sources exist but are empty or unreadable."
    Stop-Transcript
    exit 0
}

Write-Output "`nFound data from: $($foundData -join ', ')"
Write-Output "Total content size: $($crashData.Length) characters"

### ————— PREPARE API REQUEST —————
Write-Output "`nPreparing diagnostic request to Anthropic AI..."

# Truncate if too large (keep last 100KB to get most recent errors)
$maxLogSize = 100000
if ($crashData.Length -gt $maxLogSize) {
    Write-Output "Crash data is large ($($crashData.Length) chars), truncating to last $maxLogSize characters..."
    $crashData = $crashData.Substring($crashData.Length - $maxLogSize)
}

$prompt = @"
You are a Windows BSOD (Blue Screen of Death) diagnostics expert. I need you to analyze Windows crash logs, bug check events, and hardware error data to provide diagnostic reasoning.

ANALYZE THESE WINDOWS CRASH LOGS:

The data includes:
- Bug Check events (stop codes, parameters)
- Kernel-Power critical errors (unexpected shutdowns)
- WHEA hardware error logs
- Critical system errors
- Minidump file information
- System configuration details

$crashData

---

Please provide:

1. **PRIMARY DIAGNOSIS** (Most Likely Root Cause):
   - State your highest confidence diagnosis with a confidence level (e.g., "HIGH CONFIDENCE: 90%")
   - Provide detailed reasoning based on specific bug check codes, error patterns, and log evidence
   - Explain WHY this is the most likely cause
   - Quote specific stop codes, error messages, or event IDs that support this diagnosis
   - Identify the specific driver, hardware component, or software causing the crashes

2. **RECOMMENDED ACTIONS** (Next Steps):
   - Provide 3-5 actionable steps to resolve the primary diagnosis
   - Be specific with driver updates, hardware diagnostics, registry fixes, Windows updates, etc.
   - Prioritize steps by likelihood of success
   - Include specific commands or tools to run (e.g., verifier.exe, memtest, driver updates)

3. **ALTERNATIVE POSSIBILITIES** (Brief):
   - List 2-3 other possible causes with lower confidence levels
   - One sentence each explaining why they're less likely

4. **SHORT SUMMARY** (REQUIRED - Must be on a line starting with "SHORT_SUMMARY:"):
   - On a single line, provide a 150 character or less conclusive summary
   - Format: "SHORT_SUMMARY: [stop_code] - [root cause] - [quick action]"
   - Example: "SHORT_SUMMARY: 0x0000007E - Corrupted nvlddmkm.sys driver - Update/rollback NVIDIA graphics driver"

Focus heavily on the PRIMARY DIAGNOSIS with detailed evidence and reasoning. Keep alternative possibilities brief.

If no crashes are found, state that clearly.
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
Write-Output "Sending crash logs to Claude for analysis..."

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
    Write-Output "AI BSOD DIAGNOSTIC ANALYSIS"
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
    #     Ninja-Property-Set -Name 'windowsBSODAIDiagnostic' -Value $AIOutputShort
    # }
    #
    # Example for ConnectWise Automate:
    # Set-ItemProperty -Path "HKLM:\SOFTWARE\LabTech\Service" -Name "BSODDiag" -Value $AIOutputShort
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
Write-Output "Data analyzed from: $($foundData -join ', ')"

Stop-Transcript
