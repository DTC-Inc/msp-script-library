## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $dellCommandConfigureURL - URL to Dell Command Configure installer
## $enableWakeOnLan - Set to 1 to enable Wake on LAN in BIOS (default: 1)
## $disableSleep - Set to 1 to disable sleep/standby modes (default: 1)
## $enableSecureBoot - Set to 1 to enable Secure Boot on UEFI systems (default: 0, only works on UEFI not Legacy BIOS)
## $additionalCctkCommands - Optional: comma-separated CCTK commands to run (e.g., "fastboot=thorough,secureboot=disabled")

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "dell-command-configure.log"

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

    # Set default values for interactive mode
    if ([string]::IsNullOrEmpty($enableWakeOnLan)) {
        $enableWakeOnLan = 1
    }
    if ([string]::IsNullOrEmpty($disableSleep)) {
        $disableSleep = 1
    }
    if ([string]::IsNullOrEmpty($enableSecureBoot)) {
        $enableSecureBoot = 0
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
        $Description = "No Description"
    }

    # Set default values if not provided by RMM
    if ([string]::IsNullOrEmpty($enableWakeOnLan)) {
        $enableWakeOnLan = 1
    }
    if ([string]::IsNullOrEmpty($disableSleep)) {
        $disableSleep = 1
    }
    if ([string]::IsNullOrEmpty($enableSecureBoot)) {
        $enableSecureBoot = 0
    }
}

# Start the script logic here. This is the part that actually gets done what you need done.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host "Enable Wake on LAN: $enableWakeOnLan"
Write-Host "Disable Sleep: $disableSleep"
Write-Host "Enable Secure Boot: $enableSecureBoot"

# Function to check if running as administrator
function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Function to detect Dell hardware
function Test-DellHardware {
    try {
        $manufacturer = (Get-WmiObject -Class Win32_ComputerSystem).Manufacturer
        Write-Host "Detected manufacturer: $manufacturer"

        if ($manufacturer -like "*Dell*") {
            return $true
        } else {
            return $false
        }
    } catch {
        Write-Host "ERROR: Unable to detect manufacturer. $($_.Exception.Message)"
        return $false
    }
}

# Function to check if Dell Command Configure is installed
function Test-DellCommandConfigure {
    # Check common installation paths
    $cctkPaths = @(
        "C:\Program Files\Dell\Command Configure\X86_64\cctk.exe",
        "C:\Program Files (x86)\Dell\Command Configure\X86_64\cctk.exe",
        "C:\Program Files\Dell\Command Configure\cctk.exe"
    )

    foreach ($path in $cctkPaths) {
        if (Test-Path -Path $path) {
            Write-Host "Dell Command Configure found at: $path"
            return $path
        }
    }

    return $null
}

# Function to download and install Dell Command Configure
function Install-DellCommandConfigure {
    param(
        [string]$DownloadURL
    )

    Write-Host "Starting Dell Command Configure installation..."

    # Use default download URL if not provided
    if ([string]::IsNullOrEmpty($DownloadURL)) {
        # Default to Dell Command Configure 5.2.0 hosted on Backblaze B2
        # Latest version can be downloaded from: https://www.dell.com/support/kbdoc/en-us/000178000/dell-command-configure
        Write-Host "No download URL provided, using default Dell Command Configure 5.2.0 installer..."
        $DownloadURL = "https://s3.us-west-002.backblazeb2.com/public-dtc/repo/apps/dell/Dell-Command-Configure-Application_MD8CJ_WIN64_5.2.0.9_A00.EXE"
    }

    $installerPath = "$env:TEMP\DellCommandConfigure.exe"

    try {
        # Download installer
        Write-Host "Downloading Dell Command Configure from: $DownloadURL"
        Invoke-WebRequest -Uri $DownloadURL -OutFile $installerPath -UseBasicParsing

        if (-not (Test-Path -Path $installerPath)) {
            Write-Host "ERROR: Failed to download installer."
            return $false
        }

        Write-Host "Download complete. Installing..."

        # Install silently
        $installProcess = Start-Process -FilePath $installerPath -ArgumentList "/s" -Wait -PassThru -NoNewWindow

        if ($installProcess.ExitCode -eq 0) {
            Write-Host "Dell Command Configure installed successfully."

            # Clean up installer
            Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue

            # Wait a moment for installation to complete
            Start-Sleep -Seconds 5

            return $true
        } else {
            Write-Host "ERROR: Installation failed with exit code: $($installProcess.ExitCode)"
            return $false
        }

    } catch {
        Write-Host "ERROR: Exception during installation: $($_.Exception.Message)"
        return $false
    }
}

