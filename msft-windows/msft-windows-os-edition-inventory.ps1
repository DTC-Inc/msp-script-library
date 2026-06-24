## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU'RE RUNNING FROM A RMM
## NinjaRMM passes script preset variables as environment variables, so each is read via $env: in this script.
## $env:RMM                      - Set to "1" by NinjaRMM to indicate RMM (non-interactive) mode
## $env:Description              - Ticket # or initials for audit trail
## $env:RMMScriptPath            - Optional log directory base provided by the RMM
##
## $env:CustomFieldServerEdition - Text field name for the server edition callout (default: "serverEdition")
##
## NOTE: Ninja-Property-Set only works in SYSTEM context. Run this script as SYSTEM.

# Server Edition inventory for NinjaRMM.
#
# Writes one custom field:
#   serverEdition - Server edition callout, one of:
#                     "Standard", "Datacenter", "Standard (Evaluation)",
#                     "Datacenter (Evaluation)", "<EditionID> (Evaluation)",
#                     "<EditionID>" for other server SKUs, or
#                     "N/A - Workstation OS" for non-server systems.
#
# Edition is resolved from the registry EditionID (cleanest source for
# Standard/Datacenter and the *Eval evaluation SKUs) with the WMI Caption as a
# fallback. ProductType distinguishes server (2 = DC, 3 = member server) from
# workstation (1).

$ScriptLogName = "msft-windows-os-edition-inventory.log"

# --- Default optional RMM environment variables --------------------------

if ([string]::IsNullOrEmpty($env:CustomFieldServerEdition)) {
    $env:CustomFieldServerEdition = "serverEdition"
}

# --- Input handling: RMM vs interactive ----------------------------------

if ($env:RMM -ne "1") {
    $ValidInput = 0
    while ($ValidInput -ne 1) {
        $env:Description = Read-Host "Please enter the ticket # and/or your initials for audit trail"
        if ($env:Description) {
            $ValidInput = 1
        } else {
            Write-Host "Invalid input. Please try again."
        }
    }
    $LogPath = "$env:WINDIR\logs\$ScriptLogName"
} else {
    if (-not [string]::IsNullOrEmpty($env:RMMScriptPath)) {
        $LogPath = "$env:RMMScriptPath\logs\$ScriptLogName"
    } else {
        $LogPath = "$env:WINDIR\logs\$ScriptLogName"
    }

    if ([string]::IsNullOrEmpty($env:Description)) {
        Write-Host "Description is null. This was most likely run automatically from the RMM and no information was passed."
        $env:Description = "No Description"
    }
}

# Ensure log directory exists before starting the transcript
$logDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $logDir)) {
    Write-Host "Creating log directory: $logDir"
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# --- Script logic --------------------------------------------------------

Start-Transcript -Path $LogPath

Write-Host "Description: $env:Description"
Write-Host "Log path: $LogPath"
Write-Host "RMM: $env:RMM"

# --- Gather OS facts -----------------------------------------------------

$os = Get-CimInstance -ClassName Win32_OperatingSystem
$caption = ($os.Caption).Trim()

# ProductType: 1 = Workstation, 2 = Domain Controller, 3 = Server
$isServer = $os.ProductType -ne 1

# EditionID is the cleanest edition source: ServerStandard, ServerDatacenter,
# ServerStandardEval, ServerDatacenterEval, ServerStandardCore, etc.
$cvKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
$editionId = (Get-ItemProperty -Path $cvKey -Name EditionID -ErrorAction SilentlyContinue).EditionID

Write-Host "Caption:     $caption"
Write-Host "EditionID:   $editionId"
Write-Host "ProductType: $($os.ProductType) (IsServer: $isServer)"

# --- Determine server edition callout -----------------------------------
# Check EditionID first, fall back to Caption for both family and evaluation.

$isEval       = ($editionId -match 'Eval') -or ($caption -match 'Evaluation')
$isDatacenter = ($editionId -match 'Datacenter') -or ($caption -match 'Datacenter')
$isStandard   = ($editionId -match 'Standard') -or ($caption -match 'Standard')

if (-not $isServer) {
    $serverEdition = "N/A - Workstation OS"
} else {
    if ($isDatacenter) {
        $serverEdition = "Datacenter"
    } elseif ($isStandard) {
        $serverEdition = "Standard"
    } elseif (-not [string]::IsNullOrEmpty($editionId)) {
        # Other server SKU (Essentials, Web, Storage, etc.) - report it verbatim.
        $serverEdition = $editionId
    } else {
        $serverEdition = "Unknown server edition"
    }

    if ($isEval) {
        $serverEdition += " (Evaluation)"
        Write-Host "WARNING: This server is running an EVALUATION edition of Windows Server. Evaluation builds expire and will begin shutting down automatically. Confirm licensing/activation status."
    }
}

Write-Host "----------------------------------------"
Write-Host "Server Edition field value: $serverEdition"
Write-Host "----------------------------------------"

# --- Write to NinjaRMM custom field (SYSTEM/RMM context only) ------------

if ($env:RMM -eq "1") {
    try {
        Ninja-Property-Set -Name $env:CustomFieldServerEdition -Value $serverEdition
        Write-Host "Wrote server edition to '$env:CustomFieldServerEdition'"
    } catch {
        Write-Host "ERROR: Failed to write '$env:CustomFieldServerEdition' - $_"
    }
} else {
    Write-Host "Interactive mode - skipping Ninja-Property-Set (cmdlet only works in SYSTEM/RMM context)."
}

Stop-Transcript
