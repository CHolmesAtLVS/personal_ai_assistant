---
goal: Terraform per-instance resources via for_each; openclaw_instances variable; state migration
plan_type: sub
parent_plan: parent-multi-instance-aks-feature-1.md#SUB-003
version: 1.0
date_created: 2026-04-11
last_updated: 2026-04-11
status: 'Planned'
tags: [terraform, infrastructure, multi-instance, identity, storage, aks]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

Refactor Terraform to manage OpenClaw resources per-instance using `for_each` over a new `openclaw_instances` variable. Each entry in the list produces an isolated set of Azure resources: User-Assigned Managed Identity, OIDC federated credential, Azure Files NFS share, Key Vault gateway token secret, and role assignments. Shared resources (AKS, Key Vault, AI Services, Log Analytics, storage account) remain as-is. A `terraform state mv` plan is included for zero-downtime migration of the existing single-instance resources to the new keyed addresses.

## 1. Requirements & Constraints

- **REQ-001**: Add `openclaw_instances` variable: `type = list(string)`, validation: each entry `^[a-z]{2,3}$`.
- **REQ-002**: Each instance produces: MI, OIDC federated credential, NFS share, Key Vault secret (`{inst}-openclaw-gateway-token`), Storage Account Contributor role, Key Vault Secrets User role, Cognitive Services roles.
- **REQ-003**: Shared resources (AKS, Key Vault, AI Services, LAW, storage account) must not change address or be recreated.
- **REQ-004**: Existing single-instance resources for the implicit first instance (`ch`) must be moved in state, not destroyed and recreated, to avoid downtime.
- **REQ-005**: `terraform/outputs.tf` must expose `instance_mi_client_ids` (map) and `instance_nfs_share_names` (map) for use by bootstrap scripts.
- **REQ-006**: The `azure_ai_api_key` Key Vault secret is shared; it must not be duplicated per instance.
- **SEC-001**: Per-instance MI must be scoped to only its own resources; no MI is granted access to another instance's NFS share or KV secret.
- **CON-001**: AKS cluster resource address (`module.aks`) does not change.
- **CON-002**: Key Vault resource address (`module.kv`) does not change.
- **CON-003**: Storage account resource address (`azurerm_storage_account.openclaw_nfs`) does not change.

## 2. Implementation Steps

### Implementation Phase 1 — Add Variable and Locals

- GOAL-001: Add `openclaw_instances` variable and supporting locals.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-001 | Add to `terraform/variables.tf`: `variable "openclaw_instances" { description = "List of OpenClaw instance short names (2–3 lowercase letters each)." type = list(string) validation { condition = length(var.openclaw_instances) > 0 && alltrue([for i in var.openclaw_instances : can(regex("^[a-z]{2,3}$", i))]) error_message = "Each instance name must be 2–3 lowercase letters and the list must not be empty." } }` | | |
| TASK-002 | Add to `terraform/locals.tf`: `instances = toset(var.openclaw_instances)` for use as the `for_each` key, and `instance_identity_name = { for inst in var.openclaw_instances : inst => "${local.name_prefix}-${inst}-id" }` and `instance_nfs_share_name = { for inst in var.openclaw_instances : inst => "openclaw-${inst}-nfs" }` | | |

### Implementation Phase 2 — Replace Single-Instance Resources with for_each

- GOAL-002: Convert `terraform/identity.tf` and `terraform/aks-workload-identity.tf` from single resources to `for_each` maps.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-003 | In `terraform/identity.tf`: replace `module "identity"` (single) with `module "identity"` using `for_each = local.instances`. Set `name = local.instance_identity_name[each.key]`. Update all references to `module.identity.*` to `module.identity[each.key].*`. | | |
| TASK-004 | In `terraform/aks-workload-identity.tf`: replace `azurerm_federated_identity_credential.openclaw` (single) with `for_each = local.instances`. Set `name = "openclaw-aks-${var.environment}-${each.key}"`, `parent_id = module.identity[each.key].resource_id`, `subject = "system:serviceaccount:openclaw-${each.key}:openclaw"`. | | |
| TASK-005 | In `terraform/aks-workload-identity.tf`: replace `azurerm_role_assignment.aks_files_contributor` (single) with `for_each = local.instances`. Each assignment scoped to the shared storage account; `principal_id = module.identity[each.key].principal_id`. | | |

