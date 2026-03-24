---
goal: Deploy all required Azure resources for OpenClaw using Azure Verified Modules and Terraform
version: 1.0
date_created: 2026-03-24
last_updated: 2026-03-24
owner: Platform Engineering
status: 'Planned'
tags: [infrastructure, terraform, azure, avm, container-apps, ai-foundry, keyvault, acr, managed-identity]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

This plan implements all Azure resources required to run OpenClaw. It follows directly from [infrastructure-terraform-workflow-auth-1.md](infrastructure-terraform-workflow-auth-1.md), which established the Terraform workflow, remote state, Service Principal authentication, and the initial Resource Group deployment. This plan adds all remaining resources to the same `terraform/` root module, one logical file per concern. Azure Verified Modules (AVM) are used for every resource type where a verified module exists; the official `azurerm` provider is used as fallback.

The deployment sequence is: observability and identity → security and registry → AI platform → container runtime → RBAC wiring. Each phase produces concrete Terraform files that are additive to the existing `terraform/` directory with no changes to files created in plan 1.

## 1. Requirements & Constraints

- **REQ-001**: Deploy Log Analytics Workspace for Container Apps runtime telemetry and diagnostics.
- **REQ-002**: Deploy User-Assigned Managed Identity; attach it to the Container App as the workload identity.
- **REQ-003**: Deploy Azure Container Registry (ACR) for storing built OpenClaw container images. Admin access must be disabled; image pull must use Managed Identity.
- **REQ-004**: Deploy Azure Key Vault with RBAC authorization model enabled; use it as the runtime secret store.
- **REQ-005**: Deploy Azure AI Services cognitive account (kind `AIServices`) as the LLM endpoint backend. Deploy a configurable model via `azurerm_cognitive_deployment`.
- **REQ-006**: Deploy AI Hub (`azurerm_machine_learning_workspace` kind `Hub`) connected to the AI Services account, providing Azure AI Foundry portal management.
- **REQ-007**: Deploy AI Project (`azurerm_machine_learning_workspace` kind `Project`) under the AI Hub.
- **REQ-008**: Deploy Azure Container Apps Environment linked to the Log Analytics Workspace.
- **REQ-009**: Deploy the OpenClaw Container App with HTTPS ingress, source-IP restriction to `var.public_ip`, Managed Identity attached, image sourced from ACR, and the AI Services endpoint injected as an environment variable.
- **REQ-010**: Wire all RBAC role assignments: Managed Identity must hold `AcrPull` on ACR, `Key Vault Secrets User` on Key Vault, and `Cognitive Services OpenAI User` on the AI Services account.
- **REQ-011**: Add Terraform outputs for the Container App FQDN and the AI Services endpoint URL.
- **SEC-001**: Admin credentials on ACR must remain disabled; image pull uses Managed Identity exclusively.
- **SEC-002**: Key Vault must use RBAC authorization (`enable_rbac_authorization = true`); no legacy access policies.
- **SEC-003**: HTTPS ingress and IP restriction on Container App must be enforced as defined in `var.public_ip`.
- **SEC-004**: No secret values, API keys, or personal details committed in any Terraform file, variable defaults, or output values.
- **CON-001**: All new Terraform files are additive; no existing files from plan 1 are modified.
- **CON-002**: All resources use `tags = local.common_tags` and names derived from `local.name_prefix` as defined in `terraform/locals.tf`.
- **CON-003**: Deployment metadata (tenant, subscription, identity object IDs, DNS names) must not appear in committed files.
- **GUD-001**: Use AVM from `registry.terraform.io/Azure/` wherever a verified module exists. Document fallback reasoning when using the provider directly.
- **GUD-002**: Variable additions go into the existing `terraform/variables.tf`; new locals go into the existing `terraform/locals.tf`. Do not restructure these files.
- **PAT-001**: One `.tf` file per resource concern (e.g., `logging.tf`, `acr.tf`). This extends the `terraform/` directory without modifying existing files.

## 2. Implementation Steps

### Implementation Phase 1

- **GOAL-001**: Add AI model deployment variables and extend locals with all resource-specific name derivations. This must be completed before any resource file is created.