# Function to run CCTK command
function Invoke-CctkCommand {
    param(
        [string]$CctkPath,
        [string]$Command
    )

    try {
        Write-Host "Running CCTK command: $Command"
        $result = & $CctkPath $Command 2>&1
        Write-Host "CCTK Output: $result"

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Command executed successfully."
            return $true
        } else {
            Write-Host "WARNING: Command returned exit code: $LASTEXITCODE"
            return $false
        }
    } catch {
        Write-Host "ERROR: Failed to execute CCTK command: $($_.Exception.Message)"
        return $false
    }
}

# Function to configure Wake on LAN
function Set-WakeOnLan {
    param(
        [string]$CctkPath,
        [int]$Enable
    )

    if ($Enable -eq 1) {
        Write-Host "Enabling Wake on LAN..."

        # Enable Wake on LAN in BIOS
        Invoke-CctkCommand -CctkPath $CctkPath -Command "--WakeOnLan=LanOnly"

        # Enable Deep Sleep Control to allow WOL during sleep
        Invoke-CctkCommand -CctkPath $CctkPath -Command "--DeepSleepCtrl=Disabled"

        # Enable LAN/WLAN switching
        Invoke-CctkCommand -CctkPath $CctkPath -Command "--WakeOnLanLanOnly=Enabled"

        Write-Host "Wake on LAN configuration applied."
    } else {
        Write-Host "Wake on LAN configuration skipped (disabled by variable)."
    }
}

# Function to disable sleep modes
function Set-SleepConfiguration {
    param(
        [string]$CctkPath,
        [int]$DisableSleep
    )

    if ($DisableSleep -eq 1) {
        Write-Host "Disabling sleep modes..."

        # Disable Block Sleep (S3 state)
        Invoke-CctkCommand -CctkPath $CctkPath -Command "--BlockSleep=Enabled"

        # Disable AC Power Recovery
        # Note: This sets the system to stay on after power loss
        Invoke-CctkCommand -CctkPath $CctkPath -Command "--AcPwrRcvry=On"

        Write-Host "Sleep configuration applied."
    } else {
        Write-Host "Sleep configuration skipped (not disabled by variable)."
    }
}

# Function to detect UEFI vs Legacy BIOS boot mode
function Test-UefiBootMode {
    try {
        # Check if firmware type is UEFI
        $firmwareType = $env:firmware_type
        if ($firmwareType -eq "UEFI") {
            return $true
        }

        # Alternative method: Check for EFI system partition
        $efiPartition = Get-Partition | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }
        if ($efiPartition) {
            Write-Host "Detected UEFI boot mode (EFI system partition found)"
            return $true
        }

        # Alternative method: Check registry
        $secureBootCapable = Get-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\SecureBoot\State" -Name "UEFISecureBootEnabled" -ErrorAction SilentlyContinue
        if ($secureBootCapable) {
            Write-Host "Detected UEFI boot mode (SecureBoot registry key found)"
            return $true
        }

        Write-Host "Detected Legacy BIOS boot mode"
        return $false

    } catch {
        Write-Host "WARNING: Could not determine boot mode. Assuming Legacy BIOS. Error: $($_.Exception.Message)"
        return $false
    }
}

