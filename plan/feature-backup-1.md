---
goal: OpenClaw gateway backup — daily + weekly retention for dev and prod
plan_type: standalone
version: 1.0
date_created: 2026-04-01
last_updated: 2026-04-01
owner: openclaw-core
status: 'Planned'
tags: [feature, backup, operations]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

Implement automated, daily OpenClaw gateway backup for both dev and prod environments. Backups use `openclaw backup create --verify` (the supported CLI command), are stored on a dedicated Azure Files share mounted into the container, and are pruned automatically to retain daily archives for 7 days and one archive per week for 10 weeks.

Azure infrastructure is excluded from backup scope — Terraform + the repo constitute authoritative, versioned infrastructure config. Only OpenClaw runtime state (config, sessions, credentials, workspaces) requires backup.

## 1. Requirements & Constraints

- **REQ-001**: Run `openclaw backup create --verify` inside the running Container App using the same PTY exec pattern as `seed-openclaw-ci.sh` (script(1) wrapping `az containerapp exec`).
- **REQ-002**: Backup runs must cover both dev and prod environments; dev is the test bed.
- **REQ-003**: Retention policy: keep **all** archives where archive date ≥ today − 7 days (daily window); keep **one** archive per ISO-week for the 10 most recent weeks (weekly window); delete everything else.
- **REQ-004**: Backup archive verification (`--verify`) must pass before the run is considered successful.
- **REQ-005**: Backup must run at least once daily via scheduled GitHub Actions.
- **CON-001**: `az containerapp exec` is rate-limited (~5 sessions per 10 minutes). The backup job uses 1 exec session per run. Combined with the seed script's 2 sessions, budget must be tracked.
- **CON-002**: Backup output path must be **outside** `/home/node/.openclaw` (the state mount) to avoid self-inclusion. A separate share mounted at `/mnt/openclaw-backup` satisfies this.
- **CON-003**: All Terraform changes must be declarative; no imperative `az` commands to provision infrastructure.
- **CON-004**: Never place secrets in source code or workflow files. Storage keys are retrieved at runtime via `az storage account keys list`.
- **CON-005**: Backup is a safe read-only operation on state; no `ALLOW_PROD_BACKUP` guard is required. Both environments run automatically.
- **SEC-001**: Storage keys retrieved at runtime from Azure are treated as ephemeral; they must not be logged or stored.
- **GUD-001**: Retention pruning operates entirely via `az storage file list` / `az storage file delete` — no exec into the container needed for pruning.
- **GUD-002**: The backup share uses the same storage account as the state share (Standard LRS) for cost efficiency — no additional storage account is provisioned.
- **PAT-001**: GitHub Actions backup jobs use GitHub Environments (`environment: dev` / `environment: prod`) identically to `terraform-deploy.yml` to inherit environment-scoped secrets.

## 2. Implementation Steps

### Implementation Phase 1 — Terraform: backup share and container mount

- GOAL-001: Provision a dedicated `openclaw-backup` Azure Files share on each environment's existing storage account and mount it into the Container App at `/mnt/openclaw-backup`.

| Task     | Description                                                                                                                                                                                                                                                 | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | Add local `openclaw_backup_file_share_name = "openclaw-backup"` to `terraform/locals.tf` alongside the existing `openclaw_state_file_share_name` local.                                                                                                    |           |      |
| TASK-002 | Add `variable "openclaw_backup_share_quota_gb"` to `terraform/variables.tf` with `default = 10`, description, and validation `>= 1 && <= 102400`. 10 GiB is sufficient: a compressed backup of typical config + sessions is well under 1 GiB per archive. |           |      |
| TASK-003 | Add `azurerm_storage_share.openclaw_backup` resource to `terraform/storage.tf` referencing `azurerm_storage_account.openclaw_state.id`, `local.openclaw_backup_file_share_name`, and `var.openclaw_backup_share_quota_gb`.                                  |           |      |
| TASK-004 | Add `azurerm_container_app_environment_storage.openclaw_backup` resource to `terraform/storage.tf` using the same storage account, access key, and the new backup share name. Name the CAE storage resource `"openclaw-backup"`.                            |           |      |
| TASK-005 | In `terraform/containerapp.tf`, add a second entry to the `volumes` list: `{ name = "openclaw-backup", storage_type = "AzureFile", storage_name = azurerm_container_app_environment_storage.openclaw_backup.name }`.                                        |           |      |
| TASK-006 | In `terraform/containerapp.tf`, add a second entry to the container's `volume_mounts` list: `{ name = "openclaw-backup", path = "/mnt/openclaw-backup" }`.                                                                                                 |           |      |

