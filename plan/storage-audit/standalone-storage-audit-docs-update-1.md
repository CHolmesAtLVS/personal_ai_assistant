---
goal: Audit actual persistent storage config and remove stale NFS references from docs
plan_type: standalone
version: 1.0
date_created: 2026-04-19
owner: Platform Engineering
status: 'Deprecated'
tags: [chore, docs, architecture, storage, audit]
---

# Introduction

![Status: Deprecated](https://img.shields.io/badge/status-Deprecated-lightgrey)

> **Superseded by [`plan/backup-cleanup/standalone-backup-cleanup-docs-1.md`](../backup-cleanup/standalone-backup-cleanup-docs-1.md) (2026-04-20).**
> All tasks from this plan are incorporated into the backup-cleanup plan, which was fully implemented on the same date. No further action required here.

`storage-aks.tf` was removed on 2026-04-12 with the note *"NFS was never mounted — pods use managed-csi-premium"*. All `values.yaml` files confirm this (`storageClass: managed-csi-premium`, dynamically provisioned Azure Disk CSI). However, `ARCHITECTURE.md`, `PRODUCT.md`, `workloads/templates/crds/pv.yaml`, and the personal-setup plan all still describe NFS Azure Files shares as the live storage mechanism.

This plan audits the actual deployed storage configuration and corrects every stale reference.

---

## 1. Requirements & Constraints

- **REQ-001**: All documentation must reflect the storage mechanism that is actually deployed, not what was originally planned.
- **REQ-002**: No code or infrastructure changes — this plan is documentation-only (plus removing the stale PV template).
- **CON-001**: Do not execute commands against production resources. Verification commands target the `dev` environment only.
- **CON-002**: Do not delete the `pv.yaml` template file without first confirming it is not referenced by any active script or seed process.
- **GUD-001**: After editing `ARCHITECTURE.md` and `PRODUCT.md`, re-read both files in full to catch any remaining NFS mentions before marking complete.

---

## 2. Implementation Steps

### Phase 1 — Verify Actual Storage Configuration (dev)

- **GOAL-001**: Confirm from live cluster state what storage class, driver, and volume type each OpenClaw pod actually uses.

| Task     | Description                                                                                                                                                                                                                                                                                                     | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | Run `kubectl get pvc -A -o wide` on the dev cluster to list all PVCs across namespaces and confirm every openclaw PVC binds to `managed-csi-premium`. Record actual `STORAGECLASS` and `VOLUME` values.                                                                                                         |           |      |
| TASK-002 | Run `kubectl get pv -o wide` to list bound PVs and confirm they use `disk.csi.azure.com` (Azure Disk CSI) — not `file.csi.azure.com` (Azure Files/NFS).                                                                                                                                                        |           |      |
| TASK-003 | Run `kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.volumes[*]}{.name}{" "}{end}{"\n"}{end}'` and confirm no pod has a volume referencing an NFS PV or `file.csi.azure.com`.                                                                   |           |      |
| TASK-004 | Run `kubectl describe pvc -n openclaw data` (and equivalent for each instance namespace) to confirm `StorageClass: managed-csi-premium`, `VolumeMode: Filesystem`, mount path `/home/node/.openclaw`.                                                                                                            |           |      |
| TASK-005 | Check whether `workloads/templates/crds/pv.yaml` is applied by any active script: `grep -r "pv.yaml" scripts/`. If a script still seeds it, note which script before proceeding to Phase 2.                                                                                                                     |           |      |
| TASK-006 | Confirm `storage-aks.tf` does not exist in `terraform/`: `ls terraform/storage-aks.tf`. Confirm no `azurerm_storage_account` or `azurerm_storage_share` resource exists for NFS in any `.tf` file: `grep -r "nfs\|FileStorage\|storage_share" terraform/*.tf`.                                                  |           |      |
| TASK-007 | Confirm the `Storage Account Contributor` role assignment for the instance MI is absent or has been repurposed: `grep -r "Storage Account Contributor" terraform/*.tf`. Record whether the role assignment still exists and what scope it targets, or confirm it was removed with `storage-aks.tf`. |           |      |

---

### Phase 2 — Update `ARCHITECTURE.md`

- **GOAL-002**: Replace all NFS/FileStorage/azureFile references with the correct managed-csi-premium/Azure Disk CSI description.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                    | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-008 | **Line ~70 — Shared Infrastructure table**: Replace `"Premium FileStorage storage account: one storage account per environment; each instance gets a dedicated NFS share (openclaw-{instance}-nfs) mounted at /home/node/.openclaw in its pod."` with `"Azure Disk storage: each instance gets a dynamically provisioned Premium SSD PVC (managed-csi-premium, 10 Gi, ReadWriteOnce) mounted at /home/node/.openclaw in its pod."`.           |           |      |
| TASK-009 | **Line ~83 — Per-Instance Resources table**: Replace row `Azure Files NFS share \| openclaw-{inst}-nfs \| Persistent state isolated from other instances` with `Azure Disk PVC \| openclaw-{inst}-data \| Persistent state isolated from other instances; dynamically provisioned by managed-csi-premium`.                                                                                                                                     |           |      |
| TASK-010 | **Line ~92 — Per-Instance Resources table**: Remove or update the `Role: Storage Account Contributor` row based on TASK-007 findings. If the role assignment was removed with `storage-aks.tf`, delete the row. If it was repurposed, update the description accordingly.                                                                                                                                                                       |           |      |
| TASK-011 | **Line ~99 — OpenClaw Pod section**: Replace `"NFS share mounted at /home/node/.openclaw via PV/PVC backed by azureFile CSI driver"` with `"Persistent state mounted at /home/node/.openclaw via a dynamically provisioned PVC (storageClass: managed-csi-premium, disk.csi.azure.com, 10 Gi, ReadWriteOnce)"`.                                                                                                                               |           |      |
| TASK-012 | **Line ~118 — workloads directory listing**: Replace `"crds/ — PV for NFS share"` with `"crds/ — stale NFS PV template (no longer applied; see TASK-013)"`.  Then update again after TASK-014 resolves pv.yaml status.                                                                                                                                                                                                                        |           |      |
| TASK-013 | **Line ~131 — Environment resource group description**: Remove `"Premium storage account (NFS shares for all instances)"` from the resource group description. The storage account no longer exists.                                                                                                                                                                                                                                            |           |      |
| TASK-014 | **Line ~166 — Role assignments table**: Remove or update `Storage Account Contributor \| Premium NFS storage account \| NFS mount enumeration` row per TASK-007 findings.                                                                                                                                                                                                                                                                      |           |      |
| TASK-015 | **Line ~190-191 — Terraform resource table**: Remove rows `Premium Storage Account (FileStorage) \| azurerm_storage_account \| ...` and `Azure Files NFS share × N \| azurerm_storage_share \| ...`.                                                                                                                                                                                                                                          |           |      |
| TASK-016 | **Line ~219 — Deployment flow**: Replace `"Terraform provisions … NFS storage account, and for each instance in openclaw_instances: MI, OIDC federated credential, NFS share, Key Vault secret, and role assignments"` with `"Terraform provisions … and for each instance in openclaw_instances: MI, OIDC federated credential, Key Vault secret, and role assignments. Persistent storage PVCs are dynamically provisioned by Kubernetes."` |           |      |
| TASK-017 | **Line ~225 — Instance startup sequence**: Replace `"The NFS Azure Files share (openclaw-{inst}-nfs) is mounted at /home/node/.openclaw for each pod, restoring all persistent state."` with `"The dynamically provisioned Azure Disk PVC (managed-csi-premium) is mounted at /home/node/.openclaw for each pod, restoring all persistent state."`.                                                                                           |           |      |
| TASK-018 | Full-text search `ARCHITECTURE.md` for remaining occurrences of `nfs`, `NFS`, `FileStorage`, `azureFile`, `storage_share` and resolve each before marking this task complete.                                                                                                                                                                                                                                                                  |           |      |

---

### Phase 3 — Update `PRODUCT.md`

- **GOAL-003**: Remove the three NFS references from PRODUCT.md and replace with accurate storage description.

| Task     | Description                                                                                                                                                                                                                            | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-019 | **Line ~27 — Per-Instance User Model**: Replace `"stored in a dedicated Azure Files NFS share"` with `"stored on a dedicated Azure Disk volume (Premium SSD, per-instance PVC)"`.                                                      |           |      |
| TASK-020 | **Line ~141 — Deployment workflow step 3**: Replace `"per-instance namespaces, managed identities, NFS shares, Key Vault secrets, OIDC federation"` with `"per-instance namespaces, managed identities, Key Vault secrets, OIDC federation. Persistent storage is dynamically provisioned by Kubernetes (managed-csi-premium)."` |           |      |
| TASK-021 | **Line ~168 — Near-Term Roadmap item 1**: Replace `"per-instance DNS, gateway token, NFS share, and Managed Identity"` with `"per-instance DNS, gateway token, persistent disk, and Managed Identity"`.                               |           |      |

---

### Phase 4 — Update Personal Setup Guide

- **GOAL-004**: Correct the two NFS mentions in the personal setup guide that was created based on the stale docs.

| Task     | Description                                                                                                                                                                                                                                               | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-022 | In `plan/personal-setup/standalone-personal-assistant-setup-guide-1.md`: find all references to `NFS share`, `NFS volume`, or `NFS` and replace with `Azure Disk volume (Premium SSD PVC, mounted at /home/node/.openclaw)`.                              |           |      |
| TASK-023 | In the same file, update FILE-002 and FILE-003 descriptions if they mention NFS or note that config is on an NFS share. Replace with accurate description: `"openclaw.json is persisted to the pod's Azure Disk PVC at /home/node/.openclaw"`.    |           |      |

---

### Phase 5 — Resolve Stale `pv.yaml` Template

- **GOAL-005**: Either remove or clearly tombstone the stale NFS PV template so it cannot be accidentally applied.

| Task     | Description                                                                                                                                                                                                                                                                               | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-024 | Based on TASK-005 findings: if no active script references `pv.yaml`, add a prominent tombstone comment at the top of `workloads/templates/crds/pv.yaml`: `"DEPRECATED — NFS storage removed 2026-04-12. Storage-aks.tf was deleted; pods now use managed-csi-premium dynamic provisioning. Do not apply."` |           |      |
| TASK-025 | If TASK-005 found a script that still seeds `pv.yaml`, update that script to skip the NFS PV step and add a comment explaining the change. Identify the script and record its name here before proceeding.                                                                                 |           |      |

---

## 3. Alternatives

- **ALT-001**: Delete `pv.yaml` from the repo entirely instead of tombstoning it. Preferred only if no Git-history reason exists to keep it. Tombstoning is lower risk.
- **ALT-002**: Batch all doc edits in a single commit rather than one per file. Acceptable — just ensure all stale NFS mentions are gone before committing.

## 4. Dependencies

- **DEP-001**: Access to the dev AKS cluster (`az aks get-credentials`) to run Phase 1 verification commands.
- **DEP-002**: TASK-007 result (Storage Account Contributor role status) must be known before TASK-010 and TASK-014 can be completed accurately.
- **DEP-003**: TASK-005 result (pv.yaml script usage) must be known before Phase 5 can be determined.

## 5. Files

- **FILE-001**: `ARCHITECTURE.md` — 9 locations with stale NFS references (lines ~70, 83, 92, 99, 118, 131, 166, 190-191, 219, 225).
- **FILE-002**: `PRODUCT.md` — 3 locations with stale NFS references (lines ~27, 141, 168).
- **FILE-003**: `plan/personal-setup/standalone-personal-assistant-setup-guide-1.md` — NFS references in TASK-019, FILE-002/003 entries.
- **FILE-004**: `workloads/templates/crds/pv.yaml` — entire file describes defunct NFS PV; needs tombstone or deletion.
- **FILE-005**: `terraform/storage.tf` — already has correct tombstone comment; no changes needed.
- **FILE-006**: `workloads/dev/openclaw/values.yaml` (and all other `values.yaml` files) — already correct (`managed-csi-premium`); no changes needed.

## 6. Testing

- **TEST-001**: After all edits, `grep -ri "nfs\|fileStorage\|azureFile\|storage_share" ARCHITECTURE.md PRODUCT.md plan/personal-setup/` returns zero hits.
- **TEST-002**: `grep -ri "NFS" workloads/templates/crds/pv.yaml` returns only the tombstone/deprecation comment.
- **TEST-003**: `grep -r "pv.yaml\|nfs" scripts/*.sh` returns no live (non-commented) references.

## 7. Risks & Assumptions

- **RISK-001**: The `Storage Account Contributor` role assignment in Terraform may still exist even though NFS storage was removed (it might have been overlooked during cleanup). TASK-007 must verify this before TASK-010/TASK-014.
- **RISK-002**: If `seed-openclaw-aks.sh` still applies `pv.yaml`, deleting or tombstoning without updating the script would leave an unapplied but still-referenced file — address in TASK-025.
- **ASSUMPTION-001**: The root cause is that NFS was planned, infrastructure was partially written, `storage-aks.tf` was removed 2026-04-12 before NFS was ever mounted, and the docs were never retroactively updated.
- **ASSUMPTION-002**: `managed-csi-premium` (Azure Managed Disk, `disk.csi.azure.com`) is the correct storage mechanism for all instances in both dev and prod environments, as confirmed by all `values.yaml` files.

## 8. Related Specifications / Further Reading

- [ARCHITECTURE.md](../../ARCHITECTURE.md)
- [PRODUCT.md](../../PRODUCT.md)
- `terraform/storage.tf` tombstone comment (2026-04-12)
- `workloads/templates/crds/pv.yaml` — stale NFS PV template
- [plan/personal-setup/standalone-personal-assistant-setup-guide-1.md](../personal-setup/standalone-personal-assistant-setup-guide-1.md)
