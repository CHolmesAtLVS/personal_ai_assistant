---
goal: Implement RBAC role assignments and deployment outputs for OpenClaw Azure resources
version: 1.0
date_created: 2026-03-24
last_updated: 2026-03-24
owner: Platform Engineering
status: 'Planned'
tags: [infrastructure, terraform, azure, rbac, outputs, managed-identity]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

This child plan wires managed identity authorization to required Azure scopes and adds non-sensitive Terraform outputs used by operations.

## 1. Requirements & Constraints

- **REQ-001**: Assign `AcrPull` to managed identity at ACR scope.
- **REQ-002**: Assign `Key Vault Secrets User` to managed identity at Key Vault scope.
- **REQ-003**: Assign `Cognitive Services OpenAI User` to managed identity at AI Services scope.
- **REQ-004**: Add outputs for Container App FQDN and AI Services endpoint.
- **SEC-001**: Outputs must not include secrets or tokens.
- **CON-001**: Role assignment principal uses `module.managed_identity.principal_id` consistently.
- **PAT-001**: Keep authorization and outputs in dedicated files.

## 2. Implementation Steps

### Implementation Phase 1

- **GOAL-001**: Create deterministic role assignment resources.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-001 | Create `terraform/roleassignments.tf` with `azurerm_role_assignment.mi_acr_pull` for `AcrPull` at ACR scope. |  |  |
| TASK-002 | Add `azurerm_role_assignment.mi_kv_secrets_user` for `Key Vault Secrets User` at Key Vault scope. |  |  |
| TASK-003 | Add `azurerm_role_assignment.mi_ai_openai_user` for `Cognitive Services OpenAI User` at AI Services scope. |  |  |

### Implementation Phase 2

- **GOAL-002**: Add deployment outputs.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-004 | Create `terraform/outputs.tf` with non-sensitive output `container_app_fqdn` from container app module output. |  |  |
| TASK-005 | Add non-sensitive output `ai_services_endpoint` from AI services module output. |  |  |

## 3. Alternatives

- **ALT-001**: Define role assignments inline within AVM module inputs; rejected to preserve centralized audit file.

## 4. Dependencies

- **DEP-001**: [plan/infrastructure-azure-foundation-1.md](infrastructure-azure-foundation-1.md) complete.
- **DEP-002**: [plan/infrastructure-azure-security-registry-1.md](infrastructure-azure-security-registry-1.md) complete.
- **DEP-003**: [plan/infrastructure-azure-ai-platform-1.md](infrastructure-azure-ai-platform-1.md) complete.

## 5. Files

- **FILE-001**: `terraform/roleassignments.tf`
- **FILE-002**: `terraform/outputs.tf`

## 6. Testing

- **TEST-001**: `terraform plan` includes exactly three role assignments and no destructive RBAC changes.
- **TEST-002**: `terraform output` returns non-sensitive endpoint and FQDN values only.

## 7. Risks & Assumptions

- **RISK-001**: CI identity missing User Access Administrator scope blocks role assignment creation.
- **ASSUMPTION-001**: Module output names for resource IDs and endpoint/FQDN are verified during implementation.

## 8. Related Specifications / Further Reading

- [infrastructure-azure-resources-deployment-2.md](infrastructure-azure-resources-deployment-2.md)
- [infrastructure-azure-foundation-1.md](infrastructure-azure-foundation-1.md)
- [infrastructure-azure-security-registry-1.md](infrastructure-azure-security-registry-1.md)
- [infrastructure-azure-ai-platform-1.md](infrastructure-azure-ai-platform-1.md)
- [CONTRIBUTING.md](../CONTRIBUTING.md)