### Implementation Phase 2 — Backup and retention script

- GOAL-002: Create `scripts/backup-openclaw.sh` that (a) runs the backup inside the container via PTY exec, and (b) prunes old archives from the backup share without any further exec.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                   | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-007 | Create `scripts/backup-openclaw.sh`. Header: shebang, doc block (purpose, usage `bash scripts/backup-openclaw.sh [dev\|prod]`, prerequisites, constraints matching `seed-openclaw-ci.sh` style). `set -euo pipefail`.                                                                                                                                                                                         |           |      |
| TASK-008 | Derive variables from environment arg: `ENV`, `PROJECT` (`TF_VAR_project` / `TF_VAR_PROJECT` / `paa`), `APP_NAME`, `RG_NAME`, `STORAGE_ACCOUNT` (same formula as seed scripts: `${PROJECT}${ENV}ocstate`), `BACKUP_SHARE="openclaw-backup"`, `BACKUP_MOUNT="/mnt/openclaw-backup"`.                                                                                                                          |           |      |
| TASK-009 | Implement `pty_exec()` helper identical to `seed-openclaw-ci.sh`: wrap `az containerapp exec --name $APP_NAME --resource-group $RG_NAME --command '<cmd>'` in `script -q -c "..." /dev/null \| tr -d '\r'`.                                                                                                                                                                                                  |           |      |
| TASK-010 | Retrieve storage key via `az storage account keys list --account-name "$STORAGE_ACCOUNT" --resource-group "$RG_NAME" --query "[0].value" -o tsv`. Fail fast if empty.                                                                                                                                                                                                                                        |           |      |
| TASK-011 | Run backup via PTY exec: `node /app/openclaw.mjs backup create --output ${BACKUP_MOUNT} --verify`. Capture output. Check for ENOTTY, HTTP 429 (rate-limit), and the word `error` / `failed` in output. Exit non-zero on failure. On success, extract the created archive filename from output (grep for `.tar.gz`) and echo it.                                                                               |           |      |
| TASK-012 | Implement retention pruning using only `az storage file` commands (no exec). Algorithm: (1) List all `.tar.gz` files in the backup share root via `az storage file list --share-name "$BACKUP_SHARE" --query "[].name" -o tsv`. (2) Parse the ISO-8601 date prefix from each filename (`YYYY-MM-DD`). (3) Compute two keep-sets and delete files in neither. See retention algorithm detail in RISK-002 note. |           |      |
| TASK-013 | Retention algorithm detail (implement in `prune_archives` function): daily cutoff = today − 7 days; weekly cutoff = today − 70 days. For each file: if date ≥ daily cutoff → keep. Else if date ≥ weekly cutoff: compute ISO week number of the file date; if this is the first (oldest) file seen for that week → keep. Else → delete via `az storage file delete --share-name "$BACKUP_SHARE" --path "$f"`. |           |      |
| TASK-014 | Add a summary echo at the end: `BACKUP: ✅ backup=$ARCHIVE_NAME  kept=$KEPT  deleted=$DELETED`. Non-zero exit if backup exec failed; pruning failures are warnings only (do not fail the CI job).                                                                                                                                                                                                             |           |      |

### Implementation Phase 3 — GitHub Actions scheduled workflow

