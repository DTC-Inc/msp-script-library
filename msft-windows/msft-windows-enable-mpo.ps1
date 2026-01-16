## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $Description

# This script re-enables Multiplane Overlay (MPO) by removing the OverlayTestMode registry value.
# Use this to reverse the effects of msft-windows-disable-mpo.ps1
# Note: On some older machines, disabling MPO can cause screen flickering - this script fixes that.

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-enable-mpo.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"

} else {
    # Store the logs in the RMMScriptPath
    if ($null -ne $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
    }

    if ($null -eq $Description) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $Description = "Windows Multiplane Overlay (MPO) Enable"
    }
}

# Start the script logic here.

$TranscriptStarted = $false
try {
    Start-Transcript -Path $LogPath -ErrorAction Stop
    $TranscriptStarted = $true
} catch {
    Write-Host "Warning: Could not start transcript logging to $LogPath - $($_.Exception.Message)"
}

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM `n"

Write-Host "=== Windows Multiplane Overlay (MPO) Enable Script ===" -ForegroundColor Cyan
Write-Host "This script re-enables MPO by removing the OverlayTestMode registry value." -ForegroundColor White
Write-Host ""

try {
    # Check if running as administrator
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-Error "This script must be run as Administrator to modify system registry."
        if ($TranscriptStarted) { Stop-Transcript }
        exit 1
    }

    Write-Host "Running with Administrator privileges" -ForegroundColor Green
    Write-Host ""

    # Step 1: Check current MPO status
    Write-Host "Step 1: Checking current MPO status..." -ForegroundColor Yellow

    $dwmPath = "HKLM:\SOFTWARE\Microsoft\Windows\Dwm"

    if (!(Test-Path $dwmPath)) {
        Write-Host "  Registry path does not exist: $dwmPath" -ForegroundColor Yellow
        Write-Host "  MPO is already enabled (default state)." -ForegroundColor Green
        if ($TranscriptStarted) { Stop-Transcript }
        exit 0
    }

    $currentValue = $null
    try {
        $currentValue = Get-ItemProperty -Path $dwmPath -Name "OverlayTestMode" -ErrorAction Stop
        Write-Host "  Current OverlayTestMode = $($currentValue.OverlayTestMode)" -ForegroundColor Yellow
    } catch {
        Write-Host "  OverlayTestMode registry value not found." -ForegroundColor Yellow
        Write-Host "  MPO is already enabled (default state)." -ForegroundColor Green
        if ($TranscriptStarted) { Stop-Transcript }
        exit 0
    }

    Write-Host ""

    # Step 2: Remove OverlayTestMode to re-enable MPO
    Write-Host "Step 2: Re-enabling Multiplane Overlay (MPO)..." -ForegroundColor Yellow

    try {
        Remove-ItemProperty -Path $dwmPath -Name "OverlayTestMode" -Force -ErrorAction Stop
        Write-Host "  Removed OverlayTestMode registry value" -ForegroundColor Green
        Write-Host "  MPO is now enabled (Windows default)" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to remove OverlayTestMode: $($_.Exception.Message)" -ForegroundColor Red
        if ($TranscriptStarted) { Stop-Transcript }
        exit 1
    }

    Write-Host ""

    # Step 3: Verify the setting was removed
    Write-Host "Step 3: Verifying MPO enable..." -ForegroundColor Yellow

    try {
        $verifyValue = Get-ItemProperty -Path $dwmPath -Name "OverlayTestMode" -ErrorAction Stop
        Write-Host "  Warning: OverlayTestMode still exists = $($verifyValue.OverlayTestMode)" -ForegroundColor Yellow
    } catch {
        Write-Host "  Verified: OverlayTestMode registry value removed" -ForegroundColor Green
    }

    Write-Host ""

    # Final summary
    Write-Host "=== Configuration Summary ===" -ForegroundColor Cyan
    Write-Host "Multiplane Overlay (MPO): Enabled (Windows default)" -ForegroundColor Green
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "MPO re-enabled successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Why re-enable MPO:" -ForegroundColor Cyan
    Write-Host "  - Fixes screen flickering on some older machines" -ForegroundColor White
    Write-Host "  - Restores Windows default display behavior" -ForegroundColor White
    Write-Host "  - May improve performance on systems that work well with MPO" -ForegroundColor White
    Write-Host ""
    Write-Host "Note: A system restart is required for changes to take effect." -ForegroundColor Yellow

} catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
    Write-Host "Error details: $($_.Exception)" -ForegroundColor Red
    if ($TranscriptStarted) { Stop-Transcript }
    exit 1
}

if ($TranscriptStarted) { Stop-Transcript }
