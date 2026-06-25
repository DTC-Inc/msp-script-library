## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $Description          / $env:Description          - Ticket # or initials for audit trail
## $RMMScriptPath        / $env:RMMScriptPath        - Optional log directory base provided by the RMM
## $RemoveXbox           / $env:RemoveXbox           - Remove Xbox apps (default: true)
## $RemoveCommunications / $env:RemoveCommunications - Remove People, Mail, Calendar, Skype (default: true)
## $RemoveMaps           / $env:RemoveMaps           - Remove Maps (default: true)
## $RemoveEntertainment  / $env:RemoveEntertainment  - Remove Zune Music/Video, Solitaire (default: true)
## $RemoveMiscBloat      / $env:RemoveMiscBloat      - Remove 3D Builder, Print3D, etc. (default: true)

# This script removes default Windows apps (bloatware) that are typically
# not needed in business environments.
# Use Case: Deploy via RMM during initial workstation setup

#Requires -RunAsAdministrator

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-Description ...) or from an RMM that supplies values as env variables.
    [string]$Description          = $env:Description,
    [string]$RMMScriptPath        = $env:RMMScriptPath,
    [string]$RemoveXbox           = $env:RemoveXbox,
    [string]$RemoveCommunications = $env:RemoveCommunications,
    [string]$RemoveMaps           = $env:RemoveMaps,
    [string]$RemoveEntertainment  = $env:RemoveEntertainment,
    [string]$RemoveMiscBloat      = $env:RemoveMiscBloat
)

$ScriptLogName = "msft-windows-debloat-apps.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Default values - remove everything unless specified otherwise. The Remove* inputs arrive as
# strings (RMM/-Parameter); an empty value means "not supplied" so we default it to $true,
# otherwise coerce the supplied string ("true"/"false"/"1"/"0") to a boolean.
if ([string]::IsNullOrEmpty($RemoveXbox))           { $RemoveXbox = $true }           else { $RemoveXbox = [System.Convert]::ToBoolean($RemoveXbox) }
if ([string]::IsNullOrEmpty($RemoveCommunications)) { $RemoveCommunications = $true } else { $RemoveCommunications = [System.Convert]::ToBoolean($RemoveCommunications) }
if ([string]::IsNullOrEmpty($RemoveMaps))           { $RemoveMaps = $true }           else { $RemoveMaps = [System.Convert]::ToBoolean($RemoveMaps) }
if ([string]::IsNullOrEmpty($RemoveEntertainment))  { $RemoveEntertainment = $true }  else { $RemoveEntertainment = [System.Convert]::ToBoolean($RemoveEntertainment) }
if ([string]::IsNullOrEmpty($RemoveMiscBloat))      { $RemoveMiscBloat = $true }      else { $RemoveMiscBloat = [System.Convert]::ToBoolean($RemoveMiscBloat) }

# Default the audit-trail description if it was not supplied. This preserves the original
# behavior where an unattended/RMM run that passed no Description used a placeholder value.
if ([string]::IsNullOrEmpty($Description)) {
    $Description = "RMM-initiated app debloating"
}

# Store logs under $RMMScriptPath if provided, otherwise the standard Windows logs directory.
if (-not [string]::IsNullOrEmpty($RMMScriptPath)) {
    $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
} else {
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
}

# Ensure log directory exists before starting transcript
$logDir = Split-Path -Path $LogPath -Parent
if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host ""

Write-Host "=== Windows App Debloating ===" -ForegroundColor Cyan
Write-Host "Removal Categories:" -ForegroundColor Yellow
Write-Host "  Xbox Apps: $RemoveXbox"
Write-Host "  Communications: $RemoveCommunications"
Write-Host "  Maps: $RemoveMaps"
Write-Host "  Entertainment: $RemoveEntertainment"
Write-Host "  Misc Bloat: $RemoveMiscBloat"
Write-Host ""

# Build list of apps to remove based on categories
$appsToRemove = @()

if ($RemoveXbox) {
    $appsToRemove += @(
        "Microsoft.Xbox.TCUI",
        "Microsoft.XboxApp",
        "Microsoft.XboxGameOverlay",
        "Microsoft.XboxGamingOverlay",
        "Microsoft.XboxIdentityProvider",
        "Microsoft.XboxSpeechToTextOverlay",
        "Microsoft.GamingApp",
        "Microsoft.GamingServices"
    )
}

if ($RemoveCommunications) {
    $appsToRemove += @(
        "Microsoft.People",
        "microsoft.windowscommunicationsapps",
        "Microsoft.SkypeApp",
        "Microsoft.Messaging",
        "Microsoft.OneConnect"
    )
}

if ($RemoveMaps) {
    $appsToRemove += @(
        "Microsoft.WindowsMaps"
    )
}

if ($RemoveEntertainment) {
    $appsToRemove += @(
        "Microsoft.ZuneMusic",
        "Microsoft.ZuneVideo",
        "Microsoft.MicrosoftSolitaireCollection",
        "Microsoft.MixedReality.Portal",
        "Microsoft.Getstarted",
        "Microsoft.GetHelp"
    )
}

if ($RemoveMiscBloat) {
    $appsToRemove += @(
        "Microsoft.3DBuilder",
        "Microsoft.Microsoft3DViewer",
        "Microsoft.Print3D",
        "Microsoft.BingFinance",
        "Microsoft.BingNews",
        "Microsoft.BingSports",
        "Microsoft.BingWeather",
        "Microsoft.BingSearch",
        "Microsoft.NetworkSpeedTest",
        "Microsoft.News",
        "Microsoft.Office.Lens",
        "Microsoft.Office.Sway",
        "Microsoft.MicrosoftOfficeHub",
        "Microsoft.Wallet",
        "Microsoft.WindowsAlarms",
        "Microsoft.WindowsFeedbackHub",
        "Microsoft.WindowsSoundRecorder",
        "Microsoft.YourPhone",
        "Microsoft.PowerAutomateDesktop",
        "Microsoft.Todos",
        "Microsoft.549981C3F5F10",
        "Clipchamp.Clipchamp",
        "MicrosoftTeams",
        "MicrosoftCorporationII.QuickAssist",
        "Disney.37853FC22B2CE"
    )
}

$removedCount = 0
$notFoundCount = 0
$failedCount = 0

foreach ($app in $appsToRemove) {
    try {
        # Remove for all users
        $appxPackage = Get-AppxPackage -Name $app -AllUsers -ErrorAction SilentlyContinue
        $provisionedPackage = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                              Where-Object DisplayName -like $app

        if ($appxPackage -or $provisionedPackage) {
            Write-Host "Removing: $app" -ForegroundColor Yellow

            if ($appxPackage) {
                $appxPackage | Remove-AppxPackage -AllUsers -ErrorAction Stop
            }

            if ($provisionedPackage) {
                $provisionedPackage | Remove-AppxProvisionedPackage -Online -ErrorAction Stop
            }

            Write-Host "Removed: $app" -ForegroundColor Green
            $removedCount++
        } else {
            $notFoundCount++
        }
    } catch {
        Write-Host "Failed to remove $app : $_" -ForegroundColor Yellow
        $failedCount++
    }
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host "Apps removed: $removedCount" -ForegroundColor Green
Write-Host "Apps not found (already removed or not installed): $notFoundCount" -ForegroundColor Gray
if ($failedCount -gt 0) {
    Write-Host "Failed to remove: $failedCount" -ForegroundColor Yellow
}
Write-Host "===============" -ForegroundColor Cyan
Write-Host ""
Write-Host "Note: Removed provisioned packages won't be installed for new users" -ForegroundColor Yellow

Stop-Transcript
