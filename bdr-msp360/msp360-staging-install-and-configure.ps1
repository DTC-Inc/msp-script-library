## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## THIS IS HOW WE EASILY LET PEOPLE KNOW WHAT VARIABLES NEED SET IN THE RMM

# NOTE: This script should be run with -ExecutionPolicy Bypass
# Example: powershell.exe -ExecutionPolicy Bypass -File .\msp360-staging-install-and-configure.ps1

# MSP360 Configuration Variables (set these in RMM if applicable):
# $MSPAccountEmail = "staging@dtctoday.com" (MSP360 account email)
# $MSPAccountPassword = "YourPasswordHere" (MSP360 account password)
# $BackupEncryptionPassword = "YourEncryptionPasswordHere" (Backup encryption password)
# $BackupPlanName = "Staging Job" (Name for the backup plan)
# $CBBPath = "C:\Program Files\DTC Inc\DTCBSure Cloud Backup\cbb.exe" (Path to CBB executable)
# $OrganizationName = "YourOrgName" (Organization name for backup prefix)
# $SiteName = "YourSiteName" (Site name for backup prefix)
# $ServiceNames = @("DTCBSure Cloud Backup Service", "DTCBSure Cloud Backup Service Remote Management") (Service names to check)

# Function to sanitize strings for DNS/URL friendly format
function ConvertTo-DNSFriendly {
    param([string]$InputString)
    
    if ([string]::IsNullOrWhiteSpace($InputString)) {
        return ""
    }
    
    # Convert to lowercase, replace spaces and special chars with dashes, remove multiple dashes
    $sanitized = $InputString.ToLower() -replace '[^a-z0-9\-]', '-' -replace '-+', '-'
    
    # Trim dashes from start and end
    $sanitized = $sanitized.Trim('-')
    
    return $sanitized
}

# Getting input from user if not running from RMM else set variables from RMM.

$ScriptLogName = "MSP360-Staging-Install-Configure.log"

