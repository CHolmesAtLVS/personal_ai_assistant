---
goal: Replace SMB state share with disk-backed EmptyDir + azcopy sidecar for POSIX-safe persistent state
plan_type: standalone
version: "2.0"
date_created: 2026-04-02
last_updated: 2026-04-02
owner: Platform Engineering
status: 'In progress'
tags: [feature, infrastructure, terraform, azure-container-apps, storage, sidecar, azcopy]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

OpenClaw's task registry emits `EPERM chmod` errors on every start because the Azure Files SMB share at `/home/node/.openclaw` does not support POSIX `chmod()`. This plan fixes that by replacing the SMB volume with a **disk-backed EmptyDir** (full POSIX semantics, node-local ephemeral disk storage) and adding a lightweight **azcopy sidecar** that uploads changes **event-driven** (within seconds of a detected write) with a full **60-minute reconciliation sync** as a belt-and-suspenders backstop. On cold start, an **init container** restores state from Blob → EmptyDir before OpenClaw starts.

This resolves the EPERM issue without requiring a VNet, NAT Gateway, Premium storage, or storage account recreation. The existing Standard LRS storage account gains a blob container alongside the backup file share. No networking infrastructure changes are needed.

**Supersedes:** the NFS-based approach for the EPERM fix. That approach required VNet + NAT Gateway (~$35–48/month additional cost) and is not being pursued.

**Companion plan reference:** Script changes in this plan (Phase 6) follow the same pattern originally scoped for the NFS migration.

---

## 1. Requirements & Constraints

- **REQ-001**: OpenClaw must write to a **disk-backed EmptyDir** volume at `/home/node/.openclaw`. In ACA's Consumption plan, `storage_type = "EmptyDir"` is always backed by the node's local ephemeral disk (not RAM/tmpfs) — it does not consume from the pod's memory allocation, and available capacity is up to 21 GiB. The azcopy sidecar syncs EmptyDir → Blob Storage **event-driven** (triggered within seconds of detected writes) with a full **60-minute reconciliation sync** as a backstop. No SMB or POSIX chmod-limited volume is mounted at that path.
- **REQ-002**: An **init container** must restore state from Blob → EmptyDir before the main OpenClaw container starts. ACA runs init containers to completion before starting main containers, so the ordering is guaranteed.
- **REQ-003**: The sidecar must authenticate to Blob Storage using the existing **Managed Identity** (`module.identity`) with `Storage Blob Data Contributor` role. No storage keys in the sidecar. Use `AZCOPY_AUTO_LOGIN_TYPE=MSI` and `AZCOPY_MSI_CLIENT_ID` env vars.
- **REQ-004**: The sidecar must trap **SIGTERM** and run a final `azcopy sync` before exiting, to minimise data loss when ACA scales to zero.
- **REQ-005**: The **backup share** (`openclaw-backup`, SMB, mounted at `/mnt/openclaw-backup`) is **unchanged**. `backup-openclaw.sh` writes archives via exec to `/tmp` inside the container and copies to the backup mount — this workflow still works with EmptyDir and requires no changes to the backup script.
- **REQ-006**: The sidecar image must use a **pinned, immutable tag**. `busybox:latest` or `:latest` tags are not permitted (project convention enforced by `openclaw_image_tag` variable validation).
- **REQ-007**: Total CPU and memory across **all** containers (including init container) in the pod must equal a valid ACA Consumption plan combination. The current openclaw allocation is 2 CPU / 4Gi which is the per-pod maximum. CPU/memory must be redistributed to accommodate the sidecar and init container.
- **REQ-008**: Sync direction is **one-way: EmptyDir → Blob** (outbound). Restore is **one-way: Blob → EmptyDir** (init container only). The sidecar never writes back from Blob to EmptyDir at runtime — OpenClaw is the only writer to EmptyDir.
- **REQ-009**: `azcopy sync` must use `--delete-destination=true` on the outbound sync so that files deleted from EmptyDir are also removed from Blob. Without this, deleted state accumulates and is wrongly restored on next cold start.
- **REQ-010**: Seed scripts (`seed-openclaw-config.sh`, `seed-openclaw-ci.sh`) and test scripts (`test-openclaw-config.sh`, `test-multi-model.sh`) currently use `az storage file` commands against the SMB state share, which will no longer exist after this change. These must be reworked before the state share is removed.
- **SEC-001**: The `Storage Blob Data Contributor` role must be scoped to the state blob **container** (not the storage account) to apply least-privilege.
- **SEC-002**: The blob container for state must have `container_access_type = "private"`. No anonymous access.
- **CON-001**: ACA Consumption plan CPU/memory combos are fixed pairs at 2.0 CPU / 4.0Gi per pod total. Reduce openclaw from 2.0/4.0Gi to 1.5/3.0Gi; sidecar 0.25/0.5Gi; init container 0.25/0.5Gi → total 2.0/4.0Gi (valid). Evaluate whether the openclaw reduction impacts performance before applying.
- **CON-002**: Init containers in ACA share the EmptyDir volume with main containers. The init container must `chmod -R 700 /data && chown -R 1000:1000 /data` after the restore. This is the one place where `chmod` is intentional and works — EmptyDir is backed by local node disk, not a network protocol.
- **CON-003**: The SMB state share (`openclaw-state`) must not be destroyed in Terraform until state has been confirmed in Blob Storage and the new revision is running healthy. A `lifecycle { prevent_destroy = true }` block protects it during the transition.
- **CON-004**: All changes must target the dev environment only. Do not apply to production resources.
- **CON-005**: `az containerapp exec` is rate-limited at ~5 sessions per 10 minutes. Script rework must not increase the per-invocation exec session budget beyond existing limits.
- **CON-006**: The event-driven sync loop uses a **`find -newer` marker file** (`/tmp/.last_sync`) for change detection. The marker is a zero-byte file in `/tmp`; after every successful sync, the marker's mtime is updated with `touch`. A 5-second polling interval checks for new or modified files under `/data` newer than the marker. The `.azcopy/` job directory inside `/data` is excluded from change detection to prevent sync loops. This approach requires no `inotify-tools` package and works with the stock azcopy MCR image.

