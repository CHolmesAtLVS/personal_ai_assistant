---
goal: Implement Azure deployment foundation resources and naming inputs for OpenClaw
version: 1.0
date_created: 2026-03-24
last_updated: 2026-03-24
owner: Platform Engineering
status: 'Complete'
tags: [infrastructure, terraform, azure, avm, foundation]
---

# Introduction

![Status: Complete](https://img.shields.io/badge/status-Complete-brightgreen)

This child plan provisions foundation elements required by downstream deployment plans: Terraform variables, naming locals, Log Analytics Workspace, and User-Assigned Managed Identity.

## 1. Requirements & Constraints

- **REQ-001**: Add AI deployment and image tag variables to `terraform/variables.tf`.
- **REQ-002**: Add deterministic name locals for all future resources to `terraform/locals.tf`.
- **REQ-003**: Deploy Log Analytics Workspace via AVM module.
- **REQ-004**: Deploy User-Assigned Managed Identity via AVM module.
- **SEC-001**: Do not include secrets or deployment identifiers in defaults, comments, or outputs.
- **CON-001**: Existing Terraform files are only appended; no restructuring.
- **GUD-001**: Apply `tags = local.common_tags` and `resource_group_name = "${local.name_prefix}-rg"`.
- **PAT-001**: One concern per file (`logging.tf`, `identity.tf`).

## 2. Implementation Steps

### Implementation Phase 1

- **GOAL-001**: Establish variable and local prerequisites.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-001 | Append `ai_model_name`, `ai_model_version`, `ai_model_capacity`, `container_image_tag` to `terraform/variables.tf` with explicit descriptions and defaults where required. | ✅ | 2026-03-24 |
| TASK-002 | Append resource naming locals (`law_name`, `identity_name`, `kv_name`, `acr_name`, `ais_name`, `ai_hub_name`, `ai_project_name`, `cae_name`, `app_name`) to `terraform/locals.tf` including ACR and Key Vault naming constraints comments. | ✅ | 2026-03-24 |

### Implementation Phase 2

- **GOAL-002**: Provision observability and identity resources.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-003 | Create `terraform/logging.tf` with AVM `Azure/avm-res-operationalinsights-workspace/azurerm` (`~> 0.4`) configured for 30-day retention. | ✅ | 2026-03-24 |
| TASK-004 | Create `terraform/identity.tf` with AVM `Azure/avm-res-managedidentity-userassignedidentity/azurerm` (`~> 0.3`) for workload identity. | ✅ | 2026-03-24 |

## 3. Alternatives

- **ALT-001**: Keep variables and locals inline in `terraform/main.tf`; rejected for maintainability.
- **ALT-002**: Use `azurerm_log_analytics_workspace` directly; rejected due to AVM-first guideline.

## 4. Dependencies

- **DEP-001**: [plan/infrastructure-terraform-workflow-auth-1.md](infrastructure-terraform-workflow-auth-1.md) complete.

## 5. Files

- **FILE-001**: `terraform/variables.tf`
- **FILE-002**: `terraform/locals.tf`
- **FILE-003**: `terraform/logging.tf`
- **FILE-004**: `terraform/identity.tf`

## 6. Testing

- **TEST-001**: `terraform validate` passes after variable/local changes.
- **TEST-002**: `terraform plan` includes managed identity and Log Analytics resources.

## 7. Risks & Assumptions

- **RISK-001**: Name-length constraint violations for Key Vault and ACR can fail apply.
- **ASSUMPTION-001**: AVM output names match references used by downstream plans.

## 8. Related Specifications / Further Reading

- [infrastructure-azure-resources-deployment-2.md](infrastructure-azure-resources-deployment-2.md)
- [infrastructure-terraform-workflow-auth-1.md](infrastructure-terraform-workflow-auth-1.md)
- [ARCHITECTURE.md](../ARCHITECTURE.md)
