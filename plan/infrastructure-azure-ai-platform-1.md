---
goal: Implement Azure AI Services and Foundry workspace resources for OpenClaw
version: 1.0
date_created: 2026-03-24
last_updated: 2026-03-24
owner: Platform Engineering
status: 'Planned'
tags: [infrastructure, terraform, azure, ai-foundry, ai-services, machine-learning]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

This child plan provisions the AI platform stack required by OpenClaw: AI Services account, model deployment, AI Hub storage, AI Hub workspace, and AI Project workspace.

## 1. Requirements & Constraints

- **REQ-001**: Deploy AI Services account (`kind = "AIServices"`) via AVM.
- **REQ-002**: Deploy model using `azurerm_cognitive_deployment` with configured model variables.
- **REQ-003**: Deploy AI Hub and AI Project using `azurerm_machine_learning_workspace` fallback resources.
- **SEC-001**: No API keys in plan or defaults; runtime auth uses Managed Identity from separate plan.
- **CON-001**: Use provider fallback where AVM does not support Hub/Project requirements.
- **GUD-001**: Explicitly document AVM fallback rationale in code comments.
- **PAT-001**: Consolidate AI resources into `terraform/ai.tf`.

## 2. Implementation Steps

### Implementation Phase 1

- **GOAL-001**: Provision AI Services account and deployment.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-001 | Create `terraform/ai.tf` with AVM `Azure/avm-res-cognitiveservices-account/azurerm` (`~> 0.8`) configured as `kind = "AIServices"` and `sku_name = "S0"`. |  |  |
| TASK-002 | Add `azurerm_cognitive_deployment` resource using `var.ai_model_name`, `var.ai_model_version`, and `var.ai_model_capacity`. |  |  |

### Implementation Phase 2

- **GOAL-002**: Provision AI Foundry Hub and Project resources.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-003 | Add `azurerm_storage_account.ai_hub_storage` in `terraform/ai.tf` for Hub backing storage. |  |  |
| TASK-004 | Add `azurerm_machine_learning_workspace.ai_hub` with `kind = "Hub"` and system-assigned identity. |  |  |
| TASK-005 | Add `azurerm_machine_learning_workspace.ai_project` with `kind = "Project"` and `hub_id` reference. |  |  |

## 3. Alternatives

- **ALT-001**: Use `kind = "OpenAI"` account; rejected because Foundry Hub alignment requires `AIServices`.
- **ALT-002**: Use AVM ML workspace module for Hub/Project; rejected until module supports required Hub scenario.

## 4. Dependencies

- **DEP-001**: [plan/infrastructure-azure-foundation-1.md](infrastructure-azure-foundation-1.md) complete.
- **DEP-002**: [plan/infrastructure-azure-security-registry-1.md](infrastructure-azure-security-registry-1.md) Key Vault complete before Hub creation.

## 5. Files

- **FILE-001**: `terraform/ai.tf`

## 6. Testing

- **TEST-001**: `terraform plan` includes AI Services account and cognitive deployment.
- **TEST-002**: `terraform plan` includes Hub and Project workspaces with correct kinds.

## 7. Risks & Assumptions

- **RISK-001**: Regional support limitations for Hub/Project can block deployment.
- **RISK-002**: Provider patch variance for ML workspace Hub support can require pin adjustments.
- **ASSUMPTION-001**: Selected model/version are available in target region.

## 8. Related Specifications / Further Reading

- [infrastructure-azure-resources-deployment-2.md](infrastructure-azure-resources-deployment-2.md)
- [infrastructure-azure-foundation-1.md](infrastructure-azure-foundation-1.md)
- [infrastructure-azure-security-registry-1.md](infrastructure-azure-security-registry-1.md)
- [PRODUCT.md](../PRODUCT.md)