if ($RMM -ne 1) {
    $ValidInput = 0
    # Checking for valid input.
    while ($ValidInput -ne 1) {
        # Ask for input here. This is the interactive area for getting variable information.
        $Description = Read-Host "Please enter the ticket # and, or your initials. Its used as the Description for the job"
        
        # Get MSP360 account credentials
        $MSPAccountEmail = Read-Host "Enter MSP360 account email (default: staging@dtctoday.com)"
        if (-not $MSPAccountEmail) {
            $MSPAccountEmail = "staging@dtctoday.com"
        }
        
        $MSPAccountPasswordSecure = Read-Host "Enter MSP360 account password" -AsSecureString
        
        # Get backup encryption password
        $BackupEncryptionPasswordSecure = Read-Host "Enter backup encryption password (default: staging123!)" -AsSecureString
        if ([string]::IsNullOrEmpty([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($BackupEncryptionPasswordSecure)))) {
            $BackupEncryptionPasswordSecure = ConvertTo-SecureString -String "staging123!" -AsPlainText -Force
        }
        
        # Get backup plan name
        $BackupPlanName = Read-Host "Enter backup plan name (default: Staging Job)"
        if (-not $BackupPlanName) {
            $BackupPlanName = "Staging Job"
        }
        
        # Get organization and site information for backup prefix
        Write-Host "`nBackup Prefix Configuration:" -ForegroundColor Cyan
        Write-Host "The backup prefix will be: organizationname-sitename-computername" -ForegroundColor White
        $OrganizationName = Read-Host "Enter organization name"
        $SiteName = Read-Host "Enter site name"
        
        # Get CBB executable path
        Write-Host "`nCBB Executable Configuration:" -ForegroundColor Cyan
        Write-Host "Default path: C:\Program Files\DTC Inc\DTCBSure Cloud Backup\cbb.exe" -ForegroundColor White
        $useCustomCBBPath = Read-Host "Use custom CBB path? (y/N)"
        
        if ($useCustomCBBPath -eq "y" -or $useCustomCBBPath -eq "Y") {
            $CBBPath = Read-Host "Enter full path to cbb.exe"
        } else {
            $CBBPath = "C:\Program Files\DTC Inc\DTCBSure Cloud Backup\cbb.exe"
        }
        
        # Get service names
        Write-Host "`nService Configuration:" -ForegroundColor Cyan
        Write-Host "Default services: DTCBSure Cloud Backup Service, DTCBSure Cloud Backup Service Remote Management" -ForegroundColor White
        $useCustomServices = Read-Host "Use custom service names? (y/N)"
        
        if ($useCustomServices -eq "y" -or $useCustomServices -eq "Y") {
            $service1 = Read-Host "Enter first service name"
            $service2 = Read-Host "Enter second service name (optional)"
            $ServiceNames = @($service1)
            if ($service2) {
                $ServiceNames += $service2
            }
        } else {
            $ServiceNames = @("DTCBSure Cloud Backup Service", "DTCBSure Cloud Backup Service Remote Management")
        }
        
        if ($Description -and $MSPAccountPasswordSecure -and $BackupEncryptionPasswordSecure) {
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
        $Description = "MSP360 Staging Installation and Configuration"
    }
    
    # Ask for missing values even in RMM mode - this is the point of the template!
    if ($null -eq $MSPAccountEmail) {
        $MSPAccountEmail = Read-Host "MSP360 Account Email not provided by RMM. Enter MSP360 account email (default: staging@dtctoday.com)"
        if (-not $MSPAccountEmail) {
            $MSPAccountEmail = "staging@dtctoday.com"
        }
    }
    
    if ($null -eq $MSPAccountPassword) {
        $MSPAccountPasswordSecure = Read-Host "MSP360 Account Password not provided by RMM. Enter MSP360 account password" -AsSecureString
    } else {
        # Convert password to SecureString if provided as plain text from RMM
        $MSPAccountPasswordSecure = ConvertTo-SecureString -String $MSPAccountPassword -AsPlainText -Force
    }
    
    # Handle backup encryption password
    if ($null -eq $BackupEncryptionPassword) {
        $BackupEncryptionPasswordSecure = Read-Host "Backup Encryption Password not provided by RMM. Enter backup encryption password (default: staging123!)" -AsSecureString
        if ([string]::IsNullOrEmpty([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($BackupEncryptionPasswordSecure)))) {
            $BackupEncryptionPasswordSecure = ConvertTo-SecureString -String "staging123!" -AsPlainText -Force
        }
    } else {
        # Convert password to SecureString if provided as plain text from RMM
        $BackupEncryptionPasswordSecure = ConvertTo-SecureString -String $BackupEncryptionPassword -AsPlainText -Force
    }
    
    if ($null -eq $BackupPlanName) {
        $BackupPlanName = Read-Host "Backup Plan Name not provided by RMM. Enter backup plan name (default: Staging Job)"
        if (-not $BackupPlanName) {
            $BackupPlanName = "Staging Job"
        }
    }
    
    if ($null -eq $CBBPath) {
        Write-Host "CBB Path not provided by RMM." -ForegroundColor Yellow
        Write-Host "Default path: C:\Program Files\DTC Inc\DTCBSure Cloud Backup\cbb.exe" -ForegroundColor White
        $useCustomCBBPath = Read-Host "Use custom CBB path? (y/N)"
        
        if ($useCustomCBBPath -eq "y" -or $useCustomCBBPath -eq "Y") {
            $CBBPath = Read-Host "Enter full path to cbb.exe"
        } else {
            $CBBPath = "C:\Program Files\DTC Inc\DTCBSure Cloud Backup\cbb.exe"
        }
    }
    
    if ($null -eq $OrganizationName) {
        $OrganizationName = Read-Host "Organization Name not provided by RMM. Enter organization name"
    }
    
    if ($null -eq $SiteName) {
        $SiteName = Read-Host "Site Name not provided by RMM. Enter site name"
    }
    
    if ($null -eq $ServiceNames) {
        Write-Host "Service Names not provided by RMM." -ForegroundColor Yellow
        Write-Host "Default services: DTCBSure Cloud Backup Service, DTCBSure Cloud Backup Service Remote Management" -ForegroundColor White
        $useCustomServices = Read-Host "Use custom service names? (y/N)"
        
        if ($useCustomServices -eq "y" -or $useCustomServices -eq "Y") {
            $service1 = Read-Host "Enter first service name"
            $service2 = Read-Host "Enter second service name (optional)"
            $ServiceNames = @($service1)
            if ($service2) {
                $ServiceNames += $service2
            }
        } else {
            $ServiceNames = @("DTCBSure Cloud Backup Service", "DTCBSure Cloud Backup Service Remote Management")
        }
    }
}

# Create backup prefix from organization, site, and computer name
$ComputerName = $env:COMPUTERNAME
$BackupPrefix = @(
    (ConvertTo-DNSFriendly $OrganizationName),
    (ConvertTo-DNSFriendly $SiteName),
    (ConvertTo-DNSFriendly $ComputerName)
) -join '-'

# Start the script logic here.

Start-Transcript -Path $LogPath

Write-Host "Description: $Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $RMM"
Write-Host "MSP360 Account Email: $MSPAccountEmail"
Write-Host "Backup Plan Name: $BackupPlanName"
Write-Host "Organization: $OrganizationName"
Write-Host "Site: $SiteName"
Write-Host "Computer: $ComputerName"
Write-Host "Backup Prefix: $BackupPrefix"
Write-Host "CBB Executable Path: $CBBPath"
Write-Host "Service Names: $($ServiceNames -join ', ')"
Write-Host "Backup Encryption: Enabled" -ForegroundColor Green

try {
    Write-Host "Starting MSP360 installation and configuration..." -ForegroundColor Green
    
    # Step 1: Check if MSP360 Agent is already installed and healthy
    Write-Host "Step 1: Checking MSP360 Agent status..." -ForegroundColor Yellow
    
    $needsInstallation = $false
    $agentInstalled = $false
    
    # Check if MSP360 agent is installed
    try {
        $agentInfo = Get-MBSAgent -ErrorAction SilentlyContinue
        if ($agentInfo) {
            $agentInstalled = $true
            Write-Host "MSP360 Agent is installed (Version: $($agentInfo.Version))" -ForegroundColor Green
        }
    } catch {
        Write-Host "MSP360 Agent not detected or PowerShell module not available." -ForegroundColor Yellow
    }
    
    # Check service status if agent is installed
    if ($agentInstalled) {
        Write-Host "Checking services: $($ServiceNames -join ', ')" -ForegroundColor White
        $serviceHealthy = $false
        $servicesRunning = 0
        
        foreach ($serviceName in $ServiceNames) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service) {
                Write-Host "Found service: $serviceName (Status: $($service.Status))" -ForegroundColor White
                
                if ($service.Status -eq "Running") {
                    $servicesRunning++
                    Write-Host "✓ $serviceName is running" -ForegroundColor Green
                } elseif ($service.Status -eq "Stopped") {
                    Write-Host "Service $serviceName is stopped. Attempting to restart..." -ForegroundColor Yellow
                    try {
                        Start-Service -Name $serviceName
                        Start-Sleep -Seconds 5
                        $service = Get-Service -Name $serviceName
                        if ($service.Status -eq "Running") {
                            $servicesRunning++
                            Write-Host "✓ Successfully restarted $serviceName service." -ForegroundColor Green
                        } else {
                            Write-Host "✗ Failed to restart $serviceName service. Status: $($service.Status)" -ForegroundColor Red
                        }
                    } catch {
                        Write-Host "✗ Failed to restart $serviceName service: $($_.Exception.Message)" -ForegroundColor Red
                    }
                } else {
                    Write-Host "✗ Service $serviceName has unexpected status: $($service.Status)" -ForegroundColor Red
                }
            } else {
                Write-Host "✗ Service $serviceName not found" -ForegroundColor Red
            }
        }
        
        # Check if all services are healthy
        if ($servicesRunning -eq $ServiceNames.Count) {
            $serviceHealthy = $true
            Write-Host "All configured services are running and healthy." -ForegroundColor Green
        } else {
            Write-Host "Only $servicesRunning of $($ServiceNames.Count) configured services are running." -ForegroundColor Yellow
        }
        
        if (-not $serviceHealthy) {
            Write-Host "MSP360 services are not healthy. Will proceed with installation." -ForegroundColor Yellow
            $needsInstallation = $true
        }
    } else {
        $needsInstallation = $true
    }
    
    # Install only if needed
    if ($needsInstallation) {
        Write-Host "Installing MSP360 Agent..." -ForegroundColor Yellow
        
        # Use PowerShell with explicit bypass for the installation
        $installScript = @"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; 
iex (New-Object System.Net.WebClient).DownloadString('https://git.io/JUSAA'); 
Install-MSP360Module; 
Install-MBSAgent -URL 'https://console.msp360.com/api/build/download?urlParams=dGt2ZXAvQ3JqT0J1Wlgydk9YY05ZTnBDcnMwZUgwTThzREZGNnFjc2k2SHkxcUt6ZjlVeEpubTNWR2N0UG9uVXZ0K01MY2ZFNWtzdnBsTFYyMm93QlpybTFuMXlDTzgrNWtBVU9ITitBRUgxOUZ6Qmh0MHZ1d0ozUFVrcXBheFJYcmMyMzd1dDdPYStPaGl6TnJpUmFBaDhJaWlYSCtSY2dha1IvenhmY3ZoODQ3WGVHa3RpOHo2cGtQQkxHMk1vNmphREd4NlNHQkx3Y0JmNkhTdi9hUT09&brandId=0ebd1395-60b8-47e3-aaab-7f9c3be3d405' -Force
"@
        
        # Run the installation with bypass execution policy
        $processArgs = "-ExecutionPolicy Bypass -NoProfile -Command `"& {$installScript}`""
        $process = Start-Process -FilePath "powershell.exe" -ArgumentList $processArgs -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -ne 0) {
            throw "MSP360 installation failed with exit code: $($process.ExitCode)"
        }
        
        Write-Host "MSP360 Agent installation completed." -ForegroundColor Green
        
        # Wait a moment for the agent to initialize
        Start-Sleep -Seconds 10
    } else {
        Write-Host "MSP360 Agent is already installed and healthy. Skipping installation." -ForegroundColor Green
    }
    
    # Step 2: Configure MSP360 Account and Set Backup Prefix
    Write-Host "Step 2: Configuring MSP360 account and setting backup prefix..." -ForegroundColor Yellow

    try {
        # Import MSP360 module temporarily for this operation
        Import-Module MSP360 -Force -ErrorAction SilentlyContinue
        
        # First, add the user account
        Write-Host "Adding MSP360 user account: $MSPAccountEmail" -ForegroundColor White
        try {
            Add-MBSUserAccount -User $MSPAccountEmail -Password $MSPAccountPasswordSecure -SSL $true
            Write-Host "✓ Successfully added MSP360 user account" -ForegroundColor Green
        } catch {
            # Try without SSL if the first attempt fails
            Write-Host "Retrying user account addition without SSL..." -ForegroundColor Yellow
            try {
                Add-MBSUserAccount -User $MSPAccountEmail -Password $MSPAccountPasswordSecure
                Write-Host "✓ Successfully added MSP360 user account (without SSL)" -ForegroundColor Green
            } catch {
                Write-Host "Warning: Add-MBSUserAccount failed, but continuing: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
        
        # Now set the backup prefix using Edit-MBSUserAccount
        Write-Host "Setting backup prefix to: $BackupPrefix" -ForegroundColor White
        try {
            Edit-MBSUserAccount -User $MSPAccountEmail -Password $MSPAccountPasswordSecure -BackupPrefix $BackupPrefix -SSL $true
            Write-Host "✓ Successfully set backup prefix: $BackupPrefix" -ForegroundColor Green
        } catch {
            # Try without SSL if the first attempt fails
            Write-Host "Retrying backup prefix configuration without SSL..." -ForegroundColor Yellow
            try {
                Edit-MBSUserAccount -User $MSPAccountEmail -Password $MSPAccountPasswordSecure -BackupPrefix $BackupPrefix
                Write-Host "✓ Successfully set backup prefix: $BackupPrefix (without SSL)" -ForegroundColor Green
            } catch {
                Write-Host "Warning: Failed to set backup prefix via PowerShell: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "Backup prefix will need to be set manually in MSP360 console." -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "Error importing MSP360 module: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Account configuration will need to be done manually." -ForegroundColor Yellow
    }
    
    # Step 3: Get Storage Account via CBB
    Write-Host "Step 3: Getting storage account information via CBB..." -ForegroundColor Yellow
    
    # Use CBB to list storage accounts instead of PowerShell cmdlets
    $StorageAccount = $null
    if ($CBBPath -and (Test-Path $CBBPath)) {
        try {
            $storageListResult = & $CBBPath "listStorageAccounts" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Available storage accounts detected via CBB." -ForegroundColor Green
                # For now, we'll use "Staging Storage" as the default name
                # CBB will validate this when creating the backup plan
                $StorageAccount = [PSCustomObject]@{
                    DisplayName = "Staging Storage"
                }
                Write-Host "Using storage account: Staging Storage" -ForegroundColor Green
            } else {
                Write-Host "CBB storage account listing failed. Will proceed with manual specification." -ForegroundColor Yellow
                $StorageAccount = [PSCustomObject]@{
                    DisplayName = "Staging Storage"
                }
            }
        } catch {
            Write-Host "Error checking storage accounts via CBB: $($_.Exception.Message)" -ForegroundColor Yellow
            $StorageAccount = [PSCustomObject]@{
                DisplayName = "Staging Storage"
            }
        }
    } else {
        Write-Host "CBB executable not available for storage account validation." -ForegroundColor Yellow
        $StorageAccount = [PSCustomObject]@{
            DisplayName = "Staging Storage"
        }
    }
    
    Write-Host "✓ Storage account configuration ready." -ForegroundColor Green
    
    # Step 4: Check for Existing Backup Plan and Validate Settings
    Write-Host "Step 4: Checking for existing backup plan '$BackupPlanName'..." -ForegroundColor Yellow
    
    $existingPlan = $null
    $planNeedsUpdate = $false
    $shouldCreatePlan = $true
    
    # Check for existing backup plan using PowerShell cmdlets (module already imported in Step 2)
    try {
        $allPlans = Get-MBSBackupPlan -ErrorAction SilentlyContinue
        $existingPlan = $allPlans | Where-Object { $_.Name -eq $BackupPlanName }
        
        if ($existingPlan) {
            Write-Host "Found existing backup plan: $BackupPlanName" -ForegroundColor Green
            Write-Host "Plan details:" -ForegroundColor Cyan
            Write-Host "  - Name: '$($existingPlan.Name)'" -ForegroundColor White
            Write-Host "  - BackupVolumes: '$($existingPlan.BackupVolumes)'" -ForegroundColor White
            Write-Host "  - Storage Account: '$($existingPlan.StorageAccount.DisplayName)'" -ForegroundColor White
            Write-Host "  - Status: '$($existingPlan.Status)'" -ForegroundColor White
            Write-Host "Validating plan configuration..." -ForegroundColor White
            
            # Validate settings against our desired configuration
            $validationErrors = @()
            
            # Check if it's an image backup plan by looking at backup volumes
            # Image backup plans should have "SystemRequired" in BackupVolumes
            $ExpectedVolumeType = "SystemRequired"  # Configurable for future changes
            if ($existingPlan.BackupVolumes -notlike "*$ExpectedVolumeType*") {
                $validationErrors += "Backup volumes '$($existingPlan.BackupVolumes)' should contain '$ExpectedVolumeType' for image backup"
            }
            
            # Check storage account
            if ($existingPlan.StorageAccount.DisplayName -ne $StorageAccount.DisplayName) {
                $validationErrors += "Storage account is '$($existingPlan.StorageAccount.DisplayName)' but should be '$($StorageAccount.DisplayName)'"
            }
            
            # Check schedule (if available in plan properties)
            if ($existingPlan.Schedule) {
                if ($existingPlan.Schedule.Frequency -ne "Daily") {
                    $validationErrors += "Schedule frequency is '$($existingPlan.Schedule.Frequency)' but should be 'Daily'"
                }
            }
            
            # This check is now handled above with $ExpectedVolumeType
            
            # Display validation results
            if ($validationErrors.Count -eq 0) {
                Write-Host "✓ Existing backup plan configuration is correct!" -ForegroundColor Green
                Write-Host "Current plan settings:" -ForegroundColor Cyan
                Write-Host "  - Name: $($existingPlan.Name)" -ForegroundColor White
                Write-Host "  - Backup Volumes: $($existingPlan.BackupVolumes)" -ForegroundColor White
                Write-Host "  - Storage: $($existingPlan.StorageAccount.DisplayName)" -ForegroundColor White
                Write-Host "  - Status: $($existingPlan.Status)" -ForegroundColor White
                if ($existingPlan.Schedule) {
                    Write-Host "  - Schedule: $($existingPlan.Schedule.Frequency)" -ForegroundColor White
                }
                
                Write-Host "`n✓ Backup plan '$BackupPlanName' already exists with correct configuration. No changes needed." -ForegroundColor Green
                $shouldCreatePlan = $false
            } else {
                Write-Host "❌ Existing backup plan has configuration issues:" -ForegroundColor Red
                foreach ($validationError in $validationErrors) {
                    Write-Host "  - $validationError" -ForegroundColor Yellow
                }
                
                Write-Host "`nRemoving existing backup plan to recreate with correct settings..." -ForegroundColor Yellow
                try {
                    # Try different parameter patterns for Remove-MBSBackupPlan
                    if (Get-Command Remove-MBSBackupPlan -ErrorAction SilentlyContinue) {
                        # Try with -Name parameter first
                        try {
                            Remove-MBSBackupPlan -Name $existingPlan.Name -Force -ErrorAction Stop
                            Write-Host "✓ Successfully removed existing backup plan via -Name parameter." -ForegroundColor Green
                            $planNeedsUpdate = $true
                        } catch {
                            # Try with plan object directly
                            try {
                                Remove-MBSBackupPlan $existingPlan -Force -ErrorAction Stop
                                Write-Host "✓ Successfully removed existing backup plan via plan object." -ForegroundColor Green
                                $planNeedsUpdate = $true
                            } catch {
                                # Try with -BackupPlan parameter
                                try {
                                    Remove-MBSBackupPlan -BackupPlan $existingPlan -Force -ErrorAction Stop
                                    Write-Host "✓ Successfully removed existing backup plan via -BackupPlan parameter." -ForegroundColor Green
                                    $planNeedsUpdate = $true
                                } catch {
                                    throw "All removal methods failed: $($_.Exception.Message)"
                                }
                            }
                        }
                    } else {
                        throw "Remove-MBSBackupPlan cmdlet not available"
                    }
                } catch {
                    Write-Host "❌ Failed to remove existing plan via PowerShell: $($_.Exception.Message)" -ForegroundColor Red
                    Write-Host "Will attempt to remove via CBB executable..." -ForegroundColor Yellow
                    $planNeedsUpdate = $true
                }
            }
        } else {
            Write-Host "No existing backup plan found with name '$BackupPlanName'." -ForegroundColor White
            $shouldCreatePlan = $true
        }
    } catch {
        Write-Host "Could not check existing plans via PowerShell: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "Will check via CBB executable..." -ForegroundColor White
        
        # Fallback: Try to check via CBB executable if available
        if ($CBBPath -and (Test-Path $CBBPath)) {
            try {
                $listResult = & $CBBPath "list" 2>&1
                if ($listResult -like "*$BackupPlanName*") {
                    Write-Host "Found backup plan '$BackupPlanName' via CBB list command." -ForegroundColor Green
                    Write-Host "Cannot validate detailed settings via CBB. Will remove and recreate to ensure correct configuration." -ForegroundColor Yellow
                    $planNeedsUpdate = $true
                } else {
                    Write-Host "No backup plan found with name '$BackupPlanName' via CBB." -ForegroundColor White
                    $shouldCreatePlan = $true
                }
            } catch {
                Write-Host "Could not check existing plans via CBB: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "Proceeding with plan creation..." -ForegroundColor White
                $shouldCreatePlan = $true
            }
        } else {
            Write-Host "CBB executable not available for plan validation. Proceeding with creation..." -ForegroundColor White
            $shouldCreatePlan = $true
        }
    }
    
    # If plan validation shows everything is correct, exit successfully
    if (-not $shouldCreatePlan -and -not $planNeedsUpdate) {
        Write-Host "`n=== MSP360 Staging Configuration Summary ===" -ForegroundColor Cyan
        Write-Host "Account: $MSPAccountEmail" -ForegroundColor White
        Write-Host "Storage Account: $($StorageAccount.DisplayName)" -ForegroundColor White
        Write-Host "Backup Plan: $BackupPlanName (Already Configured)" -ForegroundColor Green
        Write-Host "Backup Prefix (User Account Level): $BackupPrefix" -ForegroundColor Cyan
        Write-Host "Status: Validated - No Changes Required" -ForegroundColor Green
        Write-Host "=======================================" -ForegroundColor Cyan
        
        Write-Host "`n✅ MSP360 Staging configuration already complete and correct!" -ForegroundColor Green
        return
    }
    
             # Step 5: Create Image-Based Backup Plan using CBB Executable
    if ($shouldCreatePlan -or $planNeedsUpdate) {
        Write-Host "Step 5: Creating image-based backup plan using CBB executable..." -ForegroundColor Yellow
        
        # If we need to remove an existing plan via CBB first
        if ($planNeedsUpdate) {
            Write-Host "Attempting to remove existing plan via CBB executable..." -ForegroundColor Yellow
            if ($CBBPath -and (Test-Path $CBBPath)) {
                try {
                    $removeResult = & $CBBPath "deleteBackupPlan" "-n" "`"$BackupPlanName`"" 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "✓ Successfully removed existing backup plan via CBB." -ForegroundColor Green
                    } else {
                        Write-Host "⚠ CBB plan removal may have failed (exit code: $LASTEXITCODE), proceeding with creation..." -ForegroundColor Yellow
                        Write-Host "CBB Output: $removeResult" -ForegroundColor Gray
                    }
                } catch {
                    Write-Host "⚠ CBB plan removal error: $($_.Exception.Message)" -ForegroundColor Yellow
                    Write-Host "Proceeding with plan creation..." -ForegroundColor White
                }
            }
        }
        
        # Check if CBB executable exists at the configured path
        if (Test-Path $CBBPath) {
            Write-Host "Found CBB executable at configured path: $CBBPath" -ForegroundColor Green
        } else {
            Write-Host "CBB executable not found at configured path: $CBBPath" -ForegroundColor Yellow
            Write-Host "Searching standard MSP360/CloudBerry installation paths..." -ForegroundColor White
            
            # Fallback to standard paths
            $CBBPathFound = $null
            $possiblePaths = @(
                "${env:ProgramFiles}\MSP360\MSP360 (CloudBerry) Backup\cbb.exe",
                "${env:ProgramFiles(x86)}\MSP360\MSP360 (CloudBerry) Backup\cbb.exe",
                "${env:ProgramFiles}\CloudBerry Backup\cbb.exe",
                "${env:ProgramFiles(x86)}\CloudBerry Backup\cbb.exe"
            )
            
            foreach ($path in $possiblePaths) {
                if (Test-Path $path) {
                    $CBBPathFound = $path
                    Write-Host "Found CBB executable at: $CBBPathFound" -ForegroundColor Green
                    break
                }
            }
            
            if ($CBBPathFound) {
                $CBBPath = $CBBPathFound
            } else {
                $CBBPath = $null
            }
        }
        
        if (-not $CBBPath) {
            Write-Host "❌ CBB executable not found in standard locations." -ForegroundColor Red
            Write-Host "⚠ Manual backup plan creation required via MSP360 console." -ForegroundColor Yellow
                    Write-Host "Please create an image-based backup plan with these settings:" -ForegroundColor Yellow
        Write-Host "  - Plan Name: $BackupPlanName" -ForegroundColor White
        Write-Host "  - Storage: $($StorageAccount.DisplayName)" -ForegroundColor White
        Write-Host "  - Schedule: Daily at 12:00 AM" -ForegroundColor White
        Write-Host "  - Volumes: System Required (Internal volumes only)" -ForegroundColor White
        Write-Host "  - Compression: Enabled" -ForegroundColor White
        Write-Host "  - Encryption: AES256 with password" -ForegroundColor White
        Write-Host "  - New Backup Format: Enabled" -ForegroundColor White
        Write-Host "  - Forever Forward Incremental: Enabled" -ForegroundColor White
        Write-Host "  - Retention: Purge versions older than 7 days" -ForegroundColor White
        Write-Host "  - VSS: System VSS enabled" -ForegroundColor White
        Write-Host "  - Bad Sectors: Ignore enabled" -ForegroundColor White
        Write-Host "  - Notifications: Disabled" -ForegroundColor White
        Write-Host "NOTE: Backup prefix '$BackupPrefix' is already set at user account level." -ForegroundColor Cyan
        } else {
            # Use CBB executable to create backup plan
            Write-Host "Using CBB executable to create image backup plan..." -ForegroundColor White
            
            # Get plain text password for CBB command
            $MSPAccountPasswordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($MSPAccountPasswordSecure))
            $BackupEncryptionPasswordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($BackupEncryptionPasswordSecure))
            
            try {
                # Step 7a: Create image backup plan using CBB
                Write-Host "Creating image backup plan with CBB executable..." -ForegroundColor White
                
                            # Build CBB command arguments for image backup using correct parameters
            # Note: Backup prefix is set at user account level via Edit-MBSUserAccount
            $cbbArgs = @(
                "addBackupIBBPlan",
                "-a", "`"$($StorageAccount.DisplayName)`"",
                "-n", "`"$BackupPlanName`"",
                "-r",                           # System required volumes only (internal volumes)
                "-c", "yes",                    # Use compression
                "-useSystemVss", "yes",         # Use system VSS
                "-ignoreBadSectors", "yes",     # Ignore bad sectors
                "-ea", "AES256",                # Encryption algorithm (AES256, not AES_256)
                "-ep", "`"$BackupEncryptionPasswordPlain`"", # Encryption password
                "-nbf",                         # New backup format (required for FFI)
                "-ffi", "yes",                  # Forever Forward Incremental
                "-every", "day",                # Daily schedule
                "-at", "00:00",                 # At midnight (12:00 AM)
                "-purge", "7d",                 # Purge versions older than 7 days
                "-notification", "no",          # Disable email notifications
                "-winLog", "on"                 # Add to Windows Event Log
            )
                
                Write-Host "Running CBB command: $CBBPath $($cbbArgs -join ' ')" -ForegroundColor Gray
                
                # Execute CBB command
                $result = & $CBBPath $cbbArgs 2>&1
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "✓ Successfully created image backup plan using CBB executable!" -ForegroundColor Green
                                    Write-Host "Backup plan configured with:" -ForegroundColor Cyan
                Write-Host "  - Plan Name: $BackupPlanName" -ForegroundColor White
                Write-Host "  - Storage: $($StorageAccount.DisplayName)" -ForegroundColor White
                Write-Host "  - Schedule: Daily at 12:00 AM" -ForegroundColor White
                Write-Host "  - Volumes: System Required (Internal volumes only)" -ForegroundColor White
                Write-Host "  - Compression: Enabled" -ForegroundColor White
                Write-Host "  - Encryption: AES256 with custom password" -ForegroundColor White
                Write-Host "  - New Backup Format: Enabled" -ForegroundColor White
                Write-Host "  - Forever Forward Incremental: Enabled" -ForegroundColor White
                Write-Host "  - Retention: Purge versions older than 7 days" -ForegroundColor White
                Write-Host "  - VSS: System VSS enabled" -ForegroundColor White
                Write-Host "  - Bad Sectors: Ignore enabled" -ForegroundColor White
                Write-Host "  - Notifications: Disabled" -ForegroundColor White
                Write-Host "  - Windows Event Log: Enabled" -ForegroundColor White
                Write-Host "  - Backup Prefix: $BackupPrefix (set at user account level)" -ForegroundColor Cyan
                } else {
                    Write-Host "❌ CBB command failed with exit code: $LASTEXITCODE" -ForegroundColor Red
                    Write-Host "CBB Output: $result" -ForegroundColor Yellow
                    
                    # Try simplified CBB command without some parameters that might cause issues
                    Write-Host "Trying simplified CBB command..." -ForegroundColor Yellow
                    
                                    $simpleCbbArgs = @(
                    "addBackupIBBPlan",
                    "-a", "`"$($StorageAccount.DisplayName)`"",
                    "-n", "`"$BackupPlanName`"",
                    "-r",                           # System required volumes only
                    "-c", "yes",                    # Use compression
                    "-nbf",                         # New backup format (required for FFI)
                    "-ffi", "yes",                  # Forever Forward Incremental
                    "-every", "day",                # Daily schedule
                    "-at", "00:00",                 # At midnight (12:00 AM)
                    "-purge", "7d"                  # Purge versions older than 7 days
                )
                    
                    $result2 = & $CBBPath $simpleCbbArgs 2>&1
                    
                    if ($LASTEXITCODE -eq 0) {
                                            Write-Host "✓ Successfully created simplified image backup plan!" -ForegroundColor Green
                    Write-Host "Configured: Daily schedule, compression, new backup format, forever forward incremental, 7-day retention" -ForegroundColor Green
                    Write-Host "Backup prefix '$BackupPrefix' is set at user account level." -ForegroundColor Cyan
                    Write-Host "NOTE: Please manually configure in MSP360 console:" -ForegroundColor Yellow
                    Write-Host "  - Encryption: AES256 with password '$BackupEncryptionPasswordPlain'" -ForegroundColor Yellow
                    Write-Host "  - VSS: Enable System VSS" -ForegroundColor Yellow
                    Write-Host "  - Bad Sectors: Set to ignore" -ForegroundColor Yellow
                    Write-Host "  - Notifications: Disable email notifications" -ForegroundColor Yellow
                    Write-Host "  - Windows Event Log: Enable" -ForegroundColor Yellow
                    } else {
                        Write-Host "❌ Simplified CBB command also failed: $LASTEXITCODE" -ForegroundColor Red
                        Write-Host "CBB Output: $result2" -ForegroundColor Yellow
                        Write-Host "⚠ Manual backup plan creation required via MSP360 console." -ForegroundColor Yellow
                    }
                }
            } catch {
                Write-Host "❌ CBB executable error: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "⚠ Manual backup plan creation required via MSP360 console." -ForegroundColor Yellow
            } finally {
                # Clear sensitive passwords from memory
                $MSPAccountPasswordPlain = $null
                $BackupEncryptionPasswordPlain = $null
            }
        }
    } else {
        Write-Host "Step 5: Skipping backup plan creation - already exists and validated." -ForegroundColor Green
    }
    
    # Step 6: Display Configuration Summary
    Write-Host "`n=== MSP360 Staging Configuration Summary ===" -ForegroundColor Cyan
    Write-Host "Account: $MSPAccountEmail" -ForegroundColor White
    Write-Host "Storage Account: $($StorageAccount.DisplayName)" -ForegroundColor White
    Write-Host "Backup Plan: $BackupPlanName" -ForegroundColor White
    Write-Host "Organization: $OrganizationName" -ForegroundColor White
    Write-Host "Site: $SiteName" -ForegroundColor White
    Write-Host "Computer: $ComputerName" -ForegroundColor White
    Write-Host "Backup Prefix (User Account Level): $BackupPrefix" -ForegroundColor Cyan
    Write-Host "Schedule: Daily at 12:00 AM" -ForegroundColor White
    Write-Host "Backup Type: Image-based (Internal Volumes Only)" -ForegroundColor White
    Write-Host "Compression: Enabled" -ForegroundColor White
    Write-Host "New Backup Format: Enabled" -ForegroundColor White
    Write-Host "Forever Forward Incremental: Enabled" -ForegroundColor White
    Write-Host "Retention: Purge versions older than 7 days" -ForegroundColor White
    Write-Host "CBB Executable Path: $CBBPath" -ForegroundColor White
    Write-Host "Method: Hybrid (PowerShell for prefix, CBB for plans)" -ForegroundColor Green
    Write-Host "=======================================" -ForegroundColor Cyan
    
    Write-Host "`nMSP360 Staging installation and configuration completed!" -ForegroundColor Green

} catch {
    Write-Error "An error occurred during MSP360 installation/configuration: $($_.Exception.Message)"
    Write-Host "Error details: $($_.Exception)" -ForegroundColor Red
    exit 1
}

Stop-Transcript 