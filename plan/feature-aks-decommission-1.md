---
goal: Decommission Azure Container Apps instance after AKS deployment is fully validated
plan_type: standalone
version: 1.0
date_created: 2026-04-08
last_updated: 2026-04-08
owner: Platform
status: 'Planned'
tags: [feature, migration, aks, decommission, aca, terraform, cleanup]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

Remove the Azure Container Apps (ACA) runtime and its exclusive supporting resources from both the dev and prod environments after AKS has been fully validated per SUB-003 (feature-aks-application-1.md) smoke tests. This subplan is a one-way operation — ACA resources are destroyed and the SMB Azure Files share is retired. It must not begin until AKS is confirmed healthy in the target environment. The shared infrastructure (Key Vault, AI Services, Log Analytics, Managed Identity, storage account, Premium NFS share) is retained.

> **Safety gate:** Do not execute any task in this subplan against an environment until all six TASK-021 through TASK-026 validation checkpoints in SUB-003 have been recorded as completed for that environment.

## 1. Requirements & Constraints

- **REQ-001**: ACA decommission must be sequenced: dev first, then prod, with a minimum 7-day soak period after the dev ACA is removed before decommissioning prod ACA.
- **REQ-002**: All persistent OpenClaw state from the SMB share must have already been copied to the NFS share (verified in SUB-003 TASK-025) before the SMB share is removed.
- **REQ-003**: DNS records for `paa-dev.acmeadventure.ca` and `paa.acmeadventure.ca` must already point to the AKS Gateway LoadBalancer IPs (set during SUB-003) before ACA ingress is disabled.
- **REQ-004**: Terraform is the mechanism for removing ACA resources. No manual `az containerapp delete` commands. Resources are removed by deleting the relevant Terraform resource blocks and running `terraform apply`.
- **REQ-005**: The existing standard-tier storage account and SMB Azure Files share are removed only after the NFS share has been confirmed as the active mount in AKS and ACA is fully decommissioned.
- **REQ-006**: Shared resources must not be destroyed: Key Vault, AI Services account, Log Analytics Workspace, User-Assigned Managed Identity, Premium storage account, NFS share, and the environment resource group itself are all retained.
- **REQ-007**: ACR (shared resource group, prod only) is retained — it is independent of ACA and AKS runtime choice.
- **SEC-001**: Before removing the ACA Container App, confirm no active sessions or connected devices are relying on the ACA endpoint. Notify any active users of the cutover.
- **CON-001**: The Terraform `lifecycle { prevent_destroy = true }` guard (if present) on any retained resource must not be removed as part of this subplan.
- **CON-002**: All decommission Terraform changes must be reviewed via a pull request with a `terraform plan` confirming only the expected ACA resources are destroyed.

## 2. Implementation Steps

### Implementation Phase 1 — Pre-Decommission Validation Gate

- GOAL-001: Confirm all AKS validation criteria are met before any ACA resource is touched.

| Task     | Description                                                                                                                                                                                                                                                                                                                                        | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | Verify SUB-003 smoke test checklist is fully recorded as complete for the target environment: pod `Running`, HTTPS accessible, device paired, AI prompt successful, NFS mount verified, `openclaw doctor` clean. Do not proceed if any item is unresolved.                                                                          | ✅        | 2026-04-09 |
| TASK-002 | Confirm DNS for the environment hostname (`paa-dev.acmeadventure.ca` or `paa.acmeadventure.ca`) resolves to the AKS Gateway LoadBalancer IP, not the ACA FQDN. Run `dig paa-dev.acmeadventure.ca +short` and compare against `kubectl get svc -n gateway-system`.                                                                  | ✅        | 2026-04-09 |
| TASK-003 | Confirm no active device sessions are connected to the ACA endpoint. Run `openclaw devices list` via the AKS-hosted endpoint (openclaw-cli skill). If any sessions show `source: aca-fqdn`, notify users and allow them to reconnect via the AKS hostname before proceeding.                                                       | ✅        | 2026-04-09 |
| TASK-004 | Take a final snapshot of the SMB share contents as a backup before removal: run `scripts/backup-openclaw.sh` (or equivalent `azcopy sync`) from the SMB share to a local or Blob backup destination. Label the backup `pre-aca-decommission-<env>-<date>`. Retain for at least 30 days.                                           | ✅        | 2026-04-09 |

