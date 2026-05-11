# NinjaRMM to Halo PSA GUID Sync
# Documentation: BookStack page 1908
# Schedule: Weekly (Sundays 2:00 AM EDT)
#
# Client IDs are not secrets and are hardcoded below.
# Client secrets are injected at runtime via NinjaRMM Script Variables:
#   haloclientsecret  — set in Library > Automation > Halo GUID Sync > Script Variables
#   ninjaclientsecret — set in Library > Automation > Halo GUID Sync > Script Variables
#
# Credentials stored in 1Password: Halo/NinjaRMM API - GUID Sync Secret
# Never commit real secrets to this repository.

# --- CONFIGURATION ---
$HaloClientId      = "25542a6d-2d0e-4093-bf82-e11edc64faf6"
$HaloClientSecret  = $env:haloclientsecret
$HaloBaseUrl       = "https://psa.dtctoday.com"
$HaloScope         = "read:customers edit:customers"

$NinjaClientId     = "0S1xEjce1FQp7Rbn_GJTrSWTp64"
$NinjaClientSecret = $env:ninjaclientsecret
$NinjaBaseUrl      = "https://app.ninjarmm.com"

# --- VALIDATE ---
$missing = @()
if ([string]::IsNullOrWhiteSpace($HaloClientSecret))  { $missing += "haloclientsecret" }
if ([string]::IsNullOrWhiteSpace($NinjaClientSecret)) { $missing += "ninjaclientsecret" }

if ($missing.Count -gt 0) {
    Write-Error "Missing NinjaRMM Script Variables: $($missing -join ", "). Set default values in Library > Automation > Halo GUID Sync > Script Variables."
    exit 1
}

# --- AUTHENTICATE: HALO ---
try {
    $haloTokenResp = Invoke-RestMethod -Method Post -Uri "$HaloBaseUrl/auth/token" `
        -ContentType "application/x-www-form-urlencoded" -Body @{
            grant_type    = "client_credentials"
            client_id     = $HaloClientId
            client_secret = $HaloClientSecret
            scope         = $HaloScope
        }
    $haloToken   = $haloTokenResp.access_token
    $haloHeaders = @{ Authorization = "Bearer $haloToken" }
} catch {
    Write-Error "Halo auth failed: $($_.Exception.Message)"
    exit 1
}

# --- AUTHENTICATE: NINJA ---
try {
    $ninjaTokenResp = Invoke-RestMethod -Method Post -Uri "$NinjaBaseUrl/ws/oauth/token" `
        -ContentType "application/x-www-form-urlencoded" -Body @{
            grant_type    = "client_credentials"
            client_id     = $NinjaClientId
            client_secret = $NinjaClientSecret
            scope         = "monitoring management"
        }
    $ninjaToken   = $ninjaTokenResp.access_token
    $ninjaHeaders = @{ Authorization = "Bearer $ninjaToken" }
} catch {
    Write-Error "Ninja auth failed: $($_.Exception.Message)"
    exit 1
}

# --- PULL NINJA ORGS ---
$orgs = Invoke-RestMethod -Method Get -Uri "$NinjaBaseUrl/v2/organizations" -Headers $ninjaHeaders

$results = @()

foreach ($org in $orgs) {
    $orgName = $org.name
    $orgId   = $org.id

    try {
        $cf   = Invoke-RestMethod -Method Get `
            -Uri "$NinjaBaseUrl/v2/organization/$orgId/custom-fields" -Headers $ninjaHeaders
        $guid = $cf.dtcOrgGuid
    } catch {
        Write-Host "Could not read custom fields for $orgName -- skipping"
        continue
    }

    if ([string]::IsNullOrWhiteSpace($guid)) {
        $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = "No GUID"; GUID = "" }
        continue
    }

    try {
        $haloSearch = Invoke-RestMethod -Method Get `
            -Uri "$HaloBaseUrl/api/client?search=$([uri]::EscapeDataString($orgName))" `
            -Headers $haloHeaders
    } catch {
        Write-Host "Halo search failed for $orgName -- skipping"
        continue
    }

    $haloClient = $haloSearch.clients | Where-Object { $_.name -eq $orgName } | Select-Object -First 1

    if (-not $haloClient) {
        Write-Host "No exact Halo match for $orgName -- skipping"
        $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = "No Halo match"; GUID = $guid }
        continue
    }

    # Body must be a JSON array per Halo API requirements
    # PowerShell 5 unwraps single-item @() on ConvertTo-Json so we manually wrap
    $clientUpdate = @{
        id           = $haloClient.id
        customfields = @(
            @{ name = "CFDtcClientGuid"; value = $guid }
        )
    }
    $body = "[" + ($clientUpdate | ConvertTo-Json -Depth 5) + "]"

    try {
        Invoke-RestMethod -Method Post -Uri "$HaloBaseUrl/api/client" `
            -Headers $haloHeaders -ContentType "application/json" -Body $body | Out-Null
        Write-Host "Updated $orgName"
        $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = "Updated"; GUID = $guid }
    } catch {
        $errorDetail = $_.ErrorDetails.Message
        Write-Host "Failed to update $orgName -- $($_.Exception.Message) | $errorDetail"
        $results += [PSCustomObject]@{ NinjaOrg = $orgName; Status = "Failed"; GUID = $guid }
    }
}

Write-Host ""
Write-Host "===== SYNC SUMMARY ====="
$results | Format-Table -AutoSize
