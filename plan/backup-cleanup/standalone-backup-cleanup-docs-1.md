---
goal: Remove dead backup infrastructure, trim stale ACA scripts, and fix all NFS/sidecar/blob-export documentation errors
plan_type: standalone
version: 1.0
date_created: 2026-04-20
owner: Platform Engineering
status: 'Planned'
tags: [chore, docs, architecture, backup, storage, scripts, cleanup]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

Three independent changes left stale artifacts across the codebase:

1. **Sidecar removed** — `backup-openclaw.sh` was written for Azure Container Apps (`az containerapp exec`). ACA was decommissioned in dev on 2026-04-09. The script is dead.
2. **Blob export gone** — The ACA SMB storage account (and its `openclaw-backup` share) was removed on 2026-04-09 (`storage.tf`). There is nothing to export to.
3. **NFS never mounted** — `storage-aks.tf` was removed on 2026-04-12 with the explicit note *"NFS was never mounted — pods use managed-csi-premium"*. All `values.yaml` files confirm `storageClass: managed-csi-premium` (Azure Disk CSI, dynamically provisioned).

Despite these infrastructure changes, `PRODUCT.md` still describes backup as "Azure Files share snapshots and Blob export scheduled via Terraform or a container sidecar" and references "Azure Files NFS share" as the live storage. `ARCHITECTURE.md` has the same NFS errors. The backup GitHub Actions workflow and script remain in place and will fail if triggered. Several ACA-specific scripts in `scripts/` are either marked DEPRECATED or call `az containerapp exec`, which no longer works.

This plan supersedes [`../../plan/storage-audit/standalone-storage-audit-docs-update-1.md`](../../plan/storage-audit/standalone-storage-audit-docs-update-1.md), which is now deprecated — all tasks from that plan are incorporated here.

---

## 1. Requirements & Constraints

- **REQ-001**: All deleted scripts must be confirmed as having no active callers before deletion. Dead callers (e.g. workflow steps calling a deleted script) must be updated in the same PR.
- **REQ-002**: No infrastructure changes — this plan is docs and file cleanup only. Terraform is not touched.
- **REQ-003**: Each documentation fix must describe what is actually deployed (`managed-csi-premium` Azure Disk, dynamically provisioned), not what was planned (NFS).
- **REQ-004**: The PRODUCT.md backup roadmap item must be updated to describe the realistic planned approach (Azure Disk snapshot policy via Terraform), removing the obsolete sidecar and blob-export references.
- **SEC-001**: No secrets, tenant names, subscription IDs, or DNS identifiers may be introduced into any documentation.
- **CON-001**: Do not execute any verification commands against production. Dev cluster only.
- **CON-002**: Do not delete `workloads/templates/crds/pv.yaml` until TASK-005 confirms no active script still seeds it. If a caller exists, update the caller first.
- **GUD-001**: After editing `ARCHITECTURE.md` and `PRODUCT.md`, perform a full-text search for `nfs`, `NFS`, `FileStorage`, `azureFile`, `sidecar`, `blob export`, `backup share`, `openclaw-backup` and resolve every remaining hit before closing the phase.

---

## 2. Implementation Steps

### Phase 1 — Remove Dead Backup Infrastructure

- **GOAL-001**: Remove the backup script, its GitHub Actions workflow, and the dead `seed-openclaw-ci.sh` config-seed workflow step that targets a decommissioned ACA endpoint.

| Task     | Description                                                                                                                                                                                                                                                                                                                | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | Delete `scripts/backup-openclaw.sh`. The script uses `az containerapp exec` against an ACA app that no longer exists. The ACA SMB backup share it writes to was removed 2026-04-09. No replacement backup mechanism exists yet.                                                                                            |           |      |
| TASK-002 | Delete `.github/workflows/backup.yml`. It is the only caller of `backup-openclaw.sh`. Runs daily at 02:00 UTC and will fail on every scheduled execution until removed.                                                                                                                                                   |           |      |
| TASK-003 | In `.github/workflows/aks-bootstrap.yml`, remove the **"Seed OpenClaw Config"** step (and its comment) in **both** the `bootstrap-dev` and `bootstrap-prod` jobs. These steps call `scripts/seed-openclaw-ci.sh`, which is ACA-specific and non-functional on AKS. OpenClaw configuration is now managed via the Helm chart `values.yaml` ConfigMap and ArgoCD sync; no exec-based config seeding is required at bootstrap time. Paths: lines ~167–173 (dev job) and ~295–300 (prod job). |           |      |

---

### Phase 2 — Trim Dead ACA Scripts