| Task     | Description           | Completed | Date |
| -------- | --------------------- | --------- | ---- |
| TASK-001 | Append to `terraform/variables.tf`: add `ai_model_name` (string, no default, description "Azure AI model name to deploy, e.g. gpt-4o"), `ai_model_version` (string, no default, description "Model version identifier, e.g. 2024-11-20"), `ai_model_capacity` (number, default `10`, description "Model deployment TPM capacity units"), `container_image_tag` (string, default `"latest"`, description "Container image tag to deploy from ACR"). All new variables must have explicit `description` fields. |           |      |
| TASK-002 | Append to `terraform/locals.tf`: define name locals for all new resources: `law_name = "${local.name_prefix}-law"`, `identity_name = "${local.name_prefix}-id"`, `kv_name = "${local.name_prefix}-kv"`, `acr_name = replace("${local.name_prefix}acr", "-", "")`, `ais_name = "${local.name_prefix}-ais"`, `ai_hub_name = "${local.name_prefix}-hub"`, `ai_project_name = "${local.name_prefix}-proj"`, `cae_name = "${local.name_prefix}-cae"`, `app_name = "${local.name_prefix}-app"`. Add inline comments noting character-set constraints for `acr_name` (alphanumeric only, max 50) and `kv_name` (max 24 chars; ensure `name_prefix` length respects this via project/environment variable validation in `variables.tf`). |           |      |

### Implementation Phase 2

- **GOAL-002**: Create observability and identity foundation resources. These have no dependencies on other resources in this plan and can be applied first.

| Task     | Description           | Completed | Date |
| -------- | --------------------- | --------- | ---- |
| TASK-003 | Create `terraform/logging.tf`. Call AVM module `Azure/avm-res-operationalinsights-workspace/azurerm` with label `module "log_analytics"`. Set `source = "Azure/avm-res-operationalinsights-workspace/azurerm"`, `version = "~> 0.4"`, `name = local.law_name`, `resource_group_name = "${local.name_prefix}-rg"`, `location = var.location`, `tags = local.common_tags`, `retention_in_days = 30`. Reference `module.log_analytics.resource_id` and `module.log_analytics.workspace_id` in downstream resources. |           |      |
| TASK-004 | Create `terraform/identity.tf`. Call AVM module `Azure/avm-res-managedidentity-userassignedidentity/azurerm` with label `module "managed_identity"`. Set `source = "Azure/avm-res-managedidentity-userassignedidentity/azurerm"`, `version = "~> 0.3"`, `name = local.identity_name`, `resource_group_name = "${local.name_prefix}-rg"`, `location = var.location`, `tags = local.common_tags`. Reference `module.managed_identity.resource_id` (role assignments), `module.managed_identity.client_id` (Container App registry config), and `module.managed_identity.principal_id` (role assignment principal). |           |      |

### Implementation Phase 3

- **GOAL-003**: Create security resources (Key Vault and Container Registry). These are prerequisites for role assignments in Phase 6.

| Task     | Description           | Completed | Date |
| -------- | --------------------- | --------- | ---- |
| TASK-005 | Create `terraform/keyvault.tf`. Call AVM module `Azure/avm-res-keyvault-vault/azurerm` with label `module "key_vault"`. Set `source = "Azure/avm-res-keyvault-vault/azurerm"`, `version = "~> 0.9"`, `name = local.kv_name`, `resource_group_name = "${local.name_prefix}-rg"`, `location = var.location`, `tenant_id = data.azurerm_client_config.current.tenant_id`, `sku_name = "standard"`, `enable_rbac_authorization = true`, `soft_delete_retention_days = 7`, `purge_protection_enabled = false`, `tags = local.common_tags`. Include `data "azurerm_client_config" "current" {}` once in this file; ensure it is not duplicated across the root module. |           |      |
| TASK-006 | Create `terraform/acr.tf`. Call AVM module `Azure/avm-res-containerregistry-registry/azurerm` with label `module "acr"`. Set `source = "Azure/avm-res-containerregistry-registry/azurerm"`, `version = "~> 0.4"`, `name = local.acr_name`, `resource_group_name = "${local.name_prefix}-rg"`, `location = var.location`, `sku = "Standard"`, `admin_enabled = false`, `tags = local.common_tags`. Reference `module.acr.resource_id` and `module.acr.login_server` in role assignments and Container App respectively. |           |      |

