---
goal: Implement Azure security and container registry resources for OpenClaw
version: 1.0
date_created: 2026-03-24
last_updated: 2026-03-25
owner: Platform Engineering
status: 'Complete'
tags: [infrastructure, terraform, azure, keyvault, acr, security]
---

# Introduction

![Status: Complete](https://img.shields.io/badge/status-Complete-green)

This child plan provisions security boundary resources used by runtime and AI workloads: Key Vault with RBAC authorization and Azure Container Registry with admin access disabled.

## 1. Requirements & Constraints

- **REQ-001**: Deploy Key Vault using AVM with RBAC authorization enabled.
- **REQ-002**: Deploy ACR using AVM with `admin_enabled = false`.
- **SEC-001**: No legacy Key Vault access policies.
- **SEC-002**: No static registry credentials.
- **CON-001**: Reuse existing resource group and common tags locals.
- **GUD-001**: Add `azurerm_client_config` data source once across root module.
- **PAT-001**: Keep Key Vault and ACR in separate concern files.

## 2. Implementation Steps

### Implementation Phase 1

- **GOAL-001**: Provision Key Vault resource with RBAC model.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-001 | Create `terraform/keyvault.tf` with AVM `Azure/avm-res-keyvault-vault/azurerm` (`~> 0.9`) and `enable_rbac_authorization = true`. | ✅ | 2026-03-25 |
| TASK-002 | Add `data "azurerm_client_config" "current" {}` once if not already present. | ✅ | 2026-03-25 |

### Implementation Phase 2

- **GOAL-002**: Provision registry resource for image delivery.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-003 | Create `terraform/acr.tf` with AVM `Azure/avm-res-containerregistry-registry/azurerm` (`~> 0.4`) using standard SKU and disabled admin access. | ✅ | 2026-03-25 |

## 3. Alternatives

- **ALT-001**: Use Key Vault access policies model; rejected for RBAC consistency and auditability.
- **ALT-002**: Enable ACR admin account; rejected due to credential exposure risk.

## 4. Dependencies

- **DEP-001**: [plan/infrastructure-azure-foundation-1.md](infrastructure-azure-foundation-1.md) complete.

## 5. Files

- **FILE-001**: `terraform/keyvault.tf`
- **FILE-002**: `terraform/acr.tf`

## 6. Testing

- **TEST-001**: `terraform plan` shows Key Vault with RBAC authorization enabled.
- **TEST-002**: `terraform plan` shows ACR with `admin_enabled = false`.

## 7. Risks & Assumptions

- **RISK-001**: Duplicate `azurerm_client_config` data source can cause naming conflicts.
- **ASSUMPTION-001**: Region supports selected ACR and Key Vault configurations.

## 8. Related Specifications / Further Reading

- [infrastructure-azure-resources-deployment-2.md](infrastructure-azure-resources-deployment-2.md)
- [infrastructure-azure-foundation-1.md](infrastructure-azure-foundation-1.md)
- [CONTRIBUTING.md](../CONTRIBUTING.md)