- **GOAL-002**: Remove all ACA-specific scripts from `scripts/` that are either DEPRECATED (per their own header comments) or call `az containerapp exec`, and remove the generated data file that should not be committed.

| Task     | Description                                                                                                                                                                                                                                                                                                                                            | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-004 | Delete `scripts/diagnose-containerapp.sh`. The file header explicitly marks it as `DEPRECATED` (ACA decommissioned 2026-04-09). `docs/openclaw-aca-operations.md` and `CONTRIBUTING.md` both reference it; those references will be updated in Phase 3.                                                                                               |           |      |
| TASK-005 | Check whether `workloads/templates/crds/pv.yaml` is actively seeded: run `grep -r "pv.yaml" scripts/`. If any script still references `pv.yaml`, update that script to skip the NFS PV step before deleting or tombstoning the template (proceed to Phase 4 TASK-023 after this result is known).                                                     |           |      |
| TASK-006 | Delete `scripts/seed-openclaw-ci.sh`. The file uses `az containerapp exec` throughout. It was already removed from recommended usage; the AKS equivalent is `seed-openclaw-aks.sh`. References in `aks-bootstrap.yml` are removed in TASK-003.                                                                                                        |           |      |
| TASK-007 | Delete `scripts/seed-openclaw-config.sh`. The file header explicitly marks it as `DEPRECATED` (ACA decommissioned 2026-04-09). It uses `az containerapp exec`.                                                                                                                                                                                        |           |      |
| TASK-008 | Delete `scripts/state-migration-sub003.sh`. This was a one-time Terraform state migration script for the SUB-003 multi-instance for_each refactor. The migration is complete and the script has no ongoing purpose.                                                                                                                                    |           |      |
| TASK-009 | Delete `scripts/resource-inventory.csv`. This is a generated output data file (produced by `dump-resource-inventory.sh`). It records deployment-specific Azure resource names that must not be committed per project security rules. Add `scripts/*.csv` to `.gitignore` to prevent re-commit.                                                         |           |      |

---

### Phase 3 — Fix References to Removed Scripts

- **GOAL-003**: Ensure no committed file references a script that has been deleted. Update or remove each stale reference.

| Task     | Description                                                                                                                                                                                                                                                                                                                          | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-010 | In `docs/openclaw-aca-operations.md`, find all references to `diagnose-containerapp.sh`, `seed-openclaw-ci.sh`, and `seed-openclaw-config.sh`. Replace each occurrence with a note directing the reader to the equivalent AKS procedure: `kubectl logs`, `kubectl exec`, or `seed-openclaw-aks.sh`. The document is already marked DECOMMISSIONED at its top; the individual script references still appear in the Legacy (ACA) procedure sections within that document. |           |      |
| TASK-011 | Run `grep -r "backup-openclaw\|diagnose-containerapp\|seed-openclaw-ci\|seed-openclaw-config\|state-migration-sub003\|resource-inventory.csv" . --include="*.md" --include="*.yml" --include="*.yaml" --include="*.sh" --include="*.json"` (excluding `plan/` history). Resolve every hit not already addressed by TASK-003, TASK-010.  |           |      |

---

### Phase 4 — Fix NFS and Storage Documentation