### Implementation Phase 4

- **GOAL-004**: Create Azure AI Foundry platform: Cognitive Services account, model deployment, AI Hub, and AI Project. Container App depends on the AI Services endpoint produced here.

| Task     | Description           | Completed | Date |
| -------- | --------------------- | --------- | ---- |
| TASK-007 | Create `terraform/ai.tf`. Call AVM module `Azure/avm-res-cognitiveservices-account/azurerm` with label `module "ai_services"`. Set `source = "Azure/avm-res-cognitiveservices-account/azurerm"`, `version = "~> 0.8"`, `name = local.ais_name`, `resource_group_name = "${local.name_prefix}-rg"`, `location = var.location`, `kind = "AIServices"`, `sku_name = "S0"`, `tags = local.common_tags`. Reference `module.ai_services.resource_id` and `module.ai_services.endpoint` in downstream resources. |           |      |
| TASK-008 | Append to `terraform/ai.tf`. Add `resource "azurerm_cognitive_deployment" "model"` (no AVM exists for cognitive deployments; provider resource is the documented fallback). Set `cognitive_account_id = module.ai_services.resource_id`, `name = var.ai_model_name`. Add nested `model` block: `format = "OpenAI"`, `name = var.ai_model_name`, `version = var.ai_model_version`. Add nested `sku` block: `name = "GlobalStandard"`, `capacity = var.ai_model_capacity`. |           |      |
| TASK-009 | Append to `terraform/ai.tf`. Add `resource "azurerm_storage_account" "ai_hub_storage"` as the required AI Hub backing store (provider resource; no AVM for storage account yet in this root module). Set `name = substr(replace("${local.name_prefix}aihub", "-", ""), 0, 24)`, `resource_group_name = "${local.name_prefix}-rg"`, `location = var.location`, `account_replication_type = "LRS"`, `account_tier = "Standard"`, `tags = local.common_tags`. |           |      |
| TASK-010 | Append to `terraform/ai.tf`. Add `resource "azurerm_machine_learning_workspace" "ai_hub"` (provider resource fallback; AVM `Azure/avm-res-machinelearningservices-workspace/azurerm` does not yet support `kind = "Hub"` with AI Services connection). Set `name = local.ai_hub_name`, `resource_group_name = "${local.name_prefix}-rg"`, `location = var.location`, `kind = "Hub"`, `key_vault_id = module.key_vault.resource_id`, `storage_account_id = azurerm_storage_account.ai_hub_storage.id`, `tags = local.common_tags`. Add `identity` block: `type = "SystemAssigned"`. |           |      |
| TASK-011 | Append to `terraform/ai.tf`. Add `resource "azurerm_machine_learning_workspace" "ai_project"` (provider resource fallback; same reasoning as AI Hub). Set `name = local.ai_project_name`, `resource_group_name = "${local.name_prefix}-rg"`, `location = var.location`, `kind = "Project"`, `hub_id = azurerm_machine_learning_workspace.ai_hub.id`, `tags = local.common_tags`. Add `identity` block: `type = "SystemAssigned"`. |           |      |

### Implementation Phase 5

- **GOAL-005**: Create Container Apps Environment and OpenClaw Container App. These depend on Log Analytics (Phase 2), Managed Identity (Phase 2), ACR (Phase 3), and AI Services endpoint (Phase 4).

