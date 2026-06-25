<#
.SYNOPSIS
    Install Dell Server Management Tools
.DESCRIPTION
    Detects Dell server hardware and installs missing management tools:
    - OpenManage Server Administrator (OMSA)
    - iDRAC Service Module (iSM)
    - Dell System Update (DSU)

    Designed for Windows Server environments and RMM deployment.
.NOTES
    Author: DTC Inc
    Version: 1.0
    Date: 2024-12-22
#>

#Requires -RunAsAdministrator
#Requires -Version 5.1

## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM
## $RMM = 1                          # Set to 1 when running from RMM
## $Description = "Ticket #12345"   # Optional description/ticket number

$scriptLogName = "Install-DellServerTools.log"

# Getting input from user if not running from RMM else set variables from RMM
if ($RMM -ne 1) {
    $validInput = 0
    # Checking for valid input
    while ($validInput -ne 1) {
        $Description = Read-Host "Please enter the ticket # and/or your initials (for logging)"
        if ($Description) {
            $validInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $logPath = "$ENV:WINDIR\logs\$scriptLogName"
} else {
    # Store the logs in the RMMScriptPath
    if ($null -ne $RMMScriptPath -and $RMMScriptPath -ne "") {
        $logPath = "$RMMScriptPath\logs\$scriptLogName"
    } else {
        $logPath = "$ENV:WINDIR\logs\$scriptLogName"
    }

    if ($null -eq $Description) {
        $Description = "RMM-initiated Dell tools installation"
    }
}

# Ensure log directory exists
$logDir = Split-Path -Path $logPath -Parent
if (!(Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Start the script logic here
Start-Transcript -Path $logPath

try {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Dell Server Management Tools Installer" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Description: $Description"
    Write-Host "Log path: $logPath"
    Write-Host "RMM Mode: $(if ($RMM -eq 1) { 'Yes' } else { 'No' })"
    Write-Host ""

    # Detect hardware manufacturer
    Write-Host "Detecting hardware manufacturer..." -ForegroundColor Yellow
    try {
        $manufacturer = Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 30 |
                       Select-Object -ExpandProperty Manufacturer
        Write-Host "  Manufacturer: $manufacturer" -ForegroundColor Gray
    } catch {
        Write-Host "  Failed via CIM, trying WMI..." -ForegroundColor Yellow
        try {
            $manufacturer = (Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop).Manufacturer
            Write-Host "  Manufacturer: $manufacturer" -ForegroundColor Gray
        } catch {
            Write-Host "ERROR: Cannot detect hardware manufacturer" -ForegroundColor Red
            throw "Hardware detection failed: $_"
        }
    }

    # Check if Dell hardware
    if ($manufacturer -notlike "Dell*") {
        Write-Host ""
        Write-Host "This is not Dell hardware - exiting" -ForegroundColor Yellow
        Write-Host "Detected manufacturer: $manufacturer" -ForegroundColor Yellow
        exit 0
    }

    # Detect if this is a server
    Write-Host "Checking system type..." -ForegroundColor Yellow
    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 30
        $pcSystemType = $computerSystem.PCSystemType
        $model = $computerSystem.Model

        Write-Host "  Model: $model" -ForegroundColor Gray
        Write-Host "  System Type: $pcSystemType" -ForegroundColor Gray

        # PCSystemType: 2 = Mobile, 3 = Workstation, 4 = Enterprise Server, 5 = SOHO Server, 6 = Appliance PC, 7 = Performance Server
        $isServer = $pcSystemType -in @(4, 5, 7) -or $model -match "PowerEdge|VRTX"

        if (!$isServer) {
            Write-Host ""
            Write-Host "This does not appear to be a server - exiting" -ForegroundColor Yellow
            Write-Host "Use this script only on Dell PowerEdge servers" -ForegroundColor Yellow
            exit 0
        }

        Write-Host "  Dell server detected" -ForegroundColor Green
    } catch {
        Write-Host "  Warning: Could not determine system type, proceeding anyway..." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Checking Dell management tools installation status..." -ForegroundColor Cyan
    Write-Host ""

    # Ensure BITS service is running for reliable downloads
    Start-Service -Name BITS -ErrorAction SilentlyContinue

    # Define Dell tools to install
    $dellTools = @(
        @{
            Name = "OpenManage Server Administrator"
            CheckPath = "C:\Program Files\Dell\SysMgt\oma\bin"
            Urls = @(
                "https://public-dtc.s3.us-west-002.backblazeb2.com/repo/vendors/dell/OM-SrvAdmin-Dell-Web-WINX64-11.0.1.0-5494_A00.exe"
            )
            File = "$env:WINDIR\temp\OMSA_Setup.exe"
            IsExtractor = $true
            ExtractPath = "C:\OpenManage"
            ActualSetup = "C:\OpenManage\windows\setup.exe"
            Args = "/qn"
            ShowWindow = $false
        },
        @{
            Name = "iDRAC Service Module (iSM)"
            CheckPath = "C:\Program Files\Dell\SysMgt\iDRACTools"
            Urls = @(
                "https://public-dtc.s3.us-west-002.backblazeb2.com/repo/vendors/dell/OM-iSM-Dell-Web-X64-5.4.2.0-4048.exe"
            )
            File = "$env:WINDIR\temp\iSM_Setup.exe"
            IsExtractor = $true
            ExtractPath = "C:\OpenManage\iSM"
            ActualSetup = "C:\OpenManage\iSM\windows\idracsvcmod.msi"
            Args = "/qn"
            ShowWindow = $false
        },
        @{
            Name = "Dell System Update"
            CheckPath = "C:\Program Files\Dell\SysMgt\DSU"
            Urls = @(
                "https://public-dtc.s3.us-west-002.backblazeb2.com/repo/vendors/dell/Systems-Management_Application_W7K0J_WN64_2.1.2.0_A01.EXE"
            )
            File = "$env:WINDIR\temp\DSU_Setup.exe"
            IsExtractor = $false
            Args = "/s"
            ShowWindow = $false
        }
    )

    $toolsToInstall = @()

    # Check which tools are missing
    foreach ($tool in $dellTools) {
        if (Test-Path $tool.CheckPath) {
            Write-Host "[INSTALLED] $($tool.Name)" -ForegroundColor Green
        } else {
            Write-Host "[MISSING]    $($tool.Name)" -ForegroundColor Yellow
            $toolsToInstall += $tool
        }
    }

    if ($toolsToInstall.Count -eq 0) {
        Write-Host ""
        Write-Host "All Dell management tools are already installed" -ForegroundColor Green
        exit 0
    }

    Write-Host ""
    Write-Host "Installing $($toolsToInstall.Count) missing tool(s)..." -ForegroundColor Cyan
    Write-Host ""

    # Install missing tools
    foreach ($tool in $toolsToInstall) {
        Write-Host "========================================" -ForegroundColor Gray
        Write-Host "Installing: $($tool.Name)" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Gray

        $downloadSuccess = $false

        # Try each URL in order until one succeeds
        foreach ($url in $tool.Urls) {
            try {
                Write-Host "  Downloading from: $url" -ForegroundColor Gray

                # Try BITS transfer first for better reliability
                try {
                    $bitsJob = Start-BitsTransfer -Source $url -Destination $tool.File `
                        -DisplayName $tool.Name -Priority Normal -Asynchronous -ErrorAction Stop

                    # Monitor BITS job progress
                    while (($bitsJob.JobState -eq "Transferring") -or ($bitsJob.JobState -eq "Connecting")) {
                        $percentComplete = if ($bitsJob.BytesTotal -gt 0) {
                            [math]::Round(($bitsJob.BytesTransferred / $bitsJob.BytesTotal) * 100, 2)
                        } else { 0 }
                        Write-Host "    Progress: $percentComplete%" -ForegroundColor Gray
                        Start-Sleep -Seconds 5
                        $bitsJob = Get-BitsTransfer -JobId $bitsJob.JobId
                    }

                    if ($bitsJob.JobState -eq "Transferred") {
                        Complete-BitsTransfer -BitsJob $bitsJob
                        Write-Host "  Download successful (BITS)" -ForegroundColor Green
                        $downloadSuccess = $true
                        break
                    } else {
                        Remove-BitsTransfer -BitsJob $bitsJob -ErrorAction SilentlyContinue
                        throw "BITS transfer failed: $($bitsJob.JobState)"
                    }
                } catch {
                    Write-Host "    BITS failed: $_" -ForegroundColor Yellow
                    Write-Host "    Trying direct download..." -ForegroundColor Gray

                    # Fallback to Invoke-WebRequest
                    $progressPreference = 'SilentlyContinue'
                    Invoke-WebRequest -Uri $url -OutFile $tool.File -UseBasicParsing -ErrorAction Stop
                    $progressPreference = 'Continue'

                    Write-Host "  Download successful (Direct)" -ForegroundColor Green
                    $downloadSuccess = $true
                    break
                }
            } catch {
                Write-Host "    Download failed: $_" -ForegroundColor Yellow
                continue
            }
        }

        if (!$downloadSuccess) {
            Write-Host "  ERROR: Failed to download from all sources" -ForegroundColor Red
            continue
        }

        # Install the tool
        try {
            if ($tool.IsExtractor) {
                Write-Host "  Extracting..." -ForegroundColor Gray

                # Run extractor
                $extractProcess = Start-Process -FilePath $tool.File -ArgumentList "/s" `
                    -PassThru -NoNewWindow -ErrorAction Stop

                # Wait for extraction
                $extractStartTime = Get-Date
                while (!$extractProcess.HasExited) {
                    $elapsed = [math]::Round(((Get-Date) - $extractStartTime).TotalMinutes, 1)
                    if ($elapsed -gt 0 -and ($elapsed % 1) -eq 0) {
                        Write-Host "    Still extracting... ($elapsed minutes)" -ForegroundColor Gray
                    }
                    Start-Sleep -Seconds 10
                }

                Write-Host "  Extraction complete" -ForegroundColor Green

                # Verify extracted setup exists
                if (!(Test-Path $tool.ActualSetup)) {
                    throw "Extracted setup not found at: $($tool.ActualSetup)"
                }

                Write-Host "  Installing from extracted files..." -ForegroundColor Gray

                # Run actual setup
                if ($tool.ShowWindow) {
                    $process = Start-Process -FilePath $tool.ActualSetup -ArgumentList $tool.Args -PassThru
                } else {
                    $process = Start-Process -FilePath $tool.ActualSetup -ArgumentList $tool.Args `
                        -PassThru -NoNewWindow
                }
            } else {
                # Direct installer
                Write-Host "  Installing..." -ForegroundColor Gray

                if ($tool.ShowWindow) {
                    $process = Start-Process -FilePath $tool.File -ArgumentList $tool.Args -PassThru
                } else {
                    $process = Start-Process -FilePath $tool.File -ArgumentList $tool.Args `
                        -PassThru -NoNewWindow
                }
            }

            # Wait for installation
            $startTime = Get-Date
            while (!$process.HasExited) {
                $elapsed = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
                if ($elapsed -gt 0 -and ($elapsed % 1) -eq 0) {
                    Write-Host "    Still installing... ($elapsed minutes)" -ForegroundColor Gray
                }
                Start-Sleep -Seconds 10
            }

            # Check exit code
            $totalTime = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)

            if ($process.ExitCode -eq 0) {
                Write-Host "  SUCCESS: $($tool.Name) installed ($totalTime minutes)" -ForegroundColor Green
            } elseif ($process.ExitCode -in @(3010, 3011)) {
                Write-Host "  SUCCESS: $($tool.Name) installed - reboot recommended (exit code: $($process.ExitCode))" -ForegroundColor Yellow
            } else {
                Write-Host "  WARNING: Exit code $($process.ExitCode)" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  ERROR: Installation failed: $_" -ForegroundColor Red
        }

        Write-Host ""
    }

    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Dell Tools Installation Complete" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "NOTE: A reboot may be required for all services to start properly" -ForegroundColor Yellow
    Write-Host ""

} catch {
    Write-Host ""
    Write-Host "ERROR: Script failed!" -ForegroundColor Red
    Write-Host "Error details: $_" -ForegroundColor Red
    exit 1
} finally {
    Stop-Transcript
}
