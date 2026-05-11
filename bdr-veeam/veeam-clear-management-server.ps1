## Removes the old Veeam management server registration from an endpoint.
## Use when migrating an endpoint to a new Veeam B&R server and you get:
##   "host is managed by another backup server"
##
## Run on the ENDPOINT (not the Veeam server). Requires admin privileges.
##
## $env:DESCRIPTION   - Ticket # or initials for audit trail
## $env:RMM           - Set to 1 when running from RMM platform

$SCRIPT_LOG_NAME = "veeam-clear-management-server.log"

if ($env:RMM -ne "1") {
    $env:DESCRIPTION = Read-Host "Ticket # or initials for audit trail"
    $LOG_PATH = "$env:WINDIR\logs\$SCRIPT_LOG_NAME"
} else {
    if (-not $env:DESCRIPTION) { $env:DESCRIPTION = "No Description" }
    if ($env:RMM_SCRIPT_PATH) {
        $LOG_DIR = "$env:RMM_SCRIPT_PATH\logs"
        if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null }
        $LOG_PATH = "$LOG_DIR\$SCRIPT_LOG_NAME"
    } else {
        $LOG_PATH = "$env:WINDIR\logs\$SCRIPT_LOG_NAME"
    }
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