- **GOAL-004**: Replace every NFS/Azure Files/FileStorage/azureFile reference in `ARCHITECTURE.md` with the correct managed-csi-premium/Azure Disk CSI description. Seven distinct locations require edits.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                    | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-012 | **ARCHITECTURE.md — Shared Infrastructure table** (line ~70): Replace `"Premium FileStorage storage account: one storage account per environment; each instance gets a dedicated NFS share (openclaw-{instance}-nfs) mounted at /home/node/.openclaw in its pod."` with `"Azure Disk storage: each instance gets a dynamically provisioned Premium SSD PVC (storageClass: managed-csi-premium, 10 Gi, ReadWriteOnce) mounted at /home/node/.openclaw."` |           |      |
| TASK-013 | **ARCHITECTURE.md — Per-Instance Resources table** (line ~83): Replace row `Azure Files NFS share \| openclaw-{inst}-nfs \| Persistent state isolated from other instances` with `Azure Disk PVC \| openclaw-{inst}-data (dynamic) \| Persistent state isolated per instance; provisioned by managed-csi-premium StorageClass`.                                                                                                |           |      |
| TASK-014 | **ARCHITECTURE.md — Per-Instance Resources table** (line ~92): Confirm via `grep -r "Storage Account Contributor" terraform/*.tf` whether the role assignment was removed with `storage-aks.tf`. If absent from Terraform, remove the `Role: Storage Account Contributor \| NFS storage account` row from the table. If still present, update it to reflect its actual current scope.                                          |           |      |
| TASK-015 | **ARCHITECTURE.md — OpenClaw Pod section** (line ~99): Replace `"NFS share mounted at /home/node/.openclaw via PV/PVC backed by azureFile CSI driver"` with `"Persistent state at /home/node/.openclaw via a dynamically provisioned PVC (storageClass: managed-csi-premium, disk.csi.azure.com, 10 Gi, ReadWriteOnce). No static PV is needed."`.                                                                             |           |      |
| TASK-016 | **ARCHITECTURE.md — Workloads directory listing** (line ~118): Replace `"crds/ — PV for NFS share"` with `"crds/ — Stale NFS PV template (not applied; NFS removed 2026-04-12; see pv.yaml tombstone in Phase 5)"`.                                                                                                                                                                                                          |           |      |
| TASK-017 | **ARCHITECTURE.md — Environment resource group description** (line ~131): Remove `"Premium storage account (NFS shares for all instances)"` from the prose description of what goes into the environment resource group.                                                                                                                                                                                                        |           |      |
| TASK-018 | **ARCHITECTURE.md — Managed Identity Role Assignments table** (line ~166): Remove or correct the `Storage Account Contributor \| Premium NFS storage account \| NFS mount enumeration` row per TASK-014 findings.                                                                                                                                                                                                              |           |      |
| TASK-019 | **ARCHITECTURE.md — Terraform resource table** (lines ~190–191): Remove both rows: `Premium Storage Account (FileStorage) \| azurerm_storage_account \| Shared; NFS protocol; one share per instance` and `Azure Files NFS share × N \| azurerm_storage_share \| Per instance: openclaw-{inst}-nfs; mounted at /home/node/.openclaw`.                                                                                         |           |      |
| TASK-020 | **ARCHITECTURE.md — Deployment flow step 3** (line ~219): Replace `"Terraform provisions … NFS storage account, and for each instance … NFS share, Key Vault secret, and role assignments"` with `"Terraform provisions … and for each instance in openclaw_instances: MI, OIDC federated credential, Key Vault secret, and role assignments. Persistent storage PVCs are dynamically provisioned by Kubernetes."`.           |           |      |
| TASK-021 | **ARCHITECTURE.md — Instance startup sequence step 9** (line ~225): Replace `"The NFS Azure Files share (openclaw-{inst}-nfs) is mounted at /home/node/.openclaw for each pod, restoring all persistent state."` with `"The dynamically provisioned Azure Disk PVC (managed-csi-premium) is mounted at /home/node/.openclaw for each pod, restoring all persistent state."`.                                                  |           |      |
| TASK-022 | Full-text search `ARCHITECTURE.md` for `nfs`, `NFS`, `FileStorage`, `azureFile`, `storage_share`, `openclaw-backup`. Resolve every remaining hit before marking this phase complete.                                                                                                                                                                                                                                          |           |      |

---

### Phase 5 — Fix Backup and Storage References in PRODUCT.md

- **GOAL-005**: Remove all NFS, sidecar, and blob-export references from `PRODUCT.md` and correct the backup roadmap entry to reflect the actual planned approach.

| Task     | Description                                                                                                                                                                                                                                                                                | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-023 | **PRODUCT.md — Per-Instance User Model** (line ~27): Replace `"stored in a dedicated Azure Files NFS share and are inaccessible to other instances"` with `"stored on a dedicated Azure Disk volume (Premium SSD PVC, per-instance) and are inaccessible to other instances"`.            |           |      |
| TASK-024 | **PRODUCT.md — Deployment workflow step 3** (line ~123): Replace `"per-instance namespaces, managed identities, NFS shares, Key Vault secrets, OIDC federation"` with `"per-instance namespaces, managed identities, Key Vault secrets, and OIDC federation. Persistent storage PVCs are dynamically provisioned by Kubernetes (managed-csi-premium)."` |           |      |
| TASK-025 | **PRODUCT.md — Ongoing Operation step 11** (line ~137): Update `"backed up automatically (once backup is implemented)"` to `"backed up via Azure Disk snapshot policy (planned)"`. This keeps backup honestly marked as future work without implying it is already active.                 |           |      |
| TASK-026 | **PRODUCT.md — Near-Term Roadmap item 2** (line ~152): Replace the entire item: `"**Automated backup** — Azure Files share snapshots and Blob export scheduled via Terraform or a container sidecar."` with `"**Automated backup** — Azure Disk snapshot policies configured via Terraform `azurerm_managed_disk_backup_policy_configuration` (or equivalent AKS backup add-on). Snapshots to target a Recovery Services vault or Azure Backup vault scoped to the environment resource group."` |           |      |
| TASK-027 | Full-text search `PRODUCT.md` for `nfs`, `NFS`, `sidecar`, `blob export`, `blob export`, `openclaw-backup`, `Azure Files`. Resolve every remaining hit.                                                                                                                                   |           |      |