| Task     | Description           | Completed | Date |
| -------- | --------------------- | --------- | ---- |
| TASK-012 | Create `terraform/containerapp.tf`. Call AVM module `Azure/avm-res-app-managedenvironment/azurerm` with label `module "cae"`. Set `source = "Azure/avm-res-app-managedenvironment/azurerm"`, `version = "~> 0.3"`, `name = local.cae_name`, `resource_group_name = "${local.name_prefix}-rg"`, `location = var.location`, `infrastructure_resource_group_name = "${local.name_prefix}-cae-infra-rg"`, `log_analytics_workspace_customer_id = module.log_analytics.workspace_id`, `log_analytics_workspace_primary_shared_key = module.log_analytics.primary_shared_key` (sensitive; confirm exact output name against AVM docs), `internal_load_balancer_enabled = false`, `zone_redundancy_enabled = false`, `tags = local.common_tags`. |           |      |
| TASK-013 | Append to `terraform/containerapp.tf`. Call AVM module `Azure/avm-res-app-containerapp/azurerm` with label `module "container_app"`. Set `source = "Azure/avm-res-app-containerapp/azurerm"`, `version = "~> 0.3"`, `name = local.app_name`, `resource_group_name = "${local.name_prefix}-rg"`, `container_app_environment_id = module.cae.resource_id`, `revision_mode = "Single"`, `tags = local.common_tags`. Configure `identity` block: `type = "UserAssigned"`, `identity_ids = [module.managed_identity.resource_id]`. Configure `ingress` block: `external_enabled = true`, `target_port = 3000` (confirm against OpenClaw application port), `transport = "auto"`, `allow_insecure_connections = false`. Add `ip_security_restriction` block: `action = "Allow"`, `ip_address_range = var.public_ip`, `name = "AllowHomeIP"`. Configure `template.container`: `name = "openclaw"`, `image = "${module.acr.login_server}/openclaw:${var.container_image_tag}"`. Add `env` block: `name = "AZURE_OPENAI_ENDPOINT"`, `value = module.ai_services.endpoint`. Add `registries` block: `server = module.acr.login_server`, `identity = module.managed_identity.resource_id`. |           |      |

### Implementation Phase 6

- **GOAL-006**: Create all RBAC role assignments and Terraform outputs. Final wiring step with no further resource dependents.

| Task     | Description           | Completed | Date |
| -------- | --------------------- | --------- | ---- |
| TASK-014 | Create `terraform/roleassignments.tf`. Add `resource "azurerm_role_assignment" "mi_acr_pull"`: `principal_id = module.managed_identity.principal_id`, `role_definition_name = "AcrPull"`, `scope = module.acr.resource_id`, `skip_service_principal_aad_check = false`. |           |      |
| TASK-015 | Append to `terraform/roleassignments.tf`. Add `resource "azurerm_role_assignment" "mi_kv_secrets_user"`: `principal_id = module.managed_identity.principal_id`, `role_definition_name = "Key Vault Secrets User"`, `scope = module.key_vault.resource_id`. |           |      |
| TASK-016 | Append to `terraform/roleassignments.tf`. Add `resource "azurerm_role_assignment" "mi_ai_openai_user"`: `principal_id = module.managed_identity.principal_id`, `role_definition_name = "Cognitive Services OpenAI User"`, `scope = module.ai_services.resource_id`. |           |      |
| TASK-017 | Create `terraform/outputs.tf`. Add `output "container_app_fqdn"`: `value = module.container_app.ingress_fqdn` (verify exact output name against AVM docs at implementation time), `description = "Public FQDN of the OpenClaw Container App"`, `sensitive = false`. Add `output "ai_services_endpoint"`: `value = module.ai_services.endpoint`, `description = "Azure AI Services endpoint URL"`, `sensitive = false`. |           |      |

### Implementation Phase 7

- **GOAL-007**: Validate end-to-end deployment, confirm RBAC is correctly wired, verify no secrets are exposed, and update documentation.

| Task     | Description           | Completed | Date |
| -------- | --------------------- | --------- | ---- |
| TASK-018 | Run `terraform -chdir=terraform init` with backend config from secrets, then `terraform -chdir=terraform validate`. Confirm zero errors. Confirm `terraform plan` shows the expected resource additions: Log Analytics, Managed Identity, Key Vault, ACR, AI Services, Cognitive Deployment, AI Hub Storage Account, AI Hub, AI Project, Container Apps Environment, Container App, 3 role assignments = 13 new resources (plus 1 Resource Group already in state from plan 1). |           |      |
| TASK-019 | Trigger `terraform-deploy.yml` CI workflow on a feature branch. Confirm plan artifact is uploaded. Confirm no secret values or resource identifiers appear in job logs. Confirm apply is blocked and requires environment approval before merging to `main`. |           |      |
| TASK-020 | After first `terraform apply`: (a) confirm Container App is reachable only from approved source IP over HTTPS; (b) confirm Managed Identity pulls from ACR without admin credentials; (c) confirm Container App can successfully call AI Services endpoint using Managed Identity token; (d) confirm Key Vault access returns secrets for Managed Identity and denies unauthenticated access with HTTP 403. |           |      |
| TASK-021 | Update `ARCHITECTURE.md` to reflect full resource inventory, RBAC wiring table, and Managed Identity authentication paths. Update `docs/secrets-inventory.md` to note that no AI Services API key is stored (Managed Identity with `Cognitive Services OpenAI User` role is used). |           |      |

