## PLEASE COMMENT YOUR VARIALBES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "EnterLogNameHere.log"

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
    Quiet in-place upgrade Win10 → Win11 with staged NinjaRMM (or host) progress.

.DESCRIPTION
    Reports progress at 0 %, 25 %, 50 %, 75 %:
      0 % – script start
      25 % – download beginning
      50 % – download finished & ISO mounted
      75 % – setup.exe launched
    Then exits, letting Windows Setup reboot and complete the upgrade.
#>

### ————— CONFIGURATION —————
# $true = report to NinjaRMM; $false = write to host
#$RMM        = $true

# URL of your Win11 ISO
#$isoUrl     = "https://example.com/Windows11.iso"

# Where to save the ISO
$downloadDir = "$env:TEMP"
$isoPath     = Join-Path $downloadDir "Win11Upgrade.iso"

### ————— PROGRESS FUNCTION —————
function Show-Progress {
    param(
        [int]$Percent,
        [string]$Stage
    )
    if ($RMM) {
        Ninja-Property-Set windowsUpgradeProgress -Value $Percent
    } else {
        Write-Output "[$Stage] $Percent% complete"
    }
}

### ————— SCRIPT START —————
Show-Progress -Percent 0 -Stage "Start"

### ————— ELEVATION CHECK —————
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "Relaunching elevated..."
    Start-Process -FilePath "PowerShell.exe" `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
        -Verb RunAs
    exit
}

### ————— FAST ISO DOWNLOAD —————
Show-Progress -Percent 25 -Stage "Downloading"
Write-Output "Downloading ISO from $isoUrl..."

try {
    $clientHandler = [System.Net.Http.HttpClientHandler]::new()
    $clientHandler.AllowAutoRedirect = $true
    $httpClient = [System.Net.Http.HttpClient]::new($clientHandler)
    
    $response = $httpClient.GetAsync($isoUrl, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
    $response.EnsureSuccessStatusCode()

    $totalBytes = $response.Content.Headers.ContentLength
    $stream = $response.Content.ReadAsStreamAsync().Result
    $fileStream = [System.IO.File]::Create($isoPath)

    $buffer = New-Object byte[] 81920
    $totalRead = 0
    $read = 0

    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $fileStream.Write($buffer, 0, $read)
        $totalRead += $read

        $percent = if ($totalBytes -gt 0) { [int](($totalRead / $totalBytes) * 100) } else { 0 }
        Show-Progress -Percent $percent -Stage "Downloading"
    }

    $fileStream.Close()
    $stream.Close()
} catch {
    Write-Error "Download failed: $_"
    Show-Progress -Percent 0 -Stage "DownloadFailed"
    exit 1
}


### ————— MOUNT ISO —————
Write-Output "Mounting ISO..."
try {
    $diskImage = Mount-DiskImage -ImagePath $isoPath -PassThru -ErrorAction Stop
    Start-Sleep -Seconds 5
    $vol = $diskImage | Get-Volume
    $driveLetter = "$($vol.DriveLetter):"
} catch {
    Write-Error "Mount failed: $_"
    Show-Progress -Percent 0 -Stage "MountFailed"
    exit 1
}
Show-Progress -Percent 50 -Stage "DownloadedAndMounted"

### ————— LAUNCH SETUP —————
Show-Progress -Percent 75 -Stage "SetupStart"
Write-Output "Launching Windows 11 setup (quiet, no reboot)..."
Start-Process `
    -FilePath "$driveLetter\setup.exe" `
    -ArgumentList "/quiet","/noreboot","/auto Upgrade"

Write-Output "Setup launched; the machine will reboot and complete the upgrade."
# script ends here; Setup handles reboot & ISO cleanup

Stop-Transcript
