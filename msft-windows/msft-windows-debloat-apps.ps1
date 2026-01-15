## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## $RMM = 1
## $RemoveXbox = $true          # Remove Xbox apps
## $RemoveCommunications = $true # Remove People, Mail, Calendar, Skype
## $RemoveMaps = $true          # Remove Maps
## $RemoveEntertainment = $true # Remove Zune Music/Video, Solitaire
## $RemoveMiscBloat = $true     # Remove 3D Builder, Print3D, etc.

# This script removes default Windows apps (bloatware) that are typically
# not needed in business environments.
# Use Case: Deploy via RMM during initial workstation setup

#Requires -RunAsAdministrator

$ScriptLogName = "msft-windows-debloat-apps.log"

# Default values - remove everything unless specified otherwise
if ($null -eq $RemoveXbox) { $RemoveXbox = $true }
if ($null -eq $RemoveCommunications) { $RemoveCommunications = $true }
if ($null -eq $RemoveMaps) { $RemoveMaps = $true }
if ($null -eq $RemoveEntertainment) { $RemoveEntertainment = $true }
if ($null -eq $RemoveMiscBloat) { $RemoveMiscBloat = $true }

if ($RMM -ne 1) {
    $ValidInput = 0
    while ($ValidInput -ne 1) {
        $Description = Read-Host "Please enter the ticket # and/or your initials"
        if ($Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
} else {
    if ($null -ne $RMMScriptPath) {
        $LogPath = "$RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$ENV:WINDIR\logs\$ScriptLogName"
    }

    if ($null -eq $Description) {
        $Description = "RMM-initiated app debloating"
    }
}

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
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
                $appxPackage | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            }

            if ($provisionedPackage) {
                $provisionedPackage | Remove-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
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
