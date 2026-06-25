# BDR Veeam Scripts

Scripts for managing Veeam Backup & Replication servers deployed by DTC via NinjaRMM.

## Core Automation Scripts (New)

These scripts form the automated BDR provisioning and monitoring pipeline. They are designed to run from NinjaRMM with org-level and device-level custom fields.

### veeam-configure-backblaze-repo.ps1
Creates a Backblaze B2 bucket and registers it as a Veeam S3-compatible repository.

**Storage isolation is per-LOCATION, per-DEVICE:**

```
bucket:  veeam-{location-ouid-flat}     (one bucket per location)
folder:  {device-ouid-dashed}/          (one repository root per BDR; Veeam owns everything below)
```

Locations get bought and sold, so the bucket tracks the location OUID (looked up at runtime from NinjaOne), not the org. The per-device folder is the BDR's device OUID, so a single location bucket can hold more than one BDR. The device OUID is recomputable from a stable source (minted once, persisted on the device), so re-runs and rebuilds resolve to the SAME folder and reclaim existing data. See [Cloud Backup Architecture Standards](https://kb.dtctoday.com/books/dtcs-pillars-of-technology/page/cloud-backup-architecture-standards) and [OUID Standard](https://kb.dtctoday.com/books/dtcs-pillars-of-technology/page/operational-uuid-ouid-standard).

> **Prerequisite:** the device must already have a Device GUID. Run `rmm-ninja/ninja-ensure-device-guid.ps1` first (mints + persists the device OUID). This script fails fast if no Device GUID is found.

**What it does:**
1. Reads location OUID from the NinjaRMM location field; computes bucket `veeam-{location-ouid-flat}`
2. Resolves this device's OUID (registry `HKLM\SOFTWARE\DTC\DeviceGuid`, then NinjaOne field)
3. Creates the B2 bucket; enables Object Lock (for immutability) and SSE-B2 encryption
4. Sets lifecycle rule to purge hidden file versions after immutability + 1 day
5. Creates a scoped B2 application key restricted to that bucket only
6. Saves bucket name + scoped key to NinjaRMM device fields (before Veeam step)
7. Registers the Veeam S3 repository with immutability enabled, rooted at the `{device-ouid}/` folder

**Idempotency:** Bucket name and folder are both deterministic (location OUID, device OUID), so re-runs target the same paths. If bucket name + keys already exist in NinjaRMM, skips B2 creation and only creates the Veeam repo. Safe to re-run after failures.

**NinjaRMM Fields:**

| Variable | Level | Type | Purpose |
|----------|-------|------|---------|
| `CUSTOM_FIELD_LOCATION_UUID` | Location | Text | Location OUID (read via Ninja-Property-Get) |
| `CUSTOM_FIELD_DEVICE_GUID` | Device | Text | Device OUID (fallback if registry empty; see ninja-ensure-device-guid.ps1) |
| `B2_ADMIN_KEY_ID` | Org | Text | Master B2 key ID (never stored on device) |
| `B2_ADMIN_APP_KEY` | Org | Secure | Master B2 app key |
| `B2_ENDPOINT` | Org | Text | e.g. `https://s3.us-west-002.backblazeb2.com` |
| `B2_REGION` | Org | Text | e.g. `us-west-002` |
| `IMMUTABILITY_DAYS` | Script | Text | Default: 14 |
| `CUSTOM_FIELD_S3_BUCKET_NAME` | Device | Text | Output: bucket name |
| `CUSTOM_FIELD_S3_KEY_ID` | Device | Secure | Output: scoped key ID |
| `CUSTOM_FIELD_S3_APP_KEY` | Device | Secure | Output: scoped app key |

### veeam-configure-s3-copy-job.ps1
Creates or updates the S3 backup copy job. Ensures all backup jobs are linked as sources.

**What it does:**
1. Finds the S3 repository (from NinjaRMM field or auto-detect)
2. Collects all source backup jobs (Get-VBRJob + Get-VBRComputerBackupJob, excludes copy jobs)
3. If a copy job targeting the S3 repo exists: adds missing sources, renames to match pattern
4. If none exists: creates one in Periodic mode
5. Applies schedule, encryption, and enables the job (every run, not just creation)

**Schedule:** Mon-Fri 10 PM - 5 AM, Sat-Sun all day

**NinjaRMM Fields:**

| Variable | Level | Type | Purpose |
|----------|-------|------|---------|
| `CUSTOM_FIELD_S3_BUCKET_NAME` | Device | Text | Used to find the S3 repo |
| `CUSTOM_FIELD_CLOUD_RETENTION` | Org | Text | Retention days (default: 30) |

### veeam-configure-local-backup-jobs.ps1
Configures backup windows on all local backup jobs.

**Schedule:** Mon-Fri 6 AM - 9 PM, Sat-Sun disabled