---

### Phase 6 — Tombstone Stale pv.yaml Template

- **GOAL-006**: Prevent accidental application of the NFS PV template by tombstoning it.

| Task     | Description                                                                                                                                                                                                                                                                                               | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-028 | Based on TASK-005 result: if no active script seeds `workloads/templates/crds/pv.yaml`, replace the entire file content with a tombstone — a YAML comment block stating: `"DEPRECATED — NFS storage removed 2026-04-12. storage-aks.tf was deleted; pods now use managed-csi-premium dynamic provisioning. Do not apply this manifest. See ARCHITECTURE.md for current storage configuration."` |           |      |
| TASK-029 | If TASK-005 found a script that still seeds `pv.yaml`, update that script to skip the NFS PV step before tombstoning the template. Note the script name here before proceeding.                                                                                                                            |           |      |

---

### Phase 7 — Update Personal Setup Guide and Deprecate Storage-Audit Plan

- **GOAL-007**: Propagate storage corrections to downstream docs, and formally mark the now-superseded storage-audit plan as deprecated.

| Task     | Description                                                                                                                                                                                                                                                                                | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-030 | In `plan/personal-setup/standalone-personal-assistant-setup-guide-1.md`: find all references to `NFS share`, `NFS volume`, or `NFS` and replace with `Azure Disk volume (Premium SSD PVC, mounted at /home/node/.openclaw)`.                                                               |           |      |
| TASK-031 | In the same file: update any FILE-002/FILE-003 descriptions that mention storing config on an NFS share. Replace with: `"openclaw.json is persisted to the pod's Azure Disk PVC at /home/node/.openclaw"`.                                                                                 |           |      |
| TASK-032 | Update `plan/storage-audit/standalone-storage-audit-docs-update-1.md`: set `status: 'Deprecated'` in front matter, update the badge, and add a note at the top of the Introduction: `"Superseded by plan/backup-cleanup/standalone-backup-cleanup-docs-1.md. All tasks from this plan are incorporated there."` |           |      |

---

## 3. Alternatives

- **ALT-001**: Keep `backup-openclaw.sh` with a prominent DEPRECATED header (as done for `diagnose-containerapp.sh` and `seed-openclaw-config.sh`). Rejected — it is called by a live cron workflow that will fail every night. The script and workflow must be removed together so CI stays green.
- **ALT-002**: Rewrite `backup-openclaw.sh` for AKS using `kubectl exec`. Rejected — this plan's scope is cleanup only. A new backup implementation belongs in a separate feature plan once the approach (Azure Backup vault, snapshot policy, or sidecar) is decided.
- **ALT-003**: Mark the NFS doc errors with inline comments rather than correcting them. Rejected — stale docs cause implementation errors on the next instance addition.
- **ALT-004**: Merge the storage-audit plan work into this plan as a full "execute Phase 1 verification first" gate. Adopted — TASK-005 and TASK-014 are the verification gates; the rest of the doc edits proceed on the basis of confirmed knowledge from `storage.tf` and `values.yaml`.

---

## 4. Dependencies

- **DEP-001**: `.github/workflows/aks-bootstrap.yml` must have its `seed-openclaw-ci.sh` steps removed (TASK-003) before `seed-openclaw-ci.sh` itself is deleted (TASK-006) to avoid a broken workflow in the commit history.
- **DEP-002**: TASK-005 (check for `pv.yaml` callers) must be resolved before TASK-028 (tombstone `pv.yaml`) to avoid breaking an active seeding step.
- **DEP-003**: TASK-014 (confirm Storage Account Contributor removal in Terraform) must be resolved before TASK-018 (update the role assignments table) for accuracy.

---

## 5. Files