### Implementation Phase 2 — Disable ACA Ingress (Traffic Cutover Confirmation)

- GOAL-002: Confirm all traffic is flowing exclusively through AKS before removing the ACA Container App, allowing a safe observation window.

| Task     | Description                                                                                                                                                                                                                                                                                                                                        | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-005 | Scale the ACA Container App min replicas to 0 via Terraform: in `terraform/containerapp.tf`, set `min_replicas = 0` for the target environment (it is already 0 by default; confirm the active revision shows 0 replicas after this change). This quiesces ACA without destroying it. Run `terraform plan` to confirm only the replica count changes. | ✅        | 2026-04-09 |
| TASK-006 | Monitor AKS for 24 hours after TASK-005. Check `kubectl logs -n openclaw deployment/openclaw --tail=100` for errors. Check `openclaw status` via the openclaw-cli skill. Confirm no user-visible degradation. If issues are found, restore ACA by re-raising min replicas — ACA is still fully intact at this point.              | ✅        | 2026-04-09 |

### Implementation Phase 3 — Remove ACA Resources from Terraform

- GOAL-003: Delete the Azure Container Apps Environment, Container App, and Container Apps Environment Storage binding from Terraform state and Azure.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-007 | In `terraform/containerapp.tf`, delete (or comment out and target for removal) the following resource blocks for the target environment: `azurerm_container_app_environment_storage` (ACA storage binding to SMB share), `module.container_app` (or `azurerm_container_app`), `module.container_app_environment` (or `azurerm_container_app_environment`). Leave all other resources intact. Do not remove the `azurerm_container_app_environment_storage` resource until after `module.container_app` is removed to avoid orphan storage binding errors. | ✅        | 2026-04-09 |
| TASK-008 | Open a pull request with only the `terraform/containerapp.tf` changes from TASK-007. The PR description must state the environment, reference this plan task, and include the `terraform plan` output confirming: resources targeted for destroy, zero ACA resources created or updated, no changes to Key Vault / AI Services / LAW / Managed Identity / storage account / AKS resources.                                                                                  | ✅        | 2026-04-09 |
| TASK-009 | After PR review and approval, merge to trigger `terraform apply` via CI. For prod, this requires the GitHub Environment protection approval. Monitor the apply output. Confirm the Azure Container App and Container Apps Environment are no longer listed: `az containerapp list --resource-group <env-rg> -o table` should return empty.                                                                                                                                  | ⏳        | — |

### Implementation Phase 4 — Remove SMB Storage Share from Terraform

- GOAL-004: Remove the standard-tier storage account and SMB Azure Files share that were exclusively used by ACA. Only execute after TASK-009 is confirmed and the NFS share is active.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                 | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-010 | Confirm the NFS share is in active use by the AKS pod: `kubectl exec -n openclaw deployment/openclaw -- ls -la /home/node/.openclaw` and verify the most recent session artifacts are present (timestamps from after the AKS cutover, not ACA-era files). This confirms NFS is the live data path.                                                                                           | ✅        | 2026-04-09 |
| TASK-011 | In `terraform/storage.tf` (or the original storage file), remove the `azurerm_storage_share` resource for the SMB share and the `azurerm_storage_account` resource for the standard-tier storage account, if that account was used exclusively by ACA. If the standard storage account also holds the Terraform backend blob container, do **not** remove it — only remove the SMB share resource. | ✅        | 2026-04-09 |
| TASK-012 | Open a second pull request for the storage changes from TASK-011. `terraform plan` must show only the SMB share (and optionally standard storage account) being destroyed. No other resources affected. Merge and confirm via `az storage account list --resource-group <env-rg> -o table`.                                                                                                  | ✅        | 2026-04-09 |