This complements the S3 copy job schedule. 1-hour buffer (9 PM - 10 PM) between local backups stopping and S3 copy starting.

### veeam-inventory.ps1
Comprehensive inventory and health check. Populates multiple NinjaRMM fields.

**What it detects:**
- S3 bucket name and storage size (via Veeam backup copy job + child backup storages)
- **Active vs inactive S3 repositories.** Active = a backup copy job currently targets the repo (live pipeline). Inactive = a registered S3 repo with no copy job pointing at it (e.g. a pre-move bucket left behind, still billable). Rendered as two separate tables in the inventory field, each with a Last Backup column.
- **Total used space across all S3 repos** (active + inactive) — the full B2 footprint, so leftover buckets show up in the cost picture.
- Orphaned/stale backups across all repos (configurable threshold, default 30 days)
- Failed backup jobs (checks most recent session per job, clears when job succeeds)
- Missing S3 copy job (no S3 repo, no copy job, or missing source jobs)

**NinjaRMM Fields:**

| Variable | Type | Purpose |
|----------|------|---------|
| `CUSTOM_FIELD_S3_BUCKET_NAME` | Text | Last used S3 bucket name |
| `CUSTOM_FIELD_S3_BUCKET_SIZE` | Text | Last used S3 bucket size |
| `CUSTOM_FIELD_S3_TOTAL_SIZE` | Text | Total used space across ALL S3 repos (active + inactive) |
| `CUSTOM_FIELD_S3_INVENTORY` | WYSIWYG | HTML tables: active + inactive S3 repos, with total |
| `CUSTOM_FIELD_ORPHANS_FOUND` | Checkbox | 1 if orphaned backups exist |
| `CUSTOM_FIELD_ORPHANED_BACKUPS` | WYSIWYG | HTML table of orphaned backups |
| `CUSTOM_FIELD_FAILED_BACKUP` | Checkbox | 1 if any job's last run failed |
| `CUSTOM_FIELD_FAILED_BACKUPS` | WYSIWYG | HTML table of failed jobs |
| `CUSTOM_FIELD_S3_COPY_MISSING` | Checkbox | 1 if S3 copy job missing/incomplete |
| `ORPHAN_DAYS_THRESHOLD` | Config | Days before stale (default: 30) |

### veeam-clear-management-server.ps1
Removes old Veeam management server registration from endpoints. Run on the endpoint (not the server).

**Use when:** Migrating endpoints to a new Veeam B&R server and getting "host is managed by another backup server" error.

## Backblaze B2 Scripts (iaas-backblaze/)

### b2-bucket-audit.ps1
Lists all B2 buckets in the account, compares against a known-good list, flags unused buckets in red.

### b2-fix-lifecycle.ps1
Applies lifecycle rules to existing B2 buckets to purge hidden file versions. Fixes storage bloat from B2 keeping all versions forever.

## Technical Reference

### PS7 Bootstrap
All scripts that use the Veeam PowerShell module include a PS7 bootstrap. Veeam 12.x requires PowerShell 7+.

```powershell
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $PWSH_PATH = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
    if (-not (Test-Path $PWSH_PATH)) {
        $PWSH_CANDIDATE = Get-Command pwsh.exe -ErrorAction SilentlyContinue
        $PWSH_PATH = if ($PWSH_CANDIDATE) { $PWSH_CANDIDATE.Source } else { $null }
    }
    # ...
}
```

**Critical:** Always prefer 64-bit PS7 (`$env:ProgramFiles`, not `$env:ProgramFiles(x86)`). Veeam's native SQLite DLL is x64 only. Using 32-bit PS7 causes `SqliteConnection` type initializer failures.

### PS7.4+ SQLite Conflict
PowerShell 7.4+ ships `Microsoft.Data.Sqlite` that conflicts with Veeam's bundled version. The fix has two parts:

1. **Add Veeam's native DLL path to PATH** so `e_sqlite3.dll` is found:
```powershell
$VEEAM_RUNTIMES = "$env:ProgramFiles\Veeam\Backup and Replication\Backup\runtimes\win-x64\native"
$env:PATH = "$VEEAM_RUNTIMES;$env:PATH"
```

2. **Register an AssemblyResolve handler** to redirect managed DLL loads to Veeam's versions:
```powershell
$null = [System.AppDomain]::CurrentDomain.add_AssemblyResolve({
    param($sender, $args)
    if (-not $args.Name) { return $null }  # Null check required
    $ASSEMBLY_NAME = [System.Reflection.AssemblyName]::new($args.Name)
    $VEEAM_DLL = Join-Path $VEEAM_BACKUP_DIR "$($ASSEMBLY_NAME.Name).dll"
    if (Test-Path $VEEAM_DLL) { return [System.Reflection.Assembly]::LoadFrom($VEEAM_DLL) }
    return $null
})
```

**Important:** The null check on `$args.Name` is required. .NET passes empty assembly names which crash the handler without it.