# Function to enable Secure Boot (UEFI only)
function Set-SecureBoot {
    param(
        [string]$CctkPath,
        [int]$Enable
    )

    if ($Enable -eq 1) {
        # Check if system is booted in UEFI mode
        if (-not (Test-UefiBootMode)) {
            Write-Host "WARNING: Secure Boot can only be enabled on UEFI systems."
            Write-Host "This system is booted in Legacy BIOS mode. Skipping Secure Boot configuration."
            return
        }

        Write-Host "System is booted in UEFI mode. Proceeding with Secure Boot configuration..."

        # Enable Secure Boot
        Write-Host "Enabling Secure Boot..."
        Invoke-CctkCommand -CctkPath $CctkPath -Command "--SecureBoot=Enabled"

        # Set UEFI boot mode (ensure not in Legacy)
        Invoke-CctkCommand -CctkPath $CctkPath -Command "--BootMode=Uefi"

        Write-Host "Secure Boot configuration applied."
        Write-Host "NOTE: A system reboot is required for Secure Boot changes to take effect."

    } else {
        Write-Host "Secure Boot configuration skipped (disabled by variable)."
    }
}

# Function to apply additional custom CCTK commands
function Set-AdditionalCommands {
    param(
        [string]$CctkPath,
        [string]$CommandString
    )

    if (-not [string]::IsNullOrEmpty($CommandString)) {
        Write-Host "Applying additional CCTK commands..."

        # Split by comma and process each command
        $commands = $CommandString -split ','

        foreach ($cmd in $commands) {
            $cmd = $cmd.Trim()
            if (-not [string]::IsNullOrEmpty($cmd)) {
                Invoke-CctkCommand -CctkPath $CctkPath -Command "--$cmd"
            }
        }

        Write-Host "Additional commands applied."
    } else {
        Write-Host "No additional commands specified."
    }
}

# Main script execution

# Check if running as administrator
if (-not (Test-Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator."
    Write-Host "Please run PowerShell as Administrator and try again."
    Stop-Transcript
    exit 1
}

# Check if this is a Dell system
if (-not (Test-DellHardware)) {
    Write-Host "This system is not a Dell. Script will exit."
    Stop-Transcript
    exit 0
}

Write-Host "Dell system detected. Proceeding with configuration..."

# Check if Dell Command Configure is already installed
$cctkPath = Test-DellCommandConfigure

if ($null -eq $cctkPath) {
    Write-Host "Dell Command Configure is not installed."

    # Install Dell Command Configure
    $installSuccess = Install-DellCommandConfigure -DownloadURL $dellCommandConfigureURL

    if (-not $installSuccess) {
        Write-Host "ERROR: Failed to install Dell Command Configure."
        Stop-Transcript
        exit 1
    }

    # Check again after installation
    $cctkPath = Test-DellCommandConfigure

    if ($null -eq $cctkPath) {
        Write-Host "ERROR: Dell Command Configure installation verification failed."
        Stop-Transcript
        exit 1
    }
} else {
    Write-Host "Dell Command Configure is already installed. Skipping installation."
}

Write-Host "Using CCTK at: $cctkPath"
Write-Host ""
Write-Host "========================================"
Write-Host "Starting BIOS Configuration"
Write-Host "========================================"

# Apply Wake on LAN settings
Set-WakeOnLan -CctkPath $cctkPath -Enable $enableWakeOnLan

# Apply Sleep settings
Set-SleepConfiguration -CctkPath $cctkPath -DisableSleep $disableSleep

# Apply Secure Boot settings (UEFI only)
Set-SecureBoot -CctkPath $cctkPath -Enable $enableSecureBoot

# Apply any additional custom commands
if (-not [string]::IsNullOrEmpty($additionalCctkCommands)) {
    Set-AdditionalCommands -CctkPath $cctkPath -CommandString $additionalCctkCommands
}

Write-Host ""
Write-Host "========================================"
Write-Host "BIOS Configuration Complete"
Write-Host "========================================"
Write-Host ""
Write-Host "NOTE: Some BIOS changes may require a system reboot to take effect."
Write-Host "Script execution completed successfully."
Write-Host ""

# Pause for testing
Read-Host "Press Enter to exit"

Stop-Transcript
exit 0