### Implementation Phase 5 — Terraform State Cleanup and Documentation

- GOAL-005: Remove orphaned Terraform state entries and update documentation to reflect the AKS-only architecture.

| Task     | Description                                                                                                                                                                                                                                                                                                                                         | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-013 | Run `terraform state list` for the target environment and confirm no ACA-related resources (`azurerm_container_app*`, `azurerm_container_app_environment*`) remain in state. If any stale entries exist (resources already deleted outside of Terraform), remove them with `terraform state rm <resource>` and document the action in the PR description. | ⏳        | — |
| TASK-014 | Remove or archive the `config/openclaw.batch.json` file if it was used exclusively for ACA config seeding and is superseded by the Helm chart `values.yaml` for AKS. If the file documents canonical config values still referenced by operators, retain it with a header comment noting it is an ACA-era reference only.                            | ✅        | 2026-04-09 |
| TASK-015 | Remove references to ACA-specific scripts that are now obsolete: review `scripts/diagnose-containerapp.sh`, `scripts/seed-openclaw-config.sh`, `scripts/openclaw-connect.sh` and add a deprecation notice (header comment) to each noting it targets ACA and is superseded by AKS equivalents. Do not delete — they remain useful for historical reference and potential rollback scenarios during the soak period. | ✅        | 2026-04-09 |
| TASK-016 | Update `docs/openclaw-containerapp-operations.md`: add a header notice at the top of the document stating ACA has been decommissioned for the applicable environment and linking to the new AKS operations section. Retain the full document body for historical reference and rollback documentation.                                               | ✅        | 2026-04-09 |

### Implementation Phase 6 — Prod Decommission (repeat after 7-day dev soak)

- GOAL-006: After 7 days of confirmed stable dev AKS operation with no ACA, repeat Phases 1–5 for the prod environment.

| Task     | Description                                                                                                                                                                                                                                               | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-017 | Wait minimum 7 days after TASK-009 for dev completes. Confirm no regressions in dev AKS during the soak period (no pod restarts, no config drift, no AI failures).                                                                                       |           |      |
| TASK-018 | Repeat TASK-001 through TASK-016 targeting the prod environment. For prod-specific considerations: GitHub Environment protection approval is required at TASK-009; be especially careful to confirm `terraform plan` shows no unintended changes to prod Key Vault or AI Services secrets. |           |      |
| TASK-019 | After prod ACA is confirmed decommissioned and stable, update the parent plan [feature-aks-migration-1.md](../plan/feature-aks-migration-1.md) status to `Completed` and record completion dates for all four subplans.                                    |           |      |

## 3. Alternatives

- **ALT-001**: Manual `az containerapp delete` instead of Terraform removal — rejected; Terraform is the authoritative infrastructure mechanism per project policy. Manual deletion causes Terraform state drift and will be re-created on the next `terraform apply`.
- **ALT-002**: Leave ACA running permanently alongside AKS ("dual-run") — rejected per user requirement and to eliminate the cost of running two compute environments. Dev ACA decommission opens the path for prod.
- **ALT-003**: Remove ACA and standard storage in a single Terraform PR — rejected; separating the two PRs provides an additional confirmation checkpoint (TASK-010) that the NFS share is the live data path before the SMB share is deleted. Recovering from accidental SMB share deletion without a backup is high-risk.
- **ALT-004**: Azure Files SMB share snapshot before deletion instead of `azcopy` backup — acceptable as a supplementary measure, but `azcopy` to a separate Blob destination is preferred because it survives share-level deletion and is accessible outside the original storage account.

## 4. Dependencies