### Implementation Phase 3 — Per-Instance NFS Shares

- GOAL-003: Replace the single NFS share in `storage-aks.tf` with a per-instance `for_each` resource.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-006 | In `terraform/storage-aks.tf`: replace `azurerm_storage_share.openclaw_nfs` (single, name `"openclaw-nfs"`) with `for_each = local.instances`. Set `name = local.instance_nfs_share_name[each.key]` (e.g. `openclaw-ch-nfs`). Quota remains `var.openclaw_state_share_quota_gb`. | | |
| TASK-007 | Remove the old `openclaw_nfs_storage_account_name` local if it only served the removed outputs; retain if still used. | | |

### Implementation Phase 4 — Per-Instance Key Vault Secrets and Role Assignments

- GOAL-004: Create per-instance Key Vault gateway token secrets and scoped role assignments.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-008 | In `terraform/keyvault.tf` (or a new `terraform/kv-instances.tf`): add `azurerm_key_vault_secret.openclaw_gateway_token` using `for_each = local.instances`. Secret name: `"${each.key}-openclaw-gateway-token"`. Value: random UUID via `random_uuid` resource keyed by instance. `lifecycle { ignore_changes = [value] }` so manual rotations are preserved. | | |
| TASK-009 | In `terraform/roleassignments.tf`: convert the `Key Vault Secrets User` role assignment for the openclaw MI from single to `for_each = local.instances`. Scoped to the environment Key Vault; `principal_id = module.identity[each.key].principal_id`. | | |
| TASK-010 | In `terraform/roleassignments.tf`: convert `Cognitive Services OpenAI User` and `Cognitive Services User` role assignments from single to `for_each = local.instances`. | | |
| TASK-011 | In `terraform/roleassignments.tf` (prod only): if `AcrPull` was assigned to a single MI, convert to `for_each = local.instances`. | | |

### Implementation Phase 5 — Update Outputs

- GOAL-005: Update `terraform/outputs.tf` to expose per-instance maps.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-012 | Replace single-instance outputs with maps: `output "instance_mi_client_ids" { value = { for inst, m in module.identity : inst => m.client_id } sensitive = true }` and `output "instance_nfs_share_names" { value = { for inst in var.openclaw_instances : inst => local.instance_nfs_share_name[inst] } }`. | | |
| TASK-013 | Add `output "kv_name" { value = module.kv.name sensitive = true }` if not already present. Update or rename `openclaw_state_storage_account_name` → `nfs_storage_account_name`. | | |

### Implementation Phase 6 — State Migration

- GOAL-006: Move existing single-instance Terraform state addresses to new `for_each` keyed addresses without destroying resources.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-014 | Before applying Terraform changes, run `terraform state list` and identify current single-instance resource addresses: `module.identity`, `azurerm_federated_identity_credential.openclaw`, `azurerm_role_assignment.aks_files_contributor`, `azurerm_storage_share.openclaw_nfs`, KV secret address, and all single-instance role assignments. Document the full list. | | |
| TASK-015 | Execute `terraform state mv` for each single-instance resource to its new keyed address (assuming existing instance is `ch`): `terraform state mv 'module.identity' 'module.identity["ch"]'`, `terraform state mv 'azurerm_federated_identity_credential.openclaw' 'azurerm_federated_identity_credential.openclaw["ch"]'`, `terraform state mv 'azurerm_storage_share.openclaw_nfs' 'azurerm_storage_share.openclaw_nfs["ch"]'`. Repeat for every role assignment and KV secret at the old address. | | |
| TASK-016 | Run `terraform plan` after the state moves and confirm zero destroy operations for resources that mapped to instance `ch`. Confirm only `jh` (dev) / `jh` + `kjm` (prod) resources are shown as new `(+)`. | | |
| TASK-017 | Rename existing NFS share from `openclaw-nfs` to `openclaw-ch-nfs` if Terraform shows a replace operation. If Azure does not support in-place rename, create the new share first, copy data from the old share using `azcopy` or az CLI, update the PV in Kubernetes to point to the new share, then destroy the old share. Document this as a maintenance window operation. | | |

