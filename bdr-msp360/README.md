# MSP360 Backup Scripts

## About MSP360

[MSP360](https://www.msp360.com/) (formerly CloudBerry) is a comprehensive cloud backup solution designed for businesses and managed service providers (MSPs). It provides:

- **Multi-cloud support**: Amazon S3, Azure, Google Cloud, Backblaze B2, and 20+ other cloud storage providers
- **Image-based backups**: Full system/disk image backups for complete disaster recovery
- **File-level backups**: Selective file and folder backup with versioning
- **Cross-platform support**: Windows, Mac, Linux backup agents
- **Centralized management**: Web-based console for managing multiple endpoints
- **Advanced features**: Encryption, compression, scheduling, retention policies, and more

MSP360 is particularly popular among MSPs for its centralized management capabilities, allowing administrators to monitor and manage backups across multiple client endpoints from a single dashboard.

## Available Scripts

This directory contains PowerShell scripts for automating MSP360 backup agent deployment and configuration:

### 1. msp360-staging-install-and-configure.ps1

**Primary MSP360 deployment script** - A comprehensive automation solution that handles the complete lifecycle of MSP360 agent installation and configuration.

**Key Features:**
- ✅ Intelligent installation detection (skips if already working)
- ✅ Automatic service health checks and recovery
- ✅ Support for both cloud storage and network share storage
- ✅ Configurable for interactive and RMM automated deployment
- ✅ Image-based backup plan creation with advanced scheduling
- ✅ Integer/boolean parameters compatible with RMM systems
- ✅ Comprehensive logging and error handling

**Storage Options:**
- **Cloud Storage**: Default MSP360 cloud storage with Forever Forward Incremental
- **Network Share Storage**: Local network share storage with monthly full backups

**📖 Detailed Documentation**: [README-MSP360-STAGING-INSTALL-AND-CONFIGURE.PS1.MD](./README-MSP360-STAGING-INSTALL-AND-CONFIGURE.PS1.MD)

### 2. run-msp360-staging-install.bat

**Quick launcher batch file** - A convenient wrapper that simplifies running the PowerShell script.

**Features:**
- Automatically sets execution policy bypass
- Provides user-friendly prompts
- Eliminates need to type PowerShell commands manually

**Usage:**
```batch
# Simply double-click or run from command prompt
run-msp360-staging-install.bat
```

## Quick Start

### For Interactive Use (Manual Setup)

1. **Easy Method**: Double-click `run-msp360-staging-install.bat`
2. **PowerShell Method**: 
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\msp360-staging-install-and-configure.ps1
   ```

### For RMM/Automated Deployment

Configure these variables in your RMM system:
```powershell
$RMM = 1
$MSPAccountEmail = "your-msp360-account@domain.com"
$MSPAccountPassword = "YourSecurePassword"
$UseLocalStorage = 0  # 0 = Cloud Storage, 1 = Network Share Storage

# For Network Share Storage (when UseLocalStorage = 1):
$LocalStoragePath = "\\server\share\MSP360LocalBackups"
$NetworkShareUsername = "domain\username"  # Optional
$NetworkSharePassword = "password"         # Optional
```

## Storage Configuration Options

### Cloud Storage (Default)
- **Provider**: MSP360 cloud storage or configured cloud provider
- **Backup Plan**: "Staging Job"
- **Schedule**: Daily at 12:00 AM
- **Features**: Forever Forward Incremental, compression, encryption
- **Best For**: Standard deployments, automatic cloud management

### Network Share Storage
- **Provider**: Local network share accessible to endpoint
- **Backup Plan**: "Staging Job Local"  
- **Schedule**: Daily at 10:00 PM with monthly full backups
- **Features**: Standard incremental with monthly fulls, compression, encryption
- **Best For**: Environments with local storage requirements or limited internet

## System Requirements

- **Operating System**: Windows with PowerShell 5.1+ or PowerShell Core 6+
- **Permissions**: Administrator privileges required
- **Network**: Internet connection (for cloud storage) or network share access (for local storage)
- **Storage**: Valid MSP360 account or accessible network share
- **Architecture**: Works with both x86 and x64 Windows systems

## File Structure

```
bdr-msp360/
├── README.md                                    # This file - overview and script listing
├── msp360-staging-install-and-configure.ps1    # Main automation script
├── README-MSP360-STAGING-INSTALL-AND-CONFIGURE.PS1.MD  # Detailed script documentation
└── run-msp360-staging-install.bat              # Quick launcher batch file
```

## Logging and Troubleshooting

All scripts provide comprehensive logging:
- **Interactive Mode**: `C:\Windows\logs\MSP360-Staging-Install-Configure.log`
- **RMM Mode**: `{RMMScriptPath}\logs\MSP360-Staging-Install-Configure.log`

For specific troubleshooting steps, error codes, and advanced configuration options, see the detailed documentation for each script.

## Support and Documentation

- **Script-Specific Help**: See individual README files linked above
- **MSP360 Official Documentation**: [help.msp360.com](https://help.msp360.com/)
- **MSP360 Community**: [community.msp360.com](https://community.msp360.com/)

## Contributing

When adding new MSP360-related scripts to this directory:
1. Create the script with clear comments and error handling
2. Add a corresponding README-{SCRIPTNAME}.MD with detailed documentation
3. Update this main README.md to include the new script in the available scripts section
4. Test both interactive and automated execution modes where applicable 