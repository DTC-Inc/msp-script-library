<#
.SYNOPSIS
    Syncs DTC Org GUID from NinjaRMM organizations to Halo PSA client custom field.

.DESCRIPTION
    Reads the dtcOrgGuid custom field from each NinjaRMM organization and writes
    it to the CFDtcClientGuid field in Halo PSA for all exactly-matched clients.

    Runs unattended via NinjaOne Scheduled Task (Sundays 2:00 AM EDT).
    Matching is exact by client name. Name mismatches are logged and skipped.

.PARAMETER haloclientsecret
    Halo PSA API client secret. Injected by NinjaOne Script Variable: haloclientsecret.

.PARAMETER ninjaclientsecret
    NinjaRMM API client secret. Injected by NinjaOne Script Variable: ninjaclientsecret.

.NOTES
    Author:      Tyler Dantzler
    Repo:        DTC-Inc/msp-script-library/integrations/ninja-halo-guid-sync.ps1
    BookStack:   Page 1908
    Schedule:    Weekly, Sundays 2:00 AM EDT (NinjaOne Scheduled Task)

    ## PLEASE COMMENT YOUR VARIABLES DIRECTLY BELOW HERE IF YOU ARE RUNNING FROM A RMM
    # $env:RMM             -- set to "1" by NinjaOne at runtime; controls RMM vs interactive mode
    # $env:Description     -- human-readable audit trail label for this run
    # $env:haloclientsecret  -- Halo PSA API client secret (NinjaOne Script Variable)
    # $env:ninjaclientsecret -- NinjaRMM API client secret (NinjaOne Script Variable)
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# --- AUDIT TRAIL & LOGGING ---
$ScriptLogName = 'ninja-halo-guid-sync'
$Description   = if ($env:Description) { $env:Description } else { 'NinjaRMM to Halo PSA GUID sync (manual run)' }
$logPath       = "C:\ProgramData\DTC\Logs\$ScriptLogName-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
New-Item -ItemType Directory -Path (Split-Path $logPath) -Force | Out-Null
Start-Transcript -Path $logPath -Append

Write-Information "[$ScriptLogName] Starting — $Description" -InformationAction Continue