- GOAL-003: Create `.github/workflows/backup.yml` to run `backup-openclaw.sh` daily for both environments using environment-scoped secrets identical to `terraform-deploy.yml`.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                              | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-015 | Create `.github/workflows/backup.yml`. Triggers: `schedule: cron: '0 2 * * *'` (02:00 UTC daily) and `workflow_dispatch` with optional `environment` input (`dev` or `both`, default `both`). `permissions: contents: read`.                                                                                                                                                                                            |           |      |
| TASK-016 | Add job `backup-dev` using `environment: dev`. Env block mirrors `terraform-deploy.yml` dev env block: `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `TF_VAR_project`, `TF_VAR_environment: dev`. Steps: Checkout → Azure Login (SP, same shell block as existing workflows) → `chmod +x scripts/backup-openclaw.sh && bash scripts/backup-openclaw.sh dev`.                   |           |      |
| TASK-017 | Add job `backup-prod` using `environment: prod`, identical structure to `backup-dev` but `TF_VAR_environment: prod`. Both jobs run independently (no `needs:` dependency — dev failure must not block prod backup). scheduled trigger runs both; `workflow_dispatch` with `environment: dev` skips prod job via `if: inputs.environment == 'both' \|\| inputs.environment == 'prod'` (and vice-versa for dev). |           |      |
| TASK-018 | Add `TF_VAR_project: ${{ vars.TF_VAR_PROJECT }}` to each job env — the backup script uses this to compute `APP_NAME` and `RG_NAME` without hardcoding the project slug.                                                                                                                                                                                                                                                |           |      |

### Implementation Phase 4 — Trigger first backup manually (post-Terraform apply)

- GOAL-004: Validate end-to-end after Terraform apply provisions the backup share and container mount.

| Task     | Description                                                                                                                                                                                                                                                | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-019 | After merging TASK-001 through TASK-018: run `terraform-deploy.yml` via `workflow_dispatch` targeting dev to apply the new share + volume mount. Confirm Container App revision is updated with the `/mnt/openclaw-backup` mount.                           |           |      |
| TASK-020 | Trigger `backup.yml` via `workflow_dispatch` with `environment: dev`. Confirm: archive `.tar.gz` appears in `openclaw-backup` share, archive name logged in workflow output, `--verify` passes (no error in output), retention summary shows 1 kept, 0 deleted. |           |      |
| TASK-021 | Run `backup.yml` via `workflow_dispatch` with `environment: both` (or wait for schedule) to confirm prod backup also completes cleanly.                                                                                                                     |           |      |

## 3. Alternatives

- **ALT-001**: Write archives to the existing `openclaw-state` share in a `backups/` subdirectory. Rejected — the docs explicitly state that output paths inside the source state tree are rejected by OpenClaw to avoid self-inclusion. A separate mount is required.
- **ALT-002**: Use Azure Backup (Recovery Services Vault) on the storage account. Rejected — Azure Backup for Files requires configuring a vault and backup policy, adds significant cost (vault instance + storage), and does not use the supported `openclaw backup` CLI command. The supported CLI handles what gets backed up correctly (config, sessions, credentials, workspaces with manifest).
- **ALT-003**: Run `openclaw backup create` locally from the GitHub Actions runner (not inside the container) by mounting the Azure Files share via SMB. Rejected — SMB port 445 is not available from GitHub-hosted runners without a private network; the container has the share already mounted at the right path.
- **ALT-004**: Separate storage account for backups. Rejected — adds monthly baseline cost for an additional Standard account. One extra share on the existing Standard LRS account costs only the consumed storage (fractions of a cent per day for typical OpenClaw state).
- **ALT-005**: Use `--only-config` to minimize backup size and exec time. Noted as a fallback if full backups become slow — `--only-config` archives only `openclaw.json` and skips state, credentials, session, and workspace discovery. Prefer full backup for genuine recoverability.

## 4. Dependencies

- **DEP-001**: `script` (util-linux) available on `ubuntu-latest` GitHub Actions runners — already confirmed by seed-openclaw-ci.sh usage.
- **DEP-002**: Container App must be running (min_replicas = 0 means it may be scaled to zero); backup exec will time out if there is no active replica. The backup job does not need to handle scale-up — the Container App environment will route to an active replica if one exists, or the exec will fail with a clear error.
- **DEP-003**: GitHub Environments `dev` and `prod` must have `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` secrets — already present from Terraform deploy workflow.
- **DEP-004**: `TF_VAR_PROJECT` GitHub repository variable must be set — already required by `terraform-deploy.yml`.

## 5. Files

- **FILE-001**: [terraform/locals.tf](../terraform/locals.tf) — add `openclaw_backup_file_share_name` local.
- **FILE-002**: [terraform/variables.tf](../terraform/variables.tf) — add `openclaw_backup_share_quota_gb` variable.
- **FILE-003**: [terraform/storage.tf](../terraform/storage.tf) — add backup share and CAE storage resources.
- **FILE-004**: [terraform/containerapp.tf](../terraform/containerapp.tf) — add backup volume and volume mount.
- **FILE-005**: [scripts/backup-openclaw.sh](../scripts/backup-openclaw.sh) — new script (create).
- **FILE-006**: [.github/workflows/backup.yml](../.github/workflows/backup.yml) — new workflow (create).

## 6. Testing

- **TEST-001**: Run `backup-openclaw.sh dev` from the devcontainer shell after Terraform apply — confirm archive appears in Azure Files share (`az storage file list --share-name openclaw-backup ...`), `--verify` passes, retention output shows correct counts.
- **TEST-002**: Trigger `backup.yml` `workflow_dispatch` with `environment: dev` — confirm green run, archive in share, no ENOTTY / 429 errors.
- **TEST-003**: Seed 9 fake archive filenames into the backup share with dates spanning 12 weeks (covering the daily, weekly-keep, and weekly-delete zones), then run the prune function in isolation and verify only the correct files remain.
- **TEST-004**: Trigger `backup.yml` `workflow_dispatch` with `environment: both` — confirm both dev and prod jobs complete; confirm prod archive appears in prod storage account backup share.
- **TEST-005**: Confirm Container App revision after Terraform apply shows `/mnt/openclaw-backup` in revision's volume mount list (`az containerapp revision show ...`).

## 7. Risks & Assumptions

- **RISK-001**: `az containerapp exec` rate limit (5 sessions / 10 min). The backup uses 1 session. Combined with seed script (2 sessions), peak usage is 3 sessions — within the 5-session budget. If both workflows run simultaneously (unlikely given the 02:00 UTC schedule vs PR-triggered seed), a 429 will be logged and the backup job will fail. The next day's schedule will retry.
- **RISK-002**: Archive filename format. The docs show `2026-03-09T00-00-00.000Z-openclaw-backup.tar.gz`. The retention script parses the leading `YYYY-MM-DD` prefix with a regex. If OpenClaw changes its naming convention, the prune function will fail to parse dates and will skip deletion (safe-fail: no data is lost). An `az storage file list` check after pruning should be added to the workflow logs to surface unexpected filenames.
- **RISK-003**: Scale-to-zero. If `min_replicas = 0` and no user sessions are active, there may be no running replica when the 02:00 UTC backup fires. `az containerapp exec` will fail with a "no running replicas" error. Mitigation: the backup job uses `continue-on-error: false` so failure is visible; an operator can trigger a manual backup after the app is active. A future enhancement could set `min_replicas = 1` during the backup window via a separate scheduled action.
- **RISK-004**: Backup share quota. Default 10 GiB. A full backup of large workspace trees could exceed this. The `--only-config` fallback can be used if quota is hit. Monitor via Azure Metrics.
- **ASSUMPTION-001**: The OpenClaw CLI embedded in the container (`node /app/openclaw.mjs backup create`) supports the `--output`, `--verify`, and `--only-config` flags as documented. This was confirmed against the published docs at https://docs.openclaw.ai/cli/backup.
- **ASSUMPTION-002**: Archive dates embedded in filenames are in UTC, matching the `date -u` command used in retention calculations on the GitHub Actions runner.

## 8. Related Specifications / Further Reading

- [OpenClaw backup CLI reference](https://docs.openclaw.ai/cli/backup)
- [scripts/seed-openclaw-ci.sh](../scripts/seed-openclaw-ci.sh) — PTY exec pattern this feature follows
- [terraform/storage.tf](../terraform/storage.tf) — existing storage account and state share
- [terraform/containerapp.tf](../terraform/containerapp.tf) — existing volume mount pattern
- [.github/workflows/terraform-deploy.yml](../.github/workflows/terraform-deploy.yml) — GitHub Environment secret/variable pattern
