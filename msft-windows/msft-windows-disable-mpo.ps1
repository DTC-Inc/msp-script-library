## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $Description

# This script disables Multiplane Overlay (MPO) which causes:
# - Video game stuttering and frame drops
# - Screen flickering in games
# - Black screens or artifacts
# - Performance degradation with multiple monitors
# MPO is a Windows DWM feature that can conflict with game rendering

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "msft-windows-disable-mpo.log"

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
        $Description = "Windows Multiplane Overlay (MPO) Disable"
    }
}

# Start the script logic here.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM `n"

Write-Host "=== Windows Multiplane Overlay (MPO) Disable Script ===" -ForegroundColor Cyan
Write-Host "This script disables MPO to fix game stuttering and performance issues." -ForegroundColor White
Write-Host ""

try {
    # Check if running as administrator
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-Error "This script must be run as Administrator to modify system registry."
        exit 1
    }

    Write-Host "Running with Administrator privileges" -ForegroundColor Green
    Write-Host ""

    # Step 1: Disable MPO via DWM registry key
    Write-Host "Step 1: Disabling Multiplane Overlay (MPO)..." -ForegroundColor Yellow

    $dwmPath = "HKLM:\SOFTWARE\Microsoft\Windows\Dwm"

    if (!(Test-Path $dwmPath)) {
        New-Item -Path $dwmPath -Force | Out-Null
        Write-Host "  Created registry path: $dwmPath" -ForegroundColor Gray
    }

    try {
        # OverlayTestMode = 5 disables MPO
        Set-ItemProperty -Path $dwmPath -Name "OverlayTestMode" -Value 5 -Type DWord -Force
        Write-Host "  OverlayTestMode = 5 (MPO Disabled)" -ForegroundColor Green
    } catch {
        Write-Host "  Failed to set OverlayTestMode: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    Write-Host ""

    # Step 2: Verify the setting
    Write-Host "Step 2: Verifying MPO disable setting..." -ForegroundColor Yellow

    try {
        $currentValue = Get-ItemProperty -Path $dwmPath -Name "OverlayTestMode" -ErrorAction Stop
        if ($currentValue.OverlayTestMode -eq 5) {
            Write-Host "  Verified: OverlayTestMode = $($currentValue.OverlayTestMode)" -ForegroundColor Green
        } else {
            Write-Host "  Warning: OverlayTestMode = $($currentValue.OverlayTestMode) (expected 5)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  Could not verify setting: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host ""

    # Final summary
    Write-Host "=== Configuration Summary ===" -ForegroundColor Cyan
    Write-Host "Multiplane Overlay (MPO): Disabled" -ForegroundColor Green
    Write-Host "===============================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "MPO disabled successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "What this fixes:" -ForegroundColor Cyan
    Write-Host "  - Game stuttering and microstutter" -ForegroundColor White
    Write-Host "  - Frame drops and inconsistent frame times" -ForegroundColor White
    Write-Host "  - Screen flickering in fullscreen games" -ForegroundColor White
    Write-Host "  - Black screen issues" -ForegroundColor White
    Write-Host "  - Multi-monitor gaming issues" -ForegroundColor White
    Write-Host ""
    Write-Host "Note: A system restart is required for changes to take effect." -ForegroundColor Yellow
    Write-Host "Note: To re-enable MPO, delete the OverlayTestMode registry value." -ForegroundColor Yellow

} catch {
    Write-Error "An error occurred: $($_.Exception.Message)"
    Write-Host "Error details: $($_.Exception)" -ForegroundColor Red
    exit 1
}

Stop-Transcript