## 3. Alternatives

- **ALT-001**: Use a Terraform module for per-instance resources — adds indirection; for_each on individual resources is sufficient for this scope.
- **ALT-002**: Keep the single `openclaw` namespace and differentiate instances by Deployment name — breaks namespace-level isolation. Rejected: REQ-001 requires namespace isolation.
- **ALT-003**: Accept destroy/recreate for existing instance on migration — causes downtime and orphaned state for the live `ch` instance. Rejected: TASK-014 through TASK-017 address this with state mv.

## 4. Dependencies

- **DEP-001**: SUB-002 (central tfvars) must be complete so `openclaw_instances` variable is populated before `terraform apply`.
- **DEP-002**: `random` Terraform provider must be added if not already present (for gateway token UUID generation).
- **DEP-003**: `az` CLI must be authenticated to the storage account for the NFS share rename/copy scenario in TASK-017.

## 5. Files

- **FILE-001**: [terraform/variables.tf](../terraform/variables.tf) — add `openclaw_instances`
- **FILE-002**: [terraform/locals.tf](../terraform/locals.tf) — add `instances`, `instance_identity_name`, `instance_nfs_share_name`
- **FILE-003**: [terraform/identity.tf](../terraform/identity.tf) — `for_each` on MI module
- **FILE-004**: [terraform/aks-workload-identity.tf](../terraform/aks-workload-identity.tf) — `for_each` on federated credential and storage role
- **FILE-005**: [terraform/storage-aks.tf](../terraform/storage-aks.tf) — `for_each` on NFS shares
- **FILE-006**: [terraform/roleassignments.tf](../terraform/roleassignments.tf) — `for_each` on KV, AI, ACR role assignments
- **FILE-007**: [terraform/keyvault.tf](../terraform/keyvault.tf) — per-instance gateway token secrets
- **FILE-008**: [terraform/outputs.tf](../terraform/outputs.tf) — updated outputs

## 6. Testing

- **TEST-001**: After state mv operations, `terraform plan` must show zero destroys for resources corresponding to instance `ch`.
- **TEST-002**: After `terraform apply` for dev, verify in Azure portal that two MIs, two NFS shares, and two KV secrets (`ch-openclaw-gateway-token`, `jh-openclaw-gateway-token`) exist.
- **TEST-003**: Verify OIDC federation subjects are correct: `system:serviceaccount:openclaw-ch:openclaw` and `system:serviceaccount:openclaw-jh:openclaw`.
- **TEST-004**: Confirm `terraform output instance_mi_client_ids` returns a map with both `ch` and `jh` keys.

## 7. Risks & Assumptions

- **RISK-001**: State migration (TASK-014–017) is the highest-risk operation. Run against dev first; have a state backup before executing.
- **RISK-002**: The NFS share rename may require data migration if Azure Files does not support in-place rename. TASK-017 defines the fallback procedure.
- **RISK-003**: Role assignment `for_each` conversion may require state mv for every existing role assignment. Identify all addresses carefully in TASK-014.
- **ASSUMPTION-001**: The existing instance is named `ch` (matching the validation instance list).
- **ASSUMPTION-002**: The `random` provider is acceptable for initial gateway token generation; tokens are rotated manually if needed.

## 8. Related Specifications / Further Reading

- [plan/feature-multi-instance-aks-1.md](../plan/feature-multi-instance-aks-1.md)
- [ARCHITECTURE.md — Per-Instance Resources table](../ARCHITECTURE.md)
- [terraform/aks-workload-identity.tf](../terraform/aks-workload-identity.tf)
- [terraform/storage-aks.tf](../terraform/storage-aks.tf)
