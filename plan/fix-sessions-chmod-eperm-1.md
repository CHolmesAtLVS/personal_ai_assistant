---
goal: Fix EPERM chmod error on sessions.json — overlay sessions path with EmptyDir volume
plan_type: standalone
version: 1.0
date_created: 2026-03-31
owner: Platform Engineering
status: 'Planned'
tags: [bug, terraform, containerapp, storage, openclaw, sessions]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

OpenClaw reports `Error: EPERM: operation not permitted, chmod '/home/node/.openclaw/agents/main/sessions/sessions.json'` at startup. The root cause is that `/home/node/.openclaw` is mounted from an **Azure Files SMB share**, and the Linux CIFS/SMB kernel driver does not support POSIX `chmod()` — any attempt returns `EPERM` regardless of file ownership.

The fix is to overlay only the `sessions/` subdirectory with an `EmptyDir` volume, which uses the container's local ephemeral storage and fully supports POSIX permission calls. Sessions are transient by nature (they track in-progress conversations), so losing them on container restart is acceptable and expected behaviour.

No Dockerfile or application changes are required — this is a pure Terraform change.

---

## 1. Requirements & Constraints

- **REQ-001**: The fix must not disrupt persistence of durable state (agent config, memory, openclaw.json) stored under `/home/node/.openclaw` on the Azure Files share.
- **REQ-002**: Sessions are treated as ephemeral — loss on container restart is acceptable and must be documented.
- **REQ-003**: All infrastructure changes must be expressed in Terraform. No manual Azure portal changes.
- **CON-001**: The Azure Files share (`Standard LRS`, SMB protocol) cannot support `chmod()` — this is a kernel-level CIFS limitation and cannot be configured away.
- **CON-002**: Container Apps (ACA) does not support Azure Disk mounts natively; the available volume types are `AzureFile`, `EmptyDir`, `Secret`, and `Nfs`.
- **CON-003**: Switching the entire share to NFS would require a Premium storage account and VNet integration for the Container Apps Environment — both are out of scope for this fix.
- **GUD-001**: Target the dev environment only during validation; do not apply to production until dev is verified stable.
- **SEC-001**: EmptyDir volumes are node-local and not encrypted at rest by default in ACA; sessions must not contain secrets that are not already protected by other mechanisms (gateway token, TLS). This is acceptable — sessions contain conversation context, not credentials.

---

## 2. Implementation Steps

### Implementation Phase 1 — Terraform: Add EmptyDir sessions volume

- GOAL-001: Declare a new `EmptyDir` volume named `sessions-ephemeral` and mount it at `/home/node/.openclaw/agents/main/sessions` inside the openclaw container. This overlays the SMB-backed path at that exact sub-path with ephemeral storage that supports `chmod()`.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-001 | In `terraform/containerapp.tf`, add a new entry to `template.volumes`: `{ name = "sessions-ephemeral", storage_type = "EmptyDir" }`. Place it immediately after the existing `openclaw-state` volume entry. | | |
| TASK-002 | In the same file, add a new entry to `template.containers[openclaw].volume_mounts`: `{ name = "sessions-ephemeral", path = "/home/node/.openclaw/agents/main/sessions" }`. Place it immediately after the existing `openclaw-state` volume mount. | | |
| TASK-003 | Run `terraform fmt terraform/containerapp.tf` to normalise formatting. | | |
| TASK-004 | Run `terraform validate` in the `terraform/` directory to confirm the HCL is syntactically valid. | | |

### Implementation Phase 2 — Plan and apply to dev

- GOAL-002: Apply the Terraform change to the dev environment and verify the EPERM error is resolved.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-005 | Run `terraform plan` against the dev backend (`backend.dev.hcl`) and confirm the plan shows only one resource updated: the Container App (revision replacement). No storage resources should be destroyed or recreated. | | |
| TASK-006 | Run `terraform apply` against dev. Confirm the new revision deploys successfully and the container reaches `Running` state. | | |
| TASK-007 | Run `openclaw doctor --non-interactive` via the local CLI (after re-running `source <(./scripts/openclaw-connect.sh dev --export)`) and confirm no EPERM errors appear in the output. | | |
| TASK-008 | Run `openclaw agents status` and confirm the sessions path is accessible and `sessions.json` is initialised without errors. | | |

### Implementation Phase 3 — Documentation

