---
goal: Implement Azure AI Foundry platform resources for OpenClaw via AVM pattern module
version: 1.1
date_created: 2026-03-24
last_updated: 2026-03-26
owner: Platform Engineering
status: 'Done'
tags: [infrastructure, terraform, azure, ai-foundry, avm]
---

# Introduction

![Status: Done](https://img.shields.io/badge/status-Done-brightgreen)

This child plan provisions the AI platform stack required by OpenClaw using the AVM AI Foundry pattern module (`Azure/avm-ptn-aiml-ai-foundry/azurerm ~> 0.10`). The module provides AI Foundry account, project, and model deployment as a single integrated resource. An existing Key Vault is wired in via BYOR (Bring Your Own Resource) configuration.

## 1. Requirements & Constraints

- **REQ-001**: Deploy AI Foundry account and project via AVM pattern module `Azure/avm-ptn-aiml-ai-foundry/azurerm ~> 0.10`.
- **REQ-002**: Deploy model using `ai_model_deployments` input with `var.ai_model_name`, `var.ai_model_version`, and `var.ai_model_capacity`.
- **REQ-003**: Wire existing Key Vault into the AI Foundry module via `key_vault_definition` BYOR input using `module.key_vault.resource_id`.
- **SEC-001**: No API keys in plan or defaults; runtime auth uses Managed Identity.
- **CON-001**: `azapi ~> 2.5` provider required as a module dependency; declared in `terraform/providers.tf`.
- **CON-002**: Terraform `>= 1.12` required by the pattern module; enforced in `required_version` and pinned in CI via `hashicorp/setup-terraform@v3` with `terraform_version: "~> 1.12"`.
- **PAT-001**: Consolidate all AI resources into `terraform/ai.tf` as a single module block.

## 2. Implementation Steps

### Implementation Phase 1

- **GOAL-001**: Provision AI Foundry account, project, and model deployment via AVM pattern module.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-001 | Create `terraform/ai.tf` with `module "ai_foundry"` sourced from `Azure/avm-ptn-aiml-ai-foundry/azurerm ~> 0.10`. Set `base_name = local.name_prefix`, `location = var.location`, `resource_group_resource_id = module.resource_group.resource_id`, `tags = local.common_tags`, `enable_telemetry = true`. | ✅ | 2026-03-26 |
| TASK-002 | Configure `ai_foundry = { name = local.ai_hub_name }` and `ai_projects = { main = { name = local.ai_project_name, display_name = local.ai_project_name, description = "AI Foundry project for ${var.project} ${var.environment}" } }` inputs in `module "ai_foundry"`. | ✅ | 2026-03-26 |
| TASK-003 | Configure `ai_model_deployments = { main = { name = var.ai_model_name, model = { format = "OpenAI", name = var.ai_model_name, version = var.ai_model_version }, scale = { type = "GlobalStandard", capacity = var.ai_model_capacity } } }` in `module "ai_foundry"`. | ✅ | 2026-03-26 |

### Implementation Phase 2

- **GOAL-002**: Update provider constraints and CI workflow to satisfy module requirements.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-004 | Update `terraform/providers.tf`: set `required_version = ">= 1.12"`, bump `azurerm` to `~> 4.38`, add `azapi = { source = "azure/azapi", version = "~> 2.5" }`. | ✅ | 2026-03-26 |
| TASK-005 | Add `create_byor = true` and `key_vault_definition = { main = { existing_resource_id = module.key_vault.resource_id } }` to `module "ai_foundry"` in `terraform/ai.tf`. | ✅ | 2026-03-26 |
| TASK-006 | Pin Terraform version in `.github/workflows/terraform-deploy.yml` by adding `terraform_version: "~> 1.12"` to both `hashicorp/setup-terraform@v3` steps (dev and prod jobs). | ✅ | 2026-03-26 |

## 3. Alternatives

- **ALT-001**: Use `Azure/avm-res-cognitiveservices-account/azurerm` (`kind = "AIServices"`) + `azurerm_cognitive_deployment` + `azurerm_machine_learning_workspace` (Hub/Project); rejected because this approach used the deprecated ML workspace resource type for AI Foundry and generated schema validation errors as module interfaces evolved.
- **ALT-002**: Use `kind = "OpenAI"` for the cognitive services account; rejected because Foundry Hub alignment requires `AIServices` kind.
- **ALT-003**: Keep `azurerm_machine_learning_workspace` for Hub/Project; rejected because the resource is superseded and unsupported for AI Foundry in current provider versions.

## 4. Dependencies

- **DEP-001**: [plan/infrastructure-azure-foundation-1.md](infrastructure-azure-foundation-1.md) complete.
- **DEP-002**: [plan/infrastructure-azure-security-registry-1.md](infrastructure-azure-security-registry-1.md) Key Vault complete; `module.key_vault.resource_id` output required before AI Foundry apply.

## 5. Files

- **FILE-001**: `terraform/ai.tf` — single `module "ai_foundry"` block.
- **FILE-002**: `terraform/providers.tf` — provider version constraints.
- **FILE-003**: `.github/workflows/terraform-deploy.yml` — Terraform version pin.

## 6. Testing

- **TEST-001**: `terraform validate` passes after `terraform init` with new provider/module constraints.
- **TEST-002**: `terraform plan` includes AI Foundry account, project, and model deployment resources from the pattern module.
- **TEST-003**: CI `Terraform Dev` job passes on PR with `terraform_version: "~> 1.12"` pinned.

## 7. Risks & Assumptions

- **RISK-001**: Regional availability of the AI Foundry pattern module resources can block deployment in non-supported regions.
- **RISK-002**: AI model/version availability in the target region must be verified before apply.
- **ASSUMPTION-001**: `module.key_vault.resource_id` output is available from the Key Vault AVM module deployed in the security/registry plan.
- **ASSUMPTION-002**: Selected model name and version (`var.ai_model_name`, `var.ai_model_version`) are available in the target Azure region.

## 8. Related Specifications / Further Reading

- [infrastructure-azure-resources-deployment-2.md](infrastructure-azure-resources-deployment-2.md)
- [infrastructure-azure-foundation-1.md](infrastructure-azure-foundation-1.md)
- [infrastructure-azure-security-registry-1.md](infrastructure-azure-security-registry-1.md)
- [PRODUCT.md](../PRODUCT.md)