- **DEP-001**: SUB-003 (feature-aks-application-1.md) fully validated before this subplan begins.
- **DEP-002**: DNS cutover (paa-dev / paa hostnames pointing to AKS Gateway IP) completed before TASK-005.
- **DEP-003**: `scripts/backup-openclaw.sh` functional or equivalent `azcopy` command available for the pre-decommission backup (TASK-004).
- **DEP-004**: GitHub Environment protection approvals configured for the prod `terraform apply` jobs.

## 5. Files

- **FILE-001**: `terraform/containerapp.tf` — remove ACA resource blocks (TASK-007)
- **FILE-002**: `terraform/storage.tf` — remove SMB share resource (TASK-011)
- **FILE-003**: `docs/openclaw-containerapp-operations.md` — add decommission notice header (TASK-016)
- **FILE-004**: `scripts/diagnose-containerapp.sh`, `scripts/seed-openclaw-config.sh`, `scripts/openclaw-connect.sh` — add deprecation comment headers (TASK-015)
- **FILE-005**: `config/openclaw.batch.json` — archive or add ACA-era notice (TASK-014)
- **FILE-006**: `plan/feature-aks-migration-1.md` — update status to `Completed` (TASK-019)

## 6. Testing

- **TEST-001**: After TASK-009, `az containerapp list --resource-group <env-rg>` returns empty.
- **TEST-002**: After TASK-009, OpenClaw remains accessible at `https://paa-dev.acmeadventure.ca` (AKS unaffected).
- **TEST-003**: After TASK-012, `az storage account list --resource-group <env-rg>` shows only the Premium NFS storage account (and Terraform backend account if shared); standard account absent.
- **TEST-004**: After TASK-012, `kubectl exec -n openclaw deployment/openclaw -- ls -la /home/node/.openclaw` still shows all expected state files — NFS share unaffected by SMB deletion.
- **TEST-005**: `terraform plan` for the environment after all removals returns `No changes.` — no drift, no resources to recreate.

## 7. Risks & Assumptions

- **RISK-001**: `terraform apply` for ACA removal may fail if the Container App Environment has a `prevent_destroy` lifecycle rule or if there are dependent resources Terraform discovers at plan time (e.g., role assignments scoped to the Container App). Mitigation: Run `terraform plan -destroy -target=<resource>` scoped to each resource in sequence and resolve any dependency errors before a full apply.
- **RISK-002**: The standard storage account may also host the Terraform backend blob container (depending on the bootstrap script's design). Removing it would destroy Terraform state. Mitigation: TASK-011 explicitly checks; if the account is dual-purpose, only remove the `azurerm_storage_share` (SMB share), not the entire `azurerm_storage_account`.
- **RISK-003**: If the ACA Container App is still receiving traffic at cutover (e.g., DNS TTL hasn't expired), users will lose connectivity when ACA is scaled to 0. Mitigation: ensure DNS TTL for the ACA FQDN has expired (typically 5 minutes for Azure Container Apps) before TASK-005.
- **RISK-004**: There is no automated rollback path once the ACA Container App is destroyed (TASK-009). The 7-day soak period (dev) and the quiesce step (TASK-005/006 observation window) are the primary risk mitigation. The pre-decommission backup (TASK-004) is the data safety net.
- **ASSUMPTION-001**: The ACA FQDN (Azure-assigned FQDN on the Container Apps Environment) is not referenced by any external system other than the user's browser — the DNS cutover in SUB-003 already redirected `paa-dev.acmeadventure.ca` to AKS.
- **ASSUMPTION-002**: The Terraform backend blob container lives in the standard storage account from the bootstrap script. If it does, TASK-011 retains the storage account and only removes the SMB share.

## 8. Related Specifications / Further Reading

- [Parent plan: feature-aks-migration-1.md](../plan/feature-aks-migration-1.md)
- [SUB-003: feature-aks-application-1.md](../plan/feature-aks-application-1.md) — validation gate prerequisite
- [Azure Container Apps documentation](https://learn.microsoft.com/en-us/azure/container-apps/)
- [Terraform `terraform state rm`](https://developer.hashicorp.com/terraform/cli/commands/state/rm)