- **FILE-001**: `scripts/backup-openclaw.sh` — DELETE (ACA-specific, dead)
- **FILE-002**: `.github/workflows/backup.yml` — DELETE (calls deleted script; daily cron that fails)
- **FILE-003**: `scripts/diagnose-containerapp.sh` — DELETE (DEPRECATED header; ACA-specific)
- **FILE-004**: `scripts/seed-openclaw-ci.sh` — DELETE (ACA `az containerapp exec`; callers removed in TASK-003)
- **FILE-005**: `scripts/seed-openclaw-config.sh` — DELETE (DEPRECATED header; ACA-specific)
- **FILE-006**: `scripts/state-migration-sub003.sh` — DELETE (one-time state migration; complete)
- **FILE-007**: `scripts/resource-inventory.csv` — DELETE (generated data file; deployment identifiers; must not be committed)
- **FILE-008**: `PRODUCT.md` — UPDATE: remove NFS/sidecar/blob-export references; correct backup roadmap item
- **FILE-009**: `ARCHITECTURE.md` — UPDATE: replace seven separate NFS/Azure Files/FileStorage locations with managed-csi-premium/Azure Disk CSI description
- **FILE-010**: `docs/openclaw-aca-operations.md` — UPDATE: remove or replace references to deleted scripts within Legacy (ACA) sections
- **FILE-011**: `.github/workflows/aks-bootstrap.yml` — UPDATE: remove two dead `seed-openclaw-ci.sh` steps
- **FILE-012**: `workloads/templates/crds/pv.yaml` — TOMBSTONE: replace content with deprecation comment
- **FILE-013**: `plan/personal-setup/standalone-personal-assistant-setup-guide-1.md` — UPDATE: correct NFS references
- **FILE-014**: `plan/storage-audit/standalone-storage-audit-docs-update-1.md` — UPDATE: mark status as Deprecated; note superseded by this plan
- **FILE-015**: `.gitignore` — UPDATE: add `scripts/*.csv` to prevent re-commit of generated inventory files

---

## 6. Testing

- **TEST-001**: After TASK-003, run `grep -r "seed-openclaw-ci" .github/` — must return zero results.
- **TEST-002**: After TASK-001 and TASK-002, run `grep -r "backup-openclaw" .` (excluding `plan/`) — must return zero results outside of `plan/`.
- **TEST-003**: After all Phase 4 tasks, run `grep -in "nfs\|fileshare\|filstorage\|azurefile\|storage_share" ARCHITECTURE.md` — must return zero results.
- **TEST-004**: After all Phase 5 tasks, run `grep -in "nfs\|sidecar\|blob export\|openclaw-backup\|azure files" PRODUCT.md` — must return zero results.
- **TEST-005**: After TASK-009, run `git status scripts/` — `resource-inventory.csv` must not appear as a tracked file.
- **TEST-006**: After TASK-028/TASK-029, confirm `workloads/templates/crds/pv.yaml` either contains only a tombstone comment block or has been updated so no script seeds it with NFS parameters.
- **TEST-007**: Validate `.github/workflows/aks-bootstrap.yml` has no references to deleted scripts: `grep "seed-openclaw-ci\|backup-openclaw\|diagnose-containerapp" .github/workflows/aks-bootstrap.yml` — must return zero results.

---

## 7. Risks & Assumptions

- **RISK-001**: `aks-bootstrap.yml` has `continue-on-error: true` on the config-seed step, so removing it will not break the workflow's success gate. Validated by inspection.
- **RISK-002**: The `dump-resource-inventory.sh` script is kept (it is still referenced in `CONTRIBUTING.md` and has no ACA dependency), but the generated `resource-inventory.csv` it produces must never be committed. Adding `scripts/*.csv` to `.gitignore` mitigates re-commit risk.
- **RISK-003**: `openclaw-connect.sh` retains ACA fallback paths for `FQDN derivation steps 2 and 3` per its own header comment (pending prod ACA decommission). This script is explicitly NOT removed by this plan; it is functional for the AKS primary path and documents its own ACA fallback paths.
- **ASSUMPTION-001**: `managed-csi-premium` with `disk.csi.azure.com` is confirmed as the live storage driver from `storage.tf` comments and all `values.yaml` files. Phase 4 docs are updated on this basis without requiring live cluster verification.
- **ASSUMPTION-002**: The `Storage Account Contributor` role assignment was removed when `storage-aks.tf` was deleted. TASK-014 verifies this in Terraform source before the doc rows are removed.
- **ASSUMPTION-003**: No prod-only script is the sole caller of any deleted script. All callers have been identified from `grep` and `CONTRIBUTING.md` review.

---

## 8. Related Specifications / Further Reading

- [`../../plan/storage-audit/standalone-storage-audit-docs-update-1.md`](../../plan/storage-audit/standalone-storage-audit-docs-update-1.md) — Superseded by this plan
- [`../../ARCHITECTURE.md`](../../ARCHITECTURE.md) — Primary architecture reference; edited in Phase 4
- [`../../PRODUCT.md`](../../PRODUCT.md) — Product reference; edited in Phase 5
- [`storage.tf`](../../terraform/storage.tf) — Contains the canonical note: *"NFS storage (storage-aks.tf) removed 2026-04-12 — pods use managed-csi-premium; NFS was never mounted."*
