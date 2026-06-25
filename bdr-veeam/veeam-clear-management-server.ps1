## Removes the old Veeam management server registration from an endpoint.
## Use when migrating an endpoint to a new Veeam B&R server and you get:
##   "host is managed by another backup server"
##
## Run on the ENDPOINT (not the Veeam server). Requires admin privileges.
##
## Each input can be supplied EITHER as a -Parameter OR as an $env: variable of the same name.
## $DESCRIPTION      / $env:DESCRIPTION      - Ticket # or initials for audit trail
## $RMM_SCRIPT_PATH  / $env:RMM_SCRIPT_PATH  - Optional log directory base provided by the RMM

param(
    # Each parameter defaults to its $env: counterpart so the script runs the same from the
    # command line (-DESCRIPTION ...) or from an RMM that supplies values as env variables.
    [string]$DESCRIPTION     = $env:DESCRIPTION,
    [string]$RMM_SCRIPT_PATH = $env:RMM_SCRIPT_PATH
)

$SCRIPT_LOG_NAME = "veeam-clear-management-server.log"

# --- Input handling: non-interactive (no Read-Host) ----------------------

# Mirror the resolved parameter values into $env: so the rest of the script can reference
# either $DESCRIPTION or $env:DESCRIPTION, whichever form the input arrived in.
if (-not [string]::IsNullOrEmpty($DESCRIPTION))     { $env:DESCRIPTION     = $DESCRIPTION }
if (-not [string]::IsNullOrEmpty($RMM_SCRIPT_PATH)) { $env:RMM_SCRIPT_PATH = $RMM_SCRIPT_PATH }

if (-not $env:DESCRIPTION) { $env:DESCRIPTION = "No Description" }

# Store logs under $env:RMM_SCRIPT_PATH if provided, otherwise the standard Windows logs directory.
if ($env:RMM_SCRIPT_PATH) {
    $LOG_DIR = "$env:RMM_SCRIPT_PATH\logs"
    if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null }
    $LOG_PATH = "$LOG_DIR\$SCRIPT_LOG_NAME"
} else {
    $LOG_PATH = "$env:WINDIR\logs\$SCRIPT_LOG_NAME"
}

Start-Transcript -Path $LOG_PATH

Write-Host "=== Veeam Clear Management Server ==="
Write-Host "Description: $env:DESCRIPTION"
Write-Host "Hostname:    $env:COMPUTERNAME"
Write-Host ""

# ============================================================
# 1. Remove Veeam certificates from Trusted Root
# ============================================================
Write-Host "Checking for Veeam certificates in Trusted Root store..."

$VEEAM_CERTS = Get-ChildItem Cert:\LocalMachine\Root | Where-Object {
    $_.Issuer -like "*Veeam*" -or $_.Subject -like "*Veeam*"
}

if ($VEEAM_CERTS) {
    foreach ($CERT in $VEEAM_CERTS) {
        Write-Host "  Removing: $($CERT.Subject)"
        Write-Host "    Issuer:     $($CERT.Issuer)"
        Write-Host "    Thumbprint: $($CERT.Thumbprint)"
        try {
            Remove-Item $CERT.PSPath -Force
            Write-Host "    [OK] Removed."
        } catch {
            Write-Warning "    Failed to remove: $_"
        }
    }
} else {
    Write-Host "  No Veeam certificates found."
}

Write-Host ""

# ============================================================
# 2. Clear management server registration from registry
# ============================================================
Write-Host "Clearing management server registry entries..."

$REG_PATHS = @(
    "HKLM:\SOFTWARE\Veeam\Veeam Agent for Microsoft Windows",
    "HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication",
    "HKLM:\SOFTWARE\Veeam\Veeam Agent"
)

$REG_KEYS = @(
    "ManagementServerAddress",
    "ManagementServerPort",
    "ManagementServerId",
    "ManagementServerCertificateThumbprint",
    "ManagementServerCertificateSubject",
    "BackupServerAddress",
    "BackupServerPort",
    "BackupServerId"
)

foreach ($PATH in $REG_PATHS) {
    if (-not (Test-Path $PATH)) { continue }

    Write-Host "  Registry: $PATH"
    $PROPS = Get-ItemProperty -Path $PATH -ErrorAction SilentlyContinue

    foreach ($KEY in $REG_KEYS) {
        if ($null -ne $PROPS.$KEY) {
            Write-Host "    $KEY = $($PROPS.$KEY)"
            try {
                Remove-ItemProperty -Path $PATH -Name $KEY -Force -ErrorAction Stop
                Write-Host "    [OK] Cleared."
            } catch {
                Write-Warning "    Failed to clear: $_"
            }
        }
    }
}

Write-Host ""

# ============================================================
# 3. Restart Veeam agent service
# ============================================================
Write-Host "Restarting Veeam agent service..."

$VEEAM_SERVICES = @(
    "VeeamEndpointBackupSvc",
    "VeeamAgentSvc"
)

foreach ($SVC_NAME in $VEEAM_SERVICES) {
    $SVC = Get-Service -Name $SVC_NAME -ErrorAction SilentlyContinue
    if ($SVC) {
        Write-Host "  Restarting: $SVC_NAME (currently $($SVC.Status))"
        try {
            Restart-Service -Name $SVC_NAME -Force -ErrorAction Stop
            Write-Host "  [OK] Restarted."
        } catch {
            Write-Warning "  Failed to restart: $_"
        }
    }
}

Write-Host ""
Write-Host "=== Complete ==="
Write-Host "This endpoint can now be added to a new Veeam management server."

Stop-Transcript