try {

    # --- CONFIGURATION ---
    # Client IDs are not secrets — hardcoded here.
    # Client secrets are injected via NinjaOne Script Variables (env vars at runtime).
    $HaloClientId      = '25542a6d-2d0e-4093-bf82-e11edc64faf6'
    $HaloClientSecret  = $env:haloclientsecret
    $HaloBaseUrl       = 'https://psa.dtctoday.com'
    $HaloScope         = 'read:customers edit:customers'

    $NinjaClientId     = '0S1xEjce1FQp7Rbn_GJTrSWTp64'
    $NinjaClientSecret = $env:ninjaclientsecret
    $NinjaBaseUrl      = 'https://app.ninjarmm.com'

    # --- VALIDATE SECRETS ---
    $missing = @()
    if ([string]::IsNullOrWhiteSpace($HaloClientSecret))  { $missing += 'haloclientsecret' }
    if ([string]::IsNullOrWhiteSpace($NinjaClientSecret)) { $missing += 'ninjaclientsecret' }

    if ($missing.Count -gt 0) {
        throw "Missing NinjaOne Script Variables: $($missing -join ', '). Set default values in Library > Automation > Halo GUID Sync > Script Variables."
    }

    # --- AUTHENTICATE: HALO ---
    Write-Information '  Authenticating with Halo PSA...' -InformationAction Continue
    $haloTokenResp = Invoke-RestMethod -Method Post -Uri "$HaloBaseUrl/auth/token" `
        -ContentType 'application/x-www-form-urlencoded' -Body @{
            grant_type    = 'client_credentials'
            client_id     = $HaloClientId
            client_secret = $HaloClientSecret
            scope         = $HaloScope
        }
    $haloToken   = $haloTokenResp.access_token
    $haloHeaders = @{ Authorization = "Bearer $haloToken" }
    Write-Information '  Halo auth OK' -InformationAction Continue

    # --- AUTHENTICATE: NINJA ---
    Write-Information '  Authenticating with NinjaRMM...' -InformationAction Continue
    $ninjaTokenResp = Invoke-RestMethod -Method Post -Uri "$NinjaBaseUrl/ws/oauth/token" `
        -ContentType 'application/x-www-form-urlencoded' -Body @{
            grant_type    = 'client_credentials'
            client_id     = $NinjaClientId
            client_secret = $NinjaClientSecret
            scope         = 'monitoring management'
        }
    $ninjaToken   = $ninjaTokenResp.access_token
    $ninjaHeaders = @{ Authorization = "Bearer $ninjaToken" }
    Write-Information '  Ninja auth OK' -InformationAction Continue

    # --- PULL NINJA ORGS ---
    $orgs    = Invoke-RestMethod -Method Get -Uri "$NinjaBaseUrl/v2/organizations" -Headers $ninjaHeaders
    $results = @()

    foreach ($org in $orgs) {
        $orgName = $org.name
        $orgId   = $org.id

        # Read DTC Org GUID custom field
        try {
            $cf   = Invoke-RestMethod -Method Get `
                -Uri "$NinjaBaseUrl/v2/organization/$orgId/custom-fields" -Headers $ninjaHeaders
            $guid = $cf.dtcOrgGuid
        } catch {
            Write-Warning "Could not read custom fields for '$orgName' — skipping"
            continue
        }

        if ([string]::IsNullOrWhiteSpace($guid)) {
            $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = 'No GUID'; GUID = '' }
            continue
        }

        # Search Halo for matching client by exact name
        try {
            $haloSearch = Invoke-RestMethod -Method Get `
                -Uri "$HaloBaseUrl/api/client?search=$([uri]::EscapeDataString($orgName))" `
                -Headers $haloHeaders
        } catch {
            Write-Warning "Halo search failed for '$orgName' — skipping"
            continue
        }

        $haloClient = $haloSearch.clients | Where-Object { $_.name -eq $orgName } | Select-Object -First 1

        if (-not $haloClient) {
            Write-Warning "No exact Halo match for '$orgName' — skipping"
            $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = 'No Halo match'; GUID = $guid }
            continue
        }

        # Build body — PowerShell 5 unwraps single-item @() on ConvertTo-Json so manually wrap in []
        $clientUpdate = @{
            id           = $haloClient.id
            customfields = @(
                @{ name = 'CFDtcClientGuid'; value = $guid }
            )
        }
        $body = '[' + ($clientUpdate | ConvertTo-Json -Depth 5) + ']'

        try {
            Invoke-RestMethod -Method Post -Uri "$HaloBaseUrl/api/client" `
                -Headers $haloHeaders -ContentType 'application/json' -Body $body | Out-Null
            Write-Information "  [OK] $orgName" -InformationAction Continue
            $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = 'Updated'; GUID = $guid }
        } catch {
            $errorDetail = $_.ErrorDetails.Message
            Write-Warning "Failed to update '$orgName' — $($_.Exception.Message) | $errorDetail"
            $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = 'Failed'; GUID = $guid }
        }
    }

    # --- SUMMARY ---
    Write-Information '' -InformationAction Continue
    Write-Information '===== SYNC SUMMARY =====' -InformationAction Continue
    $results | Format-Table -AutoSize

    $failed = $results | Where-Object { $_.Status -eq 'Failed' }
    if ($failed) {
        Write-Warning "$($failed.Count) client(s) failed to update — see above"
        exit 2
    }

    Write-Information "[$ScriptLogName] Completed successfully." -InformationAction Continue
    exit 0

} catch {
    Write-Error "FAILED: $_"
    Write-Error $_.ScriptStackTrace
    exit 1
} finally {
    Stop-Transcript
}