### Veeam PowerShell Gotchas (Veeam 12.x)

**Non-interactive execution:**
- Do NOT use `-NonInteractive` in the PS7 bootstrap. Veeam cmdlets use `Read-Host` internally for certificate trust prompts, which hard-fails in NonInteractive mode (hangs instead of erroring).
- Set `$ConfirmPreference = 'None'` before Veeam cmdlet calls.
- `-Confirm:$false` is NOT a valid parameter on most Veeam cmdlets (they don't implement `ShouldProcess`).

**Add-VBRAmazonS3CompatibleRepository:**
- `-EnableBucketAutoProvision:$false` is required. Default changed to `$true` in Veeam 12.3.1 and hangs on non-AWS S3 endpoints.
- `-EnableBackupImmutability` is required when the B2 bucket has Object Lock enabled. Without it: "Enable backup immutability because the S3 Object Lock feature is enabled."
- Do NOT set bucket-level `defaultRetention` via B2 API. Veeam manages immutability per-object. Bucket default causes "default retention is not supported" errors.

**Add-VBRBackupCopyJob:**
- `-Mode` is a required parameter (values: `Periodic`, `Immediate`). Script hangs if not provided.
- Periodic mode: uses `ScheduleOptions`, does NOT support `Anytime` or `BackupWindowOptions`.
- Immediate mode: supports `Anytime` and `BackupWindowOptions`.
- Job name max length: 50 characters.

**New-VBRBackupCopyJobStorageOptions:**
- `CompressionLevel` and `StorageOptimizationType` are MANDATORY. Hangs if not provided.
- CompressionLevel values: `Auto`, `None`, `DedupeFriendly`, `Optimal`, `High`, `Extreme`
- StorageOptimizationType values: `Automatic`, `LocalTarget`, `LocalTargetHugeBackup`, `LANTarget`, `WANTarget`
- Use `Automatic` for copy jobs (not `LocalTarget` which errors on "image-level backup copy job").

**Get-VBRObjectStorageRepository:**
- Returns skeleton objects with NULL sub-properties (ArchiveRepository, AmazonCompatibleOptions, Options, Info all null).
- To get bucket name: use `Get-VBRBackupCopyJob` -> `.TargetRepository.AmazonCompatibleOptions.BucketName` instead.

**GetObjects() on agent backup jobs:**
- Returns 0 for Windows Agent Backup/Policy types. Only works for VM backups.
- For agent backups, use child backup names or time-based detection instead.

**Backup size calculation:**
- Parent backups with `IsTruePerVmContainer = true` have 0 storages.
- Must call `FindChildBackups()` and sum `GetAllStorages()` -> `Stats.BackupSize` across children.

**RetentionType enum:**
- Values are `RestoreDays` and `RestorePoints` (not `Days` or `Cycles`).

### Backblaze B2 API Reference

**Authentication:**
- Use `-Authentication Basic -Credential $PSCredential` (not manual header construction). B2 auth tokens contain `=` characters that `Invoke-RestMethod` header validation rejects.
- For post-auth API calls, use `-SkipHeaderValidation $true` in the headers.
- API v2 is the most reliable. v4 works but v3 does not exist.

**Bucket creation:**
- `fileLockEnabled: true` enables Object Lock (required for Veeam immutability). Cannot be added after creation.
- Object Lock requires versioning (automatic). Cannot disable versioning on Object Lock buckets.
- Set lifecycle rule `daysFromHidingToDeleting` to purge old hidden versions. Without this, B2 keeps ALL versions forever (causes massive storage bloat, e.g. 11 TB active = 50 TB in B2).

**Scoped application keys:**
- Must include `listAllBucketNames` capability for bucket-restricted keys. Without it, Veeam gets "Invalid credentials" because S3 ListBuckets fails.
- Full capability list for Veeam: `listBuckets`, `listAllBucketNames`, `readBuckets`, `listFiles`, `readFiles`, `writeFiles`, `deleteFiles`, `readBucketEncryption`, `writeBucketEncryption`, `readBucketRetentions`, `writeBucketRetentions`, `readFileRetentions`, `writeFileRetentions`, `readFileLegalHolds`, `writeFileLegalHolds`, `bypassGovernance`

**Daily usage reports:**
- No real-time bucket size API exists.
- B2 generates daily audit CSVs in `b2-reports-{accountId}` bucket with `storageByteCount` per bucket.

### NinjaRMM Integration

**Org-level fields:** Read with `Ninja-Property-Get $env:FIELD_NAME`. The env var contains the field API name (e.g. `dtcOrgGuid`), not the value.

**Device-level fields:** Write with `Ninja-Property-Set $fieldName $value`. Read with `Ninja-Property-Get $fieldName`.

**Important:** `Ninja-Property-Get -Organization` does NOT work from scripts. Org-level fields must be configured to inherit to device level in NinjaRMM, then read normally.