---

## 2. Implementation Steps

### Implementation Phase 1 — Pre-flight: image, resource sizing, and azcopy validation

- GOAL-001: Confirm the azcopy image version, validate Consumption plan resource maths, and verify Managed Identity blob authentication before writing any Terraform.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                              | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | **Pin the azcopy sidecar image.** Browse `mcr.microsoft.com/azure-storage/azcopy` tags to identify the latest stable azcopy version. Record the exact pinned image tag (e.g. `mcr.microsoft.com/azure-storage/azcopy:10.x.y`). This tag will be used in Terraform as the sidecar and init container `image` value. Do not use `:latest`. | ✅ | 2026-04-02 |
| TASK-002 | **Confirm ACA init container resource accounting.** Verify via [ACA init container docs](https://learn.microsoft.com/en-us/azure/container-apps/init-containers) whether init container CPU/memory counts against the pod resource total simultaneously with main containers or is additive-but-sequential. Document the confirmed behaviour as a comment on TASK-003. | ✅ | 2026-04-02 |
| TASK-003 | **Determine new per-container CPU/memory allocations.** Based on TASK-002: (a) If init container counts simultaneously: `openclaw = 1.5/3.0Gi`, sidecar `= 0.25/0.5Gi`, init `= 0.25/0.5Gi` → total 2.0/4.0Gi. (b) If sequential: `openclaw = 1.75/3.5Gi`, sidecar `= 0.25/0.5Gi` → total 2.0/4.0Gi. Record the chosen allocation; it must equal a valid [ACA Consumption plan pair](https://learn.microsoft.com/en-us/azure/container-apps/containers#allocations) before proceeding. | ✅ | 2026-04-02 |

**TASK-002/003 Finding:** Init containers count simultaneously toward the pod total in Consumption-only environments. **Also found:** MSI cannot be used in init containers in Consumption-only ACA environments (ACA platform restriction). The init container uses the storage account key (Key Vault secret ref) for azcopy auth — ASSUMPTION-001 fallback. Chosen allocation: openclaw 1.5/3.0Gi + sidecar 0.25/0.5Gi + init 0.25/0.5Gi = 2.0/4.0Gi ✓
| TASK-004 | **Validate Managed Identity azcopy auth against dev blob storage.** Before adding the sidecar, confirm azcopy MSI auth works by running a one-off test from within the existing dev container (`az containerapp exec` on dev): `export AZCOPY_AUTO_LOGIN_TYPE=MSI && export AZCOPY_MSI_CLIENT_ID=<mi-client-id> && azcopy list "https://<account>.blob.core.windows.net/<test-container>/"`. If azcopy is not present in the current image, mark as blocked — validation will happen in TASK-016 after the new revision is deployed. | ⏭️ SKIPPED | 2026-04-02 |

**TASK-004 Finding:** azcopy is not in the current openclaw image. MSI auth for the sidecar will be validated in TASK-016 after the new revision is deployed. MSI is NOT available for init containers in Consumption-only environments — storage account key (KV secret ref) used instead.

### Implementation Phase 2 — Terraform: Blob Storage and role assignment

- GOAL-002: Add the Blob Storage container for state persistence and grant the Managed Identity the required role. No changes to the Container App yet.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                        | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-005 | **Add blob container to `terraform/storage.tf`.** Add `azurerm_storage_container.openclaw_state_blob` to the existing `azurerm_storage_account.openclaw_state` resource (Standard LRS — no account changes needed). Set `name = "openclaw-state"`, `container_access_type = "private"`. Add `lifecycle { prevent_destroy = true }`. | ✅ | 2026-04-02 |
| TASK-006 | **Add local for blob URL to `terraform/locals.tf`.** Add: `openclaw_state_blob_url = "https://${local.openclaw_state_storage_account_name}.blob.core.windows.net/openclaw-state/"`. This will be injected as an env var into the sidecar and init container. | ✅ | 2026-04-02 |
| TASK-007 | **Add `Storage Blob Data Contributor` role assignment to `terraform/roleassignments.tf`.** Add `azurerm_role_assignment.mi_state_blob_contributor` scoped to `azurerm_storage_container.openclaw_state_blob.resource_manager_id`. Set `role_definition_name = "Storage Blob Data Contributor"` and `principal_id = module.identity.principal_id`. | ✅ | 2026-04-02 |

**TASK-007 Note:** `resource_manager_id` is deprecated in the azurerm provider; `.id` is used instead (same ARM resource ID semantics). | | |
| TASK-008 | **Add `lifecycle { prevent_destroy = true }` to `azurerm_storage_share.openclaw_state`** in `terraform/storage.tf`. This protects the existing SMB state share from accidental destruction during the transition period. The guard will be removed in Phase 7. | ✅ | 2026-04-02 |
| TASK-009 | **Run `terraform plan` (storage + role only), review, and apply to dev.** Target: `-target=azurerm_storage_container.openclaw_state_blob -target=azurerm_role_assignment.mi_state_blob_contributor`. Confirm no unexpected changes to existing resources. Apply. | | |

### Implementation Phase 3 — One-time data migration: SMB → Blob

- GOAL-003: Copy current gateway state from the SMB state share to the new Blob container before switching the container app volume.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                      | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-010 | **Run `scripts/backup-openclaw.sh dev`** and confirm the backup archive passes verification. This is the safety snapshot before any storage changes. Do not proceed if backup verification fails. | | |
| TASK-011 | **Migrate state from SMB share to Blob Storage.** From inside the running dev container (`az containerapp exec`), run: `azcopy sync /home/node/.openclaw/ "https://<account>.blob.core.windows.net/openclaw-state/" --recursive --delete-destination=true`. Confirm exit 0 and no transfer errors. Verify with `azcopy list "https://<account>.blob.core.windows.net/openclaw-state/"` that expected top-level directories are present (e.g. `conversations/`, `devices/`, `config/`). Set `AZCOPY_AUTO_LOGIN_TYPE=MSI` and `AZCOPY_MSI_CLIENT_ID` in the exec session. If azcopy is not in the current image, use `az storage blob upload-batch` with the storage account key as a one-time migration alternative. | | |

### Implementation Phase 4 — Terraform: Container App template update

- GOAL-004: Update the Container App to use disk-backed EmptyDir for state, add the init container and azcopy sidecar, and remove the ACA environment storage binding for the state share.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-012 | **Update `terraform/containerapp.tf` — volumes block.** Replace the `openclaw-state` AzureFile volume with a disk-backed EmptyDir volume: `{ name = "openclaw-data", storage_type = "EmptyDir" }`. Keep the `openclaw-backup` AzureFile volume unchanged. Remove `azurerm_container_app_environment_storage.openclaw_state` from `depends_on`. | ✅ | 2026-04-02 |
| TASK-013 | **Update `terraform/containerapp.tf` — openclaw container.** Change the `openclaw-state` volume mount `name` to `"openclaw-data"` (path `/home/node/.openclaw` unchanged). Update `cpu` and `memory` to the values confirmed in TASK-003. | ✅ | 2026-04-02 |
| TASK-014 | **Update `terraform/containerapp.tf` — add init container.** Add an `init_container` block: `name = "state-restore"`, `image = "mcr.microsoft.com/azure-storage/azcopy:10.32.2"`, `cpu = 0.25`, `memory = "0.5Gi"`. Volume mount: `openclaw-data` at `/data`. Command: `["/bin/sh", "-c"]`. Args (single string): `set -e; azcopy sync "$BLOB_URL" /data/ --recursive || echo "Restore failed — starting with empty state"; chmod -R 700 /data; chown -R 1000:1000 /data; echo "State restore complete."`. Env vars: `AZCOPY_AUTO_LOGIN_TYPE = "MSI"`, `AZCOPY_MSI_CLIENT_ID = module.identity.client_id`, `BLOB_URL = local.openclaw_state_blob_url`. Note: `|| echo` on the restore command ensures the init container exits 0 even on a failed restore rather than blocking startup indefinitely (RISK-003). | ✅ | 2026-04-02 |

**TASK-014 Implementation note:** MSI cannot be used in init containers in Consumption-only ACA environments. The init container uses `STORAGE_ACCOUNT_KEY` (from Key Vault secret `openclaw-state-storage-key`) and `azcopy sync --account-key` instead. A new `azurerm_key_vault_secret.openclaw_state_storage_key` resource was added to `terraform/keyvault.tf`. BLOB_URL env var is passed for the source path.
| TASK-015 | **Update `terraform/containerapp.tf` — add azcopy sidecar container.** Add a second entry to the `containers` list: `name = "state-sync"`, `image = "mcr.microsoft.com/azure-storage/azcopy:10.32.2"`, `cpu = 0.25`, `memory = "0.5Gi"`. Volume mount: `openclaw-data` at `/data`. Command: `["/bin/sh", "-c"]`. Args (single string implementing event-driven sync with 60-min reconciliation)... Env vars: `AZCOPY_AUTO_LOGIN_TYPE = "MSI"`, `AZCOPY_MSI_CLIENT_ID = module.identity.client_id`, `BLOB_URL = local.openclaw_state_blob_url`. | ✅ | 2026-04-02 |
| TASK-016 | **Run `terraform plan` (full), review, and apply to dev.** Expected changes: (a) volume `openclaw-state` replaced with EmptyDir `openclaw-data`; (b) init container added; (c) sidecar container added; (d) openclaw container CPU/memory changed; (e) `azurerm_container_app_environment_storage.openclaw_state` removed from the container app. Confirm no changes to ingress, secrets, or identity. Apply. | | |

### Implementation Phase 5 — Validation

- GOAL-005: Confirm the new architecture is working correctly: EPERM resolved, state persistence across restarts, sync operating correctly.

| Task     | Description                                                                                                                                                                                                                                                                             | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-017 | **Confirm init container ran and state was restored.** After the new revision starts, exec into the openclaw container: `ls -la /home/node/.openclaw/`. Confirm the directory contains the expected state layout matching the SMB share contents pre-migration. | | |
| TASK-018 | **Confirm EPERM is resolved.** Inside the container, run `chmod 700 /home/node/.openclaw/tasks` and confirm it exits 0. Check `openclaw logs` — the `EPERM chmod /home/node/.openclaw/tasks` warning must be absent. | | |
| TASK-019 | **Confirm azcopy sidecar is syncing (event-driven).** Create a test file: `echo test > /home/node/.openclaw/sync-test-$(date +%s).txt`. Wait 10 seconds (sidecar polls every 5s), then check Blob: `az storage blob list --account-name <account> --container-name openclaw-state --query "[?contains(name,'sync-test')]" -o table`. The file must appear within 10 seconds. If absent within 60 seconds, check sidecar container logs. | | |
| TASK-020 | **Test cold-start restore.** Scale to zero (`az containerapp update --min-replicas 0 --max-replicas 0` on dev), wait for termination, scale back to 1. After init container completes and openclaw starts, exec in and confirm the test file from TASK-019 is present at `/home/node/.openclaw/`. | | |
| TASK-021 | **Run `openclaw doctor`** and confirm no errors or warnings (beyond remaining non-EPERM warnings tracked in `fix-gateway-warnings-1.md`). | | |
| TASK-022 | **Run LLM smoke test.** Execute `scripts/test-multi-model.sh dev` (after script rework from Phase 6) and confirm a successful model response. | | |

### Implementation Phase 6 — Script rework

- GOAL-006: Remove `az storage file` dependencies on the state share from seeding and test scripts.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                               | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-023 | **Update `scripts/seed-openclaw-config.sh` and `scripts/seed-openclaw-ci.sh`.** Change `SHARE_NAME` from `"openclaw-state"` to `"openclaw-backup"`. Change `CONTAINER_PATH` from `"/home/node/.openclaw/.seed/seed.batch.json"` to `"/mnt/openclaw-backup/.seed/seed.batch.json"`. The backup share (SMB) accepts `az storage file upload`; the container has the backup mount at `/mnt/openclaw-backup`. Update script header comments to document the staging location change and explain that the state share is no longer accessible via the Azure Files REST API. | | |
| TASK-024 | **Update `scripts/test-openclaw-config.sh` and `scripts/test-multi-model.sh`.** Replace `az storage file download` calls that read `openclaw.json` from the state share with `az containerapp exec` running `node /app/openclaw.mjs config get --output json` and capturing stdout to a temp file. Update header comments. | ✅ | 2026-04-02 |

**TASK-024 Additional:** Inner test script in test-multi-model.sh updated to stage on backup share (`openclaw-backup`) and exec path updated from `/home/node/.openclaw/` to `/mnt/openclaw-backup/`. `SHARE_NAME` variable updated in both test scripts.
| TASK-025 | **Validate seed scripts against dev.** Run `bash scripts/seed-openclaw-config.sh dev` end-to-end. Confirm the batch stages to the backup share, applies via exec, and validates via exec. `openclaw config validate` must pass. | | |
| TASK-026 | **Validate test scripts against dev.** Run `bash scripts/test-openclaw-config.sh dev` and `bash scripts/test-multi-model.sh dev`. Confirm both complete successfully with no `az storage file` errors. | | |

### Implementation Phase 7 — Cleanup: remove SMB state share

- GOAL-007: Remove the now-unused SMB state share and its ACA environment storage binding after validation is complete.

| Task     | Description                                                                                                                                                                                                                                                                                                         | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-027 | **Remove `lifecycle { prevent_destroy = true }` from `azurerm_storage_share.openclaw_state`** in `terraform/storage.tf`. Remove the `azurerm_storage_share.openclaw_state` and `azurerm_container_app_environment_storage.openclaw_state` resources entirely. | | |
| TASK-028 | **Remove `openclaw_state_share_quota_gb` variable** from `terraform/variables.tf`. Remove `openclaw_state_file_share_name` local from `terraform/locals.tf` — no longer needed. | | |
| TASK-029 | **Run `terraform plan` (cleanup), review, and apply.** Expected: `azurerm_storage_share.openclaw_state` and `azurerm_container_app_environment_storage.openclaw_state` are destroyed. No other changes. Confirm with a second `terraform plan` immediately after apply (must show clean output). | | |
| TASK-030 | **Update `docs/baseline-configuration.md`** to document: (a) state is persisted via disk-backed EmptyDir + azcopy sidecar to Blob Storage; (b) backup share remains SMB at `/mnt/openclaw-backup`; (c) seed scripts stage on the backup share; (d) EPERM warning is resolved. | | |

---

## 3. Alternatives

- **ALT-001**: Use **NFS Azure Files** instead of the sidecar. Provides synchronous POSIX-correct persistence without data loss risk. Requires VNet, NAT Gateway (~$35–48/month additional), Premium FileStorage account recreation, and full script rework. Rejected for cost and complexity; no active plan exists.
- **ALT-002**: Use **rsync instead of azcopy** for sync. rsync writing to the SMB backup share would trigger the same EPERM if `--archive` mode is used (calls `chmod()` on dest). With `--no-perms`, rsync to SMB works but loses blob's superior metadata handling and cost profile. Rejected in favour of azcopy + blob.
- **ALT-003**: Use **Azure File Sync** (Microsoft managed service) for SMB → blob tiering. Adds managed service dependency; increases complexity with no advantage for this use case.
- **ALT-004**: Use **emptyDir for `/home/node/.openclaw/tasks` only**, keeping SMB for the rest of state. Targeted fix that avoids any sidecar, storage, or script changes. Acceptable if the EPERM warning is benign and task persistence is unimportant. Rejected as primary because it changes the data durability contract for tasks.
- **ALT-005**: Use **Dedicated workload profile** instead of reducing openclaw CPU/memory. Avoids any performance impact from reducing openclaw from 2/4Gi to 1.5/3.0Gi. Adds cost (~$0.10/vCPU/hr) but removes Consumption plan resource constraints. Evaluate as an upgrade if TASK-003 determines the openclaw reduction is a concern.

---

## 4. Dependencies

- **DEP-001**: TASK-002 (init container resource accounting) must complete before TASK-003 (resource sizing) — the allocation maths depend on whether init containers count simultaneously.
- **DEP-002**: TASK-009 (blob container and role assignment applied) must complete before TASK-011 (data migration) — the blob container must exist before azcopy can write to it.
- **DEP-003**: TASK-010 (backup) must complete before TASK-011 (migration) and TASK-016 (container app apply) — the backup is the safety net.
- **DEP-004**: TASK-016 (container app apply) must complete before TASK-017–TASK-022 (validation tasks).
- **DEP-005**: TASK-023–TASK-026 (script rework and validation) must complete before TASK-027–TASK-029 (state share removal) — scripts must work post-migration before the old share is destroyed.
- **DEP-006**: TASK-001 (pin azcopy image tag) must complete before TASK-014 and TASK-015 (init container and sidecar Terraform blocks) — the image value is required for both.

---

## 5. Files

- **FILE-001**: `terraform/storage.tf` — add `azurerm_storage_container.openclaw_state_blob`; add `lifecycle { prevent_destroy = true }` to `azurerm_storage_share.openclaw_state` (transition); remove state share and CAE storage binding in Phase 7.
- **FILE-002**: `terraform/locals.tf` — add `openclaw_state_blob_url` local.
- **FILE-003**: `terraform/roleassignments.tf` — add `azurerm_role_assignment.mi_state_blob_contributor`.
- **FILE-004**: `terraform/containerapp.tf` — replace AzureFile state volume with disk-backed EmptyDir; add init container; add sidecar container; update openclaw CPU/memory; add `termination_grace_period_seconds = 30`.
- **FILE-005**: `terraform/variables.tf` — remove `openclaw_state_share_quota_gb` (Phase 7).
- **FILE-006**: `scripts/seed-openclaw-config.sh` — `SHARE_NAME` and `CONTAINER_PATH` updated to use backup share staging.
- **FILE-007**: `scripts/seed-openclaw-ci.sh` — same changes as FILE-006.
- **FILE-008**: `scripts/test-openclaw-config.sh` — `az storage file download` replaced with exec-based config read.
- **FILE-009**: `scripts/test-multi-model.sh` — same change as FILE-008.
- **FILE-010**: `docs/baseline-configuration.md` — updated to document new state persistence architecture.
- **FILE-011**: `scripts/backup-openclaw.sh` — **no changes required**. Reads from `/home/node/.openclaw` (EmptyDir, unchanged from the app's perspective) and writes archives to `/mnt/openclaw-backup` (SMB, unchanged).

---

## 6. Testing

- **TEST-001**: `chmod 700 /home/node/.openclaw/tasks` exits 0 inside the container after new revision is deployed (TASK-018). Root cause validation.
- **TEST-002**: No `EPERM chmod` or `Failed to restore task registry` lines in `openclaw logs` after gateway start (TASK-018).
- **TEST-003**: Sync file appears in Blob Storage within 10 seconds of creation (TASK-019). Validates event-driven outbound sync.
- **TEST-004**: Cold-start restore — test file present after scale-to-zero and scale-back-to-one (TASK-020). Validates init container restore.
- **TEST-005**: `scripts/seed-openclaw-config.sh dev` completes successfully after rework (TASK-025).
- **TEST-006**: `scripts/test-multi-model.sh dev` completes successfully after rework (TASK-026).
- **TEST-007**: `scripts/backup-openclaw.sh dev` completes successfully without changes (implicit — backup reads EmptyDir just as it read SMB).
- **TEST-008**: Second `terraform plan` after Phase 7 cleanup apply shows clean output (no drift).
- **TEST-009**: `openclaw doctor` reports no issues (TASK-021).

---

## 7. Risks & Assumptions

- **RISK-001**: **Data loss window at scale-to-zero.** With event-driven sync, the maximum data loss window is the time between the last write and next sidecar poll (up to 5 seconds), plus azcopy upload time. The `sleep $POLL_INTERVAL & wait $!` pattern ensures SIGTERM is delivered promptly to the shell (not deferred behind a foreground sleep). Add `termination_grace_period_seconds = 30` to the container app template to give the final sync time to complete. At 5-second poll intervals, the typical data loss window is < 10 seconds in a clean shutdown.
- **RISK-002**: **Sidecar failure is silent.** If the azcopy sidecar crashes (OOM, MSI auth error), OpenClaw continues running and writing to EmptyDir — but changes are no longer being persisted. The gateway appears healthy but state is silently not being committed. Consider adding a liveness probe to the sidecar (e.g. `exec` checking a heartbeat file updated each sync cycle). Document the monitoring gap.
- **RISK-003**: **Init container failure blocks startup.** If azcopy restore fails (auth error, blob unreachable), the init container exits non-zero, ACA retries, and the main container never starts. Mitigation: the `|| echo` pattern in TASK-014 ensures the init container exits 0 even on a failed restore, degrading gracefully to starting with empty state rather than blocking indefinitely. Log the failure clearly.
- **RISK-004**: **openclaw CPU/memory reduction (1.5/3.0Gi) may impact performance.** OpenClaw is currently at 2.0/4.0Gi. If LLM responses are slower or OOM kills occur after the reduction, upgrade to a Dedicated workload profile (ALT-005) or reduce sidecar to 0.125/0.25Gi and openclaw to 1.75/3.5Gi.
- **RISK-005**: **`azcopy sync --delete-destination=true` with a misconfigured source path could delete all state from Blob.** Validate `BLOB_URL` and source path in TASK-011 before any sidecar-initiated syncs. The `lifecycle { prevent_destroy = true }` on the blob container prevents accidental TF-level deletion.
- **RISK-006**: **Blob Storage transaction costs.** azcopy only syncs when changes are detected (event-driven) or every 60 minutes. A quiet gateway triggers at most 24 reconciliation syncs/day. Estimated cost: < $0.10/month at Standard LRS pricing. Monitor via the budget alert.
- **ASSUMPTION-001**: azcopy MSI authentication works from within the ACA container using `AZCOPY_AUTO_LOGIN_TYPE=MSI` and `AZCOPY_MSI_CLIENT_ID`. Fallback: inject the storage account key via Key Vault secret ref (same pattern as `AZURE_AI_API_KEY`).
- **ASSUMPTION-002**: The OpenClaw process runs as UID 1000 inside the container. The `chown -R 1000:1000 /data` in the init container restores ownership after the restore.
- **ASSUMPTION-003**: `backup-openclaw.sh` needs no changes — it reads from `/home/node/.openclaw` (EmptyDir, still the same container-local path) and writes archives to `/mnt/openclaw-backup`. The exec-based PTY wrapper and archive copy flow are unaffected.

---

## 8. Related Specifications / Further Reading

- [plan/fix-gateway-warnings-1.md](fix-gateway-warnings-1.md) — parent warning tracker; Phase 2 (EPERM) is addressed by this plan
- [terraform/containerapp.tf](../terraform/containerapp.tf) — current container app definition
- [terraform/storage.tf](../terraform/storage.tf) — current storage account and shares
- [terraform/roleassignments.tf](../terraform/roleassignments.tf) — current role assignments
- [scripts/backup-openclaw.sh](../scripts/backup-openclaw.sh) — backup script (no changes)
- [scripts/seed-openclaw-config.sh](../scripts/seed-openclaw-config.sh) — seeding script (Phase 6)
- [ACA init containers](https://learn.microsoft.com/en-us/azure/container-apps/init-containers)
- [azcopy MSI authentication](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-authorize-azure-active-directory)
- [ACA Consumption plan resource allocations](https://learn.microsoft.com/en-us/azure/container-apps/containers#allocations)