## 3. Alternatives

- **ALT-001**: Inject RBAC `role_assignments` via AVM module input variable (supported by the AVM interface pattern) instead of standalone `azurerm_role_assignment` blocks. Not selected; placing all RBAC in a dedicated `roleassignments.tf` provides a single, auditable view of all identity grants.
- **ALT-002**: Store the AI Services API key in Key Vault and inject it via Container App secret reference. Not selected; Managed Identity with `Cognitive Services OpenAI User` eliminates the static key entirely, consistent with SEC-004 and the architecture's credential-free preference.
- **ALT-003**: Use `azurerm_cognitive_account` with `kind = "OpenAI"` instead of `kind = "AIServices"`. Not selected; `AIServices` is the unified multi-model kind required for Azure AI Foundry Hub connectivity and future model flexibility.
- **ALT-004**: Use AVM `Azure/avm-res-machinelearningservices-workspace/azurerm` for AI Hub and AI Project. Not selected for this version; that AVM does not yet fully support `kind = "Hub"` with AI Services connections. Revisit when a Hub-capable AVM is published.
- **ALT-005**: Combine all new resources in `terraform/main.tf` per plan 1's extension-point pattern. Not selected; 13+ resources in a single file is unmaintainable. Per-concern files satisfy PAT-001 without modifying existing code.

## 4. Dependencies