- GOAL-003: Record the fix and the known limitation of the SMB-backed mount so future engineers understand why the split mount exists.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-009 | Add an inline comment above the `sessions-ephemeral` volume block in `terraform/containerapp.tf` explaining that the sessions subdirectory requires EmptyDir because Azure Files SMB does not support `chmod()`. | | |
| TASK-010 | Update `docs/openclaw-containerapp-operations.md` with a note in the storage/volumes section explaining the split mount: Azure Files for durable state, EmptyDir for sessions (ephemeral, lost on restart). | | |

---

## 3. Alternatives

- **ALT-001: Switch the entire share from SMB to NFS.** Azure Files NFS fully supports `chmod()`. Rejected for now: requires upgrading to a Premium storage account and enabling VNet integration on the Container Apps Environment — significant infrastructure scope for a targeted bug fix. Viable as a future improvement if other SMB limitations surface.
- **ALT-002: Suppress `chmod` at the application level.** If openclaw exposes a config option to skip filesystem permission management (e.g. `session.fs.noChmod`), that could be set in `openclaw.json`. Rejected: no such option is documented in the openclaw-config skill; application workarounds mask the underlying constraint.
- **ALT-003: Pre-create the sessions directory with correct permissions using an init container.** An init container could `mkdir -p` and `chown` the path before the main container starts — but `chmod` would still fail on the SMB-backed path. Does not solve the EPERM.
- **ALT-004: Move the entire `.openclaw` state to EmptyDir.** Solves the `chmod` issue but loses all persistent state (agents, memory, config) on restart. Rejected: data loss is unacceptable for production operation.

---

## 4. Dependencies

- **DEP-001**: Terraform AVM module `Azure/avm-res-app-containerapp/azurerm ~> 0.3` must support `EmptyDir` as a `storage_type` in the `template.volumes` block. Verify against module source before applying.
- **DEP-002**: The `openclaw-connect.sh` script and gateway token must be available for CLI validation in TASK-007 and TASK-008.

---

## 5. Files

- **FILE-001**: `terraform/containerapp.tf` — Add `sessions-ephemeral` EmptyDir volume and volume mount (TASK-001, TASK-002, TASK-009).
- **FILE-002**: `docs/openclaw-containerapp-operations.md` — Storage/volumes documentation update (TASK-010).

---

## 6. Testing

- **TEST-001**: `terraform validate` passes with zero errors after the change (TASK-004).
- **TEST-002**: `terraform plan` shows exactly one resource updated (the Container App) and zero resources destroyed (TASK-005).
- **TEST-003**: `openclaw doctor --non-interactive` returns no EPERM errors after deployment (TASK-007).
- **TEST-004**: `openclaw agents status` shows `sessions.json` initialised successfully (TASK-008).

---

## 7. Risks & Assumptions

- **RISK-001**: The AVM container app module may not surface the `EmptyDir` storage type correctly in the current `~> 0.3` version. Mitigation: verify with `terraform plan` before applying; if the attribute is unsupported, open an issue against the module or use the `azapi` provider to patch the volume definition.
- **RISK-002**: Kubernetes (underlying ACA) may not honour overlapping volume mounts where a child path is mounted on emptyDir while the parent is on Azure Files. Mitigation: this is standard Kubernetes `volumeMount` behaviour and is well-tested; however, verify in dev before promoting to production.
- **ASSUMPTION-001**: The `sessions/` subdirectory path (`/home/node/.openclaw/agents/main/sessions`) is the only path where openclaw calls `chmod`. If openclaw also calls `chmod` on other paths under `/home/node/.openclaw`, those will continue to fail. Run `openclaw doctor --non-interactive` after deployment to surface any remaining EPERM errors.
- **ASSUMPTION-002**: Session data loss on container restart is acceptable. Restarted sessions result in a fresh conversation context with no user-visible data loss beyond in-progress chat history.

---

## 8. Related Specifications / Further Reading

- [terraform/containerapp.tf](../terraform/containerapp.tf)
- [terraform/storage.tf](../terraform/storage.tf)
- [docs/openclaw-containerapp-operations.md](../docs/openclaw-containerapp-operations.md)
- [Azure Files: Linux SMB mount limitations](https://learn.microsoft.com/en-us/azure/storage/files/storage-troubleshooting-files-linux)
- [Container Apps volume mounts](https://learn.microsoft.com/en-us/azure/container-apps/storage-mounts)
