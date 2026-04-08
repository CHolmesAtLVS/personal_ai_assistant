---
goal: Provision AKS cluster and supporting Azure infrastructure via Terraform AVM modules
plan_type: standalone
version: 1.0
date_created: 2026-04-08
last_updated: 2026-04-08
owner: Platform
status: 'In Progress'
tags: [feature, migration, aks, terraform, avm, infrastructure, workload-identity]
---

# Introduction

![Status: In Progress](https://img.shields.io/badge/status-In%20Progress-yellow)

Extend the existing Terraform configuration to provision an AKS cluster (free tier, 2 × `Standard_B2s` nodes) alongside the existing Azure Container Apps infrastructure. This subplan also establishes Workload Identity federation so pods can authenticate to Key Vault and AI Services without static credentials, and adds the required Terraform outputs for downstream cluster configuration. The ACA resources are left untouched.

## 1. Requirements & Constraints

- **REQ-001**: AKS free tier (`sku_tier = "Free"`); no Uptime SLA.
- **REQ-002**: 2 nodes using `Standard_B2s` VM SKU; one system node pool, one user node pool (1 node each), both in the same region as the existing resource group.
- **REQ-003**: AKS OIDC issuer enabled (`oidc_issuer_enabled = true`) and Workload Identity enabled (`workload_identity_enabled = true`).
- **REQ-004**: Azure Key Vault Secrets Provider add-on enabled on the cluster (`key_vault_secrets_provider` block) with secret rotation enabled at a 2-minute interval.
- **REQ-005**: Azure Files CSI driver is built into AKS by default; no additional configuration required in Terraform beyond the storage account RBAC grants.
- **REQ-006**: Azure CNI Overlay network plugin for the cluster; enables network policy enforcement.
- **REQ-007**: The existing User-Assigned Managed Identity must receive an OIDC Federated Identity Credential for the `openclaw` Kubernetes service account (`system:serviceaccount:openclaw:openclaw`).
- **REQ-008**: Key Vault RBAC: the Managed Identity already holds `Key Vault Secrets User`; no new Key Vault role assignment needed; the Workload Identity token is exchanged for the same MI token.
- **REQ-009**: Storage account RBAC: Managed Identity must have `Storage File Data NFS Share Contributor` on the Azure Files share to mount via CSI with NFS protocol.
- **REQ-010**: AKS cluster must emit diagnostics to the existing Log Analytics Workspace.
- **REQ-011**: All new Terraform files follow the project's existing naming and locals conventions.
- **REQ-012**: The Azure Files share used for `/home/node/.openclaw` must use **NFS protocol** so that the OpenClaw process can perform `chmod`/`chown` on persisted files. NFS shares require a Premium FileStorage storage account (`kind = "FileStorage"`, `account_tier = "Premium"`, `account_replication_type = "LRS"` or `"ZRS"`). The existing standard-tier storage account does not support NFS shares. A new Premium storage account must be added to Terraform for this share. Migrate existing state data from the old SMB share to the new NFS share before switching the mount (see RISK-003).
- **SEC-001**: AKS API server authorized IP ranges must include the GitHub Actions runner outbound IP range or be set open only during CI — use a variable `aks_api_authorized_ips` with a sensible default (empty = public). Operators must populate this variable to restrict access.
- **SEC-002**: Node pool OS disk type `Ephemeral` or `Managed`; use `Managed` 30 GiB for compatibility with `Standard_B2s` (ephemeral requires local temp disk larger than OS disk).
- **CON-001**: `latest` Kubernetes version is not pinned in code; use the `kubernetes_version` variable that defaults to `null` (AKS selects latest stable). Allow explicit override via `TF_VAR_aks_kubernetes_version`.
- **CON-002**: ACA resources (`containerapp.tf`, `acr.tf`) are not modified in this subplan.

## 2. Implementation Steps

### Implementation Phase 1 — New Terraform file: `terraform/aks.tf`

- GOAL-001: Declare the AKS cluster resource using the AVM module `Azure/avm-res-containerservice-managedcluster/azurerm ~> 0.5`.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | Create `terraform/aks.tf`. Declare module `aks` using source `Azure/avm-res-containerservice-managedcluster/azurerm`, version `~> 0.5`. Set `name = "${local.name_prefix}-aks"`, `resource_group_name = module.resource_group.resource.name`, `location = var.location`. Set `sku_tier = "Free"`. Set `kubernetes_version = var.aks_kubernetes_version` (nullable). Enable `oidc_issuer_enabled = true`, `workload_identity_enabled = true`. Set `network_profile` block: `network_plugin = "azure"`, `network_plugin_mode = "overlay"`, `network_policy = "azure"`, `dns_service_ip = "10.0.0.10"`, `service_cidr = "10.0.0.0/16"`. Set `log_analytics_workspace_id` to the existing LAW resource ID output. | ✅ | 2026-04-08 |
| TASK-002 | Within `terraform/aks.tf`, define the default system node pool block: `name = "system"`, `vm_size = var.aks_node_vm_size`, `node_count = 1`, `os_disk_size_gb = 30`, `os_disk_type = "Managed"`, `only_critical_addons_enabled = true`, `node_labels = { "role" = "system" }`. This reserves the system pool for AKS control-plane pods only.                                                                                                                                                                                                                                                                                                                                                   | ✅ | 2026-04-08 |
| TASK-003 | Within `terraform/aks.tf`, define a user node pool named `workload`: `vm_size = var.aks_node_vm_size`, `node_count = 1`, `os_disk_size_gb = 30`, `os_disk_type = "Managed"`, `node_labels = { "role" = "workload" }`, `node_taints = []`. This is where OpenClaw and platform workloads run.                                                                                                                                                                                                                                                                                                                                                                                                    | ✅ | 2026-04-08 |
| TASK-004 | Within `terraform/aks.tf`, attach the existing User-Assigned Managed Identity to the cluster: `managed_identities = { system_assigned = false, user_assigned_resource_ids = [module.managed_identity.resource.id] }`. This makes the MI available for Workload Identity token exchange.                                                                                                                                                                                                                                                                                                                                                                                                         | ✅ | 2026-04-08 |
| TASK-005 | Within `terraform/aks.tf`, enable the Key Vault Secrets Provider add-on: `key_vault_secrets_provider = { secret_rotation_enabled = true, secret_rotation_interval = "2m" }`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | ✅ | 2026-04-08 |
| TASK-006 | Within `terraform/aks.tf`, set `api_server_access_profile = { authorized_ip_ranges = var.aks_api_authorized_ips }`. This variable defaults to `[]` (open) and is populated via GitHub Secret `TF_VAR_AKS_API_AUTHORIZED_IPS` for production hardening.                                                                                                                                                                                                                                                                                                                                                                                                                                         | ✅ | 2026-04-08 |
| TASK-007 | Within `terraform/aks.tf`, configure diagnostics: add `diagnostic_settings` block pointing `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, `kube-audit`, `kube-audit-admin` log categories to the existing Log Analytics Workspace resource ID.                                                                                                                                                                                                                                                                                                                                                                                                                                  | ✅ | 2026-04-08 |

### Implementation Phase 2 — Workload Identity Federation: `terraform/aks-workload-identity.tf`

- GOAL-002: Create OIDC federated credentials so the `openclaw` Kubernetes service account can exchange tokens for the Managed Identity, enabling pod-level Key Vault and AI Services access.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                              | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-008 | Create `terraform/aks-workload-identity.tf`. Declare resource `azurerm_federated_identity_credential "openclaw"`: `name = "openclaw-aks-${var.environment}"`, `resource_group_name = module.resource_group.resource.name`, `parent_id = module.managed_identity.resource.id`, `audience = ["api://AzureADTokenExchange"]`, `issuer = module.aks.oidc_issuer_url`, `subject = "system:serviceaccount:openclaw:openclaw"`. | ✅ | 2026-04-08 |
| TASK-009 | In `terraform/aks-workload-identity.tf`, verify the Managed Identity already holds `Key Vault Secrets User` (from `roleassignments.tf`). Add a comment noting no new KV role assignment is required for Workload Identity — the existing role binding applies via the same MI client ID.                                                                                                  | ✅ | 2026-04-08 |
| TASK-010 | In `terraform/aks-workload-identity.tf`, add `azurerm_role_assignment "aks_files_contributor"`: assign `Storage File Data NFS Share Contributor` scoped to the NFS Azure Files share resource ID on the new Premium storage account for the Managed Identity. This allows the Azure Files CSI driver to mount the NFS share via Workload Identity without a storage account key. Also add a separate `azurerm_storage_account` resource (Premium FileStorage) and `azurerm_storage_share` resource (NFS protocol, `enabled_protocol = "NFS"`) in `terraform/storage.tf` or a new `terraform/storage-aks.tf`. Keep the existing standard storage account and SMB share intact for ACA until decommission. Note: role assigned as `Storage Account Contributor` at storage account scope (the `Storage File Data NFS Share Contributor` built-in does not exist). | ✅ | 2026-04-08 |

### Implementation Phase 3 — Variables and Outputs

- GOAL-003: Expose AKS configuration via variables and outputs so downstream CI steps and documentation remain auditable.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                 | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-011 | Add to `terraform/variables.tf`: `variable "aks_kubernetes_version"` (type `string`, nullable, default `null`, description "AKS Kubernetes version; null selects the latest stable AKS-supported version"); `variable "aks_node_vm_size"` (type `string`, default `"Standard_B2s"`, description "VM SKU for AKS system and workload node pools"); `variable "aks_api_authorized_ips"` (type `list(string)`, default `[]`, description "CIDR ranges allowed to reach the AKS API server; empty list = unrestricted (default for dev)"). | ✅ | 2026-04-08 |
| TASK-012 | Add to `terraform/outputs.tf`: `output "aks_cluster_name"` (value `module.aks.resource.name`, sensitive `false`); `output "aks_oidc_issuer_url"` (value `module.aks.oidc_issuer_url`, sensitive `true`); `output "aks_node_resource_group"` (value `module.aks.resource.node_resource_group`, sensitive `false`). These are needed for workload identity federation debugging and GitHub Actions kubeconfig generation.                       | ✅ | 2026-04-08 |
| TASK-013 | Add to `scripts/dev.tfvars`: `aks_node_vm_size = "Standard_B2s"`. Leave `aks_kubernetes_version` and `aks_api_authorized_ips` absent (use defaults). Do not commit any IP values.                                                                                                                                                                                                                                                           | ✅ | 2026-04-08 |

### Implementation Phase 4 — CI/CD GitHub Actions Update

- GOAL-004: Ensure GitHub Actions Terraform jobs have kubectl access to the newly created AKS cluster for any post-Terraform bootstrap steps.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                          | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-014 | Add an `az aks get-credentials` step to the Terraform CI workflow after `terraform apply` succeeds in both `terraform-dev` and `terraform-prod` jobs. Command: `az aks get-credentials --resource-group <rg> --name <cluster> --overwrite-existing`. Use Terraform output values to derive the resource group and cluster name. Store kubeconfig in the CI runner's default `~/.kube/config`; do not commit or cache. | ✅ | 2026-04-08 |
| TASK-015 | Add GitHub secret `TF_VAR_AKS_API_AUTHORIZED_IPS` to `dev` and `prod` GitHub Environments. Value should be a JSON-encoded list of CIDRs: the home public IP `/32` plus GitHub Actions runner IP ranges, or leave empty during initial rollout and tighten post-validation.                                                                                                                                            |   |      |
| TASK-016 | Run `terraform fmt`, `terraform validate`, and `terraform plan` for the `dev` environment. Confirm the plan shows only AKS additive changes (no ACA modifications). Resolve any module version constraints or provider version conflicts before merging.                                                                                                                                                              | ✅ | 2026-04-08 |

## 3. Alternatives

- **ALT-001**: Single node pool with 2 nodes — rejected; AKS best practice separates system and user workloads. System pool taints prevent user pods from landing on system nodes.
- **ALT-002**: Ephemeral OS disks — rejected; `Standard_B2s` has a 4 GiB temp disk which is smaller than the minimum 30 GiB OS disk requirement. Managed disk is required.
- **ALT-003**: Azure CNI (full) — rejected; consumes one IP per pod from the subnet (IPAM exhaustion risk). Azure CNI Overlay allocates pod IPs from a separate overlay range.
- **ALT-004**: Separate federated credentials per environment — accepted (implemented); each environment has its own federated credential named `openclaw-aks-<environment>` pointing to the environment-specific OIDC issuer URL.
- **ALT-005**: Azure Files SMB protocol with fixed `uid`/`gid`/`file_mode`/`dir_mode` mount options — rejected; SMB mounts ignore `chmod`/`chown` syscalls at runtime, causing silent failures for any OpenClaw code that sets file permissions on its state files. NFS protocol is required for correct POSIX permission semantics.

## 4. Dependencies

- **DEP-001**: Existing `module.resource_group`, `module.managed_identity`, `module.log_analytics`, `azurerm_storage_share.openclaw` resources in Terraform — referenced by name in new files.
- **DEP-002**: AVM module `Azure/avm-res-containerservice-managedcluster/azurerm ~> 0.5` — must be available in Terraform registry. Run `terraform init -upgrade` after adding.
- **DEP-003**: `azurerm` provider version must support `azurerm_federated_identity_credential` (available since `~> 3.40`). Verify `required_providers` in `terraform/providers.tf`.

## 5. Files

- **FILE-001**: `terraform/aks.tf` — new file; AKS cluster module declaration
- **FILE-002**: `terraform/aks-workload-identity.tf` — new file; federated identity credential and storage RBAC
- **FILE-003**: `terraform/variables.tf` — add three AKS variables
- **FILE-004**: `terraform/outputs.tf` — add three AKS outputs
- **FILE-005**: `scripts/dev.tfvars` — add `aks_node_vm_size`
- **FILE-006**: `.github/workflows/terraform.yml` (or equivalent) — add `az aks get-credentials` step
- **FILE-007**: `terraform/storage-aks.tf` (or additions to `terraform/storage.tf`) — new Premium FileStorage storage account and NFS Azure Files share

## 6. Testing

- **TEST-001**: `terraform plan` produces only additive changes (no destroy on ACA, Key Vault, storage, AI resources).
- **TEST-002**: After `terraform apply`, run `az aks show --name <cluster> --resource-group <rg> --query "oidcIssuerProfile.issuerUrl"` and confirm the OIDC issuer URL matches `module.aks.oidc_issuer_url` Terraform output.
- **TEST-003**: Confirm `az aks get-credentials` succeeds and `kubectl get nodes` returns 2 nodes in `Ready` state.
- **TEST-004**: Confirm federated identity credential exists: `az identity federated-credential show --name openclaw-aks-dev --identity-name <mi> --resource-group <rg>`.
- **TEST-005**: Confirm ACA environment is unaffected: `az containerapp show --name <app> --resource-group <rg>` returns healthy status.

## 7. Risks & Assumptions

- **RISK-001**: AVM AKS module output attribute names (`oidc_issuer_url`, `resource.name`, etc.) may differ by module version. Validate output names against the selected module version's `outputs.tf` before wiring.
- **RISK-002**: `Standard_B2s` VMs may not be available in quota for the target subscription/region. Check quota via `az vm list-usage --location <region>` before applying.
- **RISK-003**: The existing Azure Files share is SMB (standard storage account). Migrating accumulated state (conversations, auth profiles, device pairings) to the new NFS share requires a one-time data copy while ACA is briefly paused or with ACA still running and the share quiesced. Use `azcopy sync` between the two shares before the first AKS pod starts. The SMB share is retained until ACA is decommissioned (SUB-004).
- **ASSUMPTION-001**: The existing `azurerm_storage_share.openclaw` resource is referenced by that exact name in `storage.tf`. Adapt the resource ID reference if the name differs.
- **ASSUMPTION-002**: The GitHub Actions service principal has `Contributor` + `User Access Administrator` (or `Owner`) on the resource group to create role assignments for storage.
- **ASSUMPTION-003**: Premium FileStorage (`Standard_LRS` or `Premium_LRS`) is available in the subscription's region and quota. Verify with `az storage account list-supported --location <region> --query "[?kind=='FileStorage']"` before applying.

## 8. Related Specifications / Further Reading

- [AVM AKS module documentation](https://registry.terraform.io/modules/Azure/avm-res-containerservice-managedcluster/azurerm/latest)
- [AKS Workload Identity overview](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview)
- [Azure CNI Overlay](https://learn.microsoft.com/en-us/azure/aks/azure-cni-overlay)
- [Azure Files CSI driver for AKS](https://learn.microsoft.com/en-us/azure/aks/azure-files-csi)
- [Parent plan: feature-aks-migration-1.md](../plan/feature-aks-migration-1.md)