- **DEP-001**: Plan 1 (`infrastructure-terraform-workflow-auth-1.md`) fully completed: remote state active, GitHub Actions workflow deployed, Resource Group in Terraform state.
- **DEP-002**: AVM modules available on public Terraform Registry: `avm-res-operationalinsights-workspace ~> 0.4`, `avm-res-managedidentity-userassignedidentity ~> 0.3`, `avm-res-keyvault-vault ~> 0.9`, `avm-res-containerregistry-registry ~> 0.4`, `avm-res-cognitiveservices-account ~> 0.8`, `avm-res-app-managedenvironment ~> 0.3`, `avm-res-app-containerapp ~> 0.3`.
- **DEP-003**: `azurerm` provider `~> 4.0` (from plan 1's `providers.tf`) must support `azurerm_cognitive_deployment` and `azurerm_machine_learning_workspace` with `kind = "Hub"/"Project"`.
- **DEP-004**: Service Principal used by CI workflow holds `Contributor` on the target Resource Group and `User Access Administrator` scoped to that group (required to create role assignments).
- **DEP-005**: Azure region supports Azure AI Services kind `AIServices`, Container Apps, and Azure AI Foundry Hub. Verify availability before first apply.

## 5. Files

- **FILE-001**: `terraform/variables.tf` — append new variables (`ai_model_name`, `ai_model_version`, `ai_model_capacity`, `container_image_tag`). Existing content unchanged.
- **FILE-002**: `terraform/locals.tf` — append resource-specific name locals. Existing content unchanged.
- **FILE-003**: `terraform/logging.tf` — new file; Log Analytics Workspace via AVM.
- **FILE-004**: `terraform/identity.tf` — new file; User-Assigned Managed Identity via AVM.
- **FILE-005**: `terraform/keyvault.tf` — new file; Key Vault via AVM.
- **FILE-006**: `terraform/acr.tf` — new file; Azure Container Registry via AVM.
- **FILE-007**: `terraform/ai.tf` — new file; AI Services (AVM), Cognitive Deployment (provider fallback), AI Hub Storage Account (provider fallback), AI Hub (provider fallback), AI Project (provider fallback).
- **FILE-008**: `terraform/containerapp.tf` — new file; Container Apps Environment (AVM), Container App (AVM).
- **FILE-009**: `terraform/roleassignments.tf` — new file; all three `azurerm_role_assignment` resources.
- **FILE-010**: `terraform/outputs.tf` — new file; Container App FQDN and AI Services endpoint outputs.
- **FILE-011**: `ARCHITECTURE.md` — updated resource inventory and RBAC wiring description.
- **FILE-012**: `docs/secrets-inventory.md` — updated to note AI Services key is not stored; Managed Identity is used.

## 6. Testing

- **TEST-001**: `terraform validate` returns zero errors across all new files.
- **TEST-002**: `terraform plan` shows exactly the expected resource count with zero unexpected destroys or replacements.
- **TEST-003**: Container App is reachable over HTTPS only from the approved source IP; requests from any other IP receive a 403 from the Container Apps platform.
- **TEST-004**: Container App image pull from ACR succeeds using Managed Identity with no admin credentials (`admin_enabled = false` confirmed in plan output).
- **TEST-005**: Container App workload calls AI Services endpoint using Managed Identity token with `Cognitive Services OpenAI User` role; response is HTTP 200 from the model deployment.
- **TEST-006**: Key Vault returns a secret value to a request authenticated with the Managed Identity; unauthenticated request returns HTTP 403.
- **TEST-007**: No raw secret values, API keys, or deployment identifiers appear in `terraform output`, Terraform state, or CI job logs.
- **TEST-008**: Second `terraform plan` run with no changes shows zero resources to add, change, or destroy (idempotency confirmed).

## 7. Risks & Assumptions

- **RISK-001**: AVM module interface changes at a minor version boundary may require input variable adjustments. Mitigate by pinning to exact patch versions once validated.
- **RISK-002**: `azurerm_machine_learning_workspace` kind `Hub` requires a specific minimum provider version and may behave inconsistently across provider patch releases. Pin `azurerm` to a tested patch version once validated.
- **RISK-003**: AI Hub requires a dedicated Storage Account; the `ai_hub_storage` account uses LRS. Data durability requirements may warrant ZRS in future.
- **RISK-004**: `User Access Administrator` on the Resource Group is required for the Service Principal to create role assignments. Limit this scope strictly to the application Resource Group, not subscription level.
- **RISK-005**: `container_image_tag` defaults to `"latest"`, which is non-deterministic. The CI image publishing workflow must always supply an explicit, immutable tag and pass it to Terraform as a variable.
- **RISK-006**: Azure AI Foundry Hub has limited regional availability. Verify the selected `var.location` supports Hub before first apply.
- **ASSUMPTION-001**: The Resource Group `"${local.name_prefix}-rg"` exists in Terraform state from plan 1 before this plan is applied.
- **ASSUMPTION-002**: OpenClaw listens on port 3000 inside the container. Adjust `target_port` in TASK-013 if the actual container port differs.
- **ASSUMPTION-003**: AVM module output names (`resource_id`, `workspace_id`, `login_server`, `endpoint`, `principal_id`, `client_id`, `ingress_fqdn`, `primary_shared_key`) are accurate for the specified versions. Confirm against module documentation during TASK-018.
- **ASSUMPTION-004**: The AI model name and version specified in `ai_model_name` and `ai_model_version` are available in the selected Azure region under the configured capacity.

## 8. Related Specifications / Further Reading

- [infrastructure-terraform-workflow-auth-1.md](infrastructure-terraform-workflow-auth-1.md)
- `ARCHITECTURE.md`
- `PRODUCT.md`
- Azure Verified Modules catalog: https://azure.github.io/Azure-Verified-Modules/
- AVM Log Analytics module: https://registry.terraform.io/modules/Azure/avm-res-operationalinsights-workspace/azurerm/latest
- AVM Managed Identity module: https://registry.terraform.io/modules/Azure/avm-res-managedidentity-userassignedidentity/azurerm/latest
- AVM Key Vault module: https://registry.terraform.io/modules/Azure/avm-res-keyvault-vault/azurerm/latest
- AVM Container Registry module: https://registry.terraform.io/modules/Azure/avm-res-containerregistry-registry/azurerm/latest
- AVM Cognitive Services module: https://registry.terraform.io/modules/Azure/avm-res-cognitiveservices-account/azurerm/latest
- AVM Container Apps Environment module: https://registry.terraform.io/modules/Azure/avm-res-app-managedenvironment/azurerm/latest
- AVM Container App module: https://registry.terraform.io/modules/Azure/avm-res-app-containerapp/azurerm/latest
- Azure AI Foundry Hub/Project Terraform: https://learn.microsoft.com/azure/ai-foundry/how-to/create-hub-terraform
