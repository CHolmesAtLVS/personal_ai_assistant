---
goal: Terraform deployment workflow with Service Principal authentication and Azure remote state bootstrap
version: 1.1
date_created: 2026-03-24
last_updated: 2026-03-24
owner: Platform Engineering
status: 'Planned'
tags: [infrastructure, terraform, github-actions, azure, security, remote-state, avm]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

This plan defines a deterministic implementation for Terraform deployment using GitHub Actions and Service Principal authentication, with Azure Blob remote state where the Storage Account is bootstrapped through Azure CLI. The plan enforces naming conventions, required tags, and strict secret handling for personal and environment-specific details.

Azure Verified Modules (AVM) are used wherever an AVM exists for the required resource type to ensure consistent, well-tested, and Microsoft-supported module implementations. The initial deployment scope is a single Azure Resource Group, providing a validated end-to-end foundation that is explicitly designed for iterative extension with further Azure resources in subsequent plan updates.

## 1. Requirements & Constraints

- **REQ-001**: Implement a GitHub Actions workflow that runs `terraform fmt`, `terraform init`, `terraform validate`, `terraform plan`, and conditional `terraform apply`.
- **REQ-002**: Authenticate Terraform deployment using Azure Service Principal credentials stored in GitHub repository secrets.
- **REQ-003**: Configure Terraform remote state in Azure Blob Storage.
- **REQ-004**: Create remote state Resource Group, Storage Account, and Blob Container using Azure CLI before Terraform backend initialization.
- **REQ-005**: Enforce a naming convention applied consistently to resource names and state resources.
- **REQ-006**: Enforce a standardized tag map on all Terraform-managed resources.
- **SEC-001**: Never commit secrets, identifiers, or personal details in repository files.
- **SEC-002**: Store all personal details (home IP, tenant/subscription identifiers, client IDs, client secrets, backend resource names) as GitHub Secrets.
- **SEC-003**: Keep HTTPS and IP restriction controls unchanged unless a dedicated change request explicitly updates them.
- **CON-001**: Terraform remains the authoritative mechanism for infrastructure resources.
- **CON-002**: Backend state resources are bootstrapped using Azure CLI and are excluded from Terraform management in this implementation.
- **CON-003**: Deployment metadata that can identify the tenant, subscription, identity objects, or DNS must not appear in docs, logs, or committed defaults.
- **GUD-001**: Keep implementation changes minimal, reviewable, and reversible.
- **GUD-002**: Use explicit variable validation for required naming components and tags.
- **PAT-001**: Use environment-scoped secrets and variables in GitHub Actions (`dev`, `prod`) to support future environment split.
- **REQ-007**: Use Azure Verified Modules (AVM) from `registry.terraform.io/Azure/` whenever an AVM exists for the resource type being deployed. Fall back to the official `hashicorp/azurerm` provider resource only when no AVM is available.
- **PAT-002**: The initial Terraform deployment scope is a single Resource Group (`terraform/main.tf`). The module structure must be designed for incremental extension; each subsequent resource type is added as a new AVM module call or provider resource block in `terraform/main.tf` without restructuring existing code.

## 2. Implementation Steps

### Implementation Phase 1

- **GOAL-001**: Bootstrap Azure remote state storage via Azure CLI and establish secret inventory required by workflow and Terraform.

| Task     | Description           | Completed | Date       |
| -------- | --------------------- | --------- | ---------- |
| TASK-001 | Create `scripts/bootstrap-tfstate.sh` with deterministic Azure CLI commands: `az group create`, `az storage account create`, `az storage container create`. Inputs are read from environment variables only: `TFSTATE_RG`, `TFSTATE_LOCATION`, `TFSTATE_STORAGE_ACCOUNT`, `TFSTATE_CONTAINER`, `AZURE_SUBSCRIPTION_ID`. Script exits non-zero on missing variables and uses `set -euo pipefail`. |           |            |
| TASK-002 | Add idempotency checks in `scripts/bootstrap-tfstate.sh`: call `az group exists` and `az storage account show` before create operations; only create missing resources; print machine-parseable status lines prefixed with `BOOTSTRAP-STATE:`. |           |            |
| TASK-003 | Define required GitHub Secrets in repository settings: `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `TFSTATE_RG`, `TFSTATE_LOCATION`, `TFSTATE_STORAGE_ACCOUNT`, `TFSTATE_CONTAINER`, `TFSTATE_KEY`. No values are stored in repository files. |           |            |
| TASK-004 | Add `docs/secrets-inventory.md` listing secret names, purpose, rotation cadence, and ownership without any secret values or identifiers. Include explicit statement that personal details are secrets. |           |            |

### Implementation Phase 2

- **GOAL-002**: Implement Terraform structure with naming convention and required tags, using backend configuration from runtime inputs.

| Task     | Description           | Completed | Date |
| -------- | --------------------- | --------- | ---- |
| TASK-005 | Create `terraform/providers.tf` with `azurerm` provider and version pinning: Terraform `>= 1.7.0`; provider `hashicorp/azurerm ~> 4.0`; `features {}` block included. |           |      |
| TASK-006 | Create `terraform/backend.hcl.example` containing only placeholders (`resource_group_name`, `storage_account_name`, `container_name`, `key`) and no real values. |           |      |
| TASK-007 | Create `terraform/variables.tf` with explicit inputs: `project`, `environment`, `location`, `owner`, `cost_center`, `extra_tags` (map(string), default `{}`), `public_ip` (sensitive string). Add validation regex for `project` and `environment` to enforce lowercase alphanumeric-hyphen naming. |           |      |
| TASK-008 | Create `terraform/locals.tf` implementing naming convention: `name_prefix = "${var.project}-${var.environment}"`; resource names derive from `name_prefix` with service suffixes. Define `required_tags = { project = var.project, environment = var.environment, owner = var.owner, cost_center = var.cost_center, managed_by = "terraform" }`; merge with `extra_tags`. |           |      |
| TASK-009 | Create `terraform/main.tf` as the primary entry point for all Azure resource deployments. Call AVM module `Azure/avm-res-resources-resourcegroup/azurerm` (version constraint `~> 0.2`) to provision the application Resource Group. Set `source = "Azure/avm-res-resources-resourcegroup/azurerm"`, `version = "~> 0.2"`, `name = "${local.name_prefix}-rg"`, `location = var.location`, `tags = local.common_tags`. Add a comment block stating this file is the extension point for all future resource additions. |           |      |
| TASK-010 | Ensure ingress/IP configuration consumes `var.public_ip` and is sourced from secret-backed CI variable injection, not committed defaults. This variable is declared in `variables.tf` now and consumed by future Container App / network resources added in subsequent plan iterations. |           |      |

### Implementation Phase 3

- **GOAL-003**: Implement GitHub Actions Terraform workflow with Service Principal authentication and remote state initialization.

| Task     | Description           | Completed | Date |
| -------- | --------------------- | --------- | ---- |
| TASK-011 | Create `.github/workflows/terraform-deploy.yml` with triggers: pull request (`terraform/**`), push to `main` (`terraform/**`), and manual `workflow_dispatch`. |           |      |
| TASK-012 | Add Azure login step using Service Principal secret-based auth: `az login --service-principal --username "$AZURE_CLIENT_ID" --password "$AZURE_CLIENT_SECRET" --tenant "$AZURE_TENANT_ID"` and `az account set --subscription "$AZURE_SUBSCRIPTION_ID"`. |           |      |
| TASK-013 | Add bootstrap step invoking `scripts/bootstrap-tfstate.sh` before Terraform init. Pass backend resource names from GitHub Secrets. |           |      |
| TASK-014 | Add `terraform init` command using backend config CLI args from secrets: `-backend-config="resource_group_name=${TFSTATE_RG}"`, `-backend-config="storage_account_name=${TFSTATE_STORAGE_ACCOUNT}"`, `-backend-config="container_name=${TFSTATE_CONTAINER}"`, `-backend-config="key=${TFSTATE_KEY}"`. |           |      |
| TASK-015 | Add validation and plan steps (`terraform fmt -check`, `terraform validate`, `terraform plan -out=tfplan`). Upload plan artifact for pull requests. |           |      |
| TASK-016 | Add protected apply step for `main` only, gated by environment approval and branch condition. Execute `terraform apply -auto-approve tfplan` only after successful plan. |           |      |

### Implementation Phase 4

- **GOAL-004**: Validate end-to-end behavior, security controls, and documentation completeness.

| Task     | Description           | Completed | Date |
| -------- | --------------------- | --------- | ---- |
| TASK-017 | Execute local validation: `terraform -chdir=terraform fmt -recursive`, `terraform -chdir=terraform validate` after backend init with safe non-production secrets. |           |      |
| TASK-018 | Run workflow dry-run on feature branch; confirm bootstrap creates/uses existing state resources idempotently and no secret values appear in logs. |           |      |
| TASK-019 | Update `ARCHITECTURE.md` and `CONTRIBUTING.md` with concise sections describing SP-based CI auth, CLI backend bootstrap, and secret handling policy if current docs do not already cover exact implementation flow. |           |      |
| TASK-020 | Add PR checklist entry requiring verification that personal details remain in secrets and are not printed in CI output or committed files. |           |      |

## 3. Alternatives

- **ALT-001**: Use OpenID Connect federation (`azure/login`) instead of Service Principal client secret. Not selected because requirement explicitly requests Service Principal-based authentication.
- **ALT-002**: Manage backend state resources with Terraform in a separate bootstrap stack. Not selected because requirement explicitly requests Storage Account creation through Azure CLI.
- **ALT-003**: Use local Terraform state. Not selected due to collaboration, traceability, and recovery limitations.
- **ALT-004**: Use the native `azurerm_resource_group` resource instead of the AVM module. Not selected; AVM is the stated preference and the resource group AVM (`Azure/avm-res-resources-resourcegroup/azurerm`) is a stable, verified wrapper that enforces consistent tagging and lifecycle defaults.

## 4. Dependencies

- **DEP-001**: Azure CLI available in CI runtime and local development environment.
- **DEP-002**: Terraform CLI `>= 1.7.0`.
- **DEP-003**: GitHub Actions permissions to access repository/environment secrets.
- **DEP-004**: Azure Service Principal with least-privilege RBAC roles on target subscription/resource groups.
- **DEP-005**: AVM Resource Group module `registry.terraform.io/Azure/avm-res-resources-resourcegroup/azurerm`, version `~> 0.2`. Sourced from the public Terraform Registry; no private registry required.

## 5. Files

- **FILE-001**: `.github/workflows/terraform-deploy.yml` - CI workflow for Terraform plan/apply and backend bootstrap.
- **FILE-002**: `scripts/bootstrap-tfstate.sh` - Azure CLI bootstrap script for remote state resources.
- **FILE-003**: `terraform/providers.tf` - Terraform and provider version pinning.
- **FILE-004**: `terraform/variables.tf` - input variables and validation rules.
- **FILE-005**: `terraform/locals.tf` - naming convention and common tags composition.
- **FILE-006**: `terraform/backend.hcl.example` - backend config placeholder template (no real values).
- **FILE-007**: `docs/secrets-inventory.md` - secret name catalog and governance metadata.
- **FILE-008**: `ARCHITECTURE.md` - architecture flow updates if needed.
- **FILE-009**: `CONTRIBUTING.md` - contributor process updates for secret and workflow checks.
- **FILE-010**: `terraform/main.tf` - primary resource entry point; initial content deploys Resource Group via AVM; extended in future iterations.

## 6. Testing

- **TEST-001**: Verify bootstrap script idempotency by running `scripts/bootstrap-tfstate.sh` twice with same inputs and confirming second run performs no create operations.
- **TEST-002**: Verify `terraform init` succeeds using backend configs sourced from secrets only.
- **TEST-003**: Verify `terraform plan` succeeds in pull request workflow with no hardcoded credentials.
- **TEST-004**: Verify apply is blocked outside `main` and requires environment protection approval.
- **TEST-005**: Verify all Terraform resources contain required tags: `project`, `environment`, `owner`, `cost_center`, `managed_by`.
- **TEST-006**: Verify CI logs do not expose secret values or personal details by scanning job logs for masked placeholders and absence of raw identifiers.
- **TEST-007**: Verify `terraform plan` output for initial deployment shows exactly one resource group resource sourced from `module.resource_group` (the AVM module). Confirm name matches `${local.name_prefix}-rg` and tags match `local.common_tags`.

## 7. Risks & Assumptions

- **RISK-001**: Service Principal secret expiration can break deployments if rotation is not automated.
- **RISK-002**: Incorrect RBAC scope on Service Principal can cause partial provisioning failures.
- **RISK-003**: Non-globally-unique Storage Account name can fail bootstrap.
- **RISK-004**: Missing secret values in environment-specific contexts can cause workflow runtime failures.
- **RISK-005**: AVM module minor version updates (`~> 0.2`) may introduce input variable changes requiring edits to `terraform/main.tf`. Mitigate by pinning an exact patch version (`= 0.2.x`) once validated, and upgrading deliberately.
- **ASSUMPTION-001**: Repository administrators can configure and rotate GitHub Secrets.
- **ASSUMPTION-002**: Azure CLI and Terraform versions in runner match minimum required versions.
- **ASSUMPTION-003**: Existing Terraform codebase can be updated to use centralized `local.common_tags` without breaking module interfaces.
- **ASSUMPTION-004**: The AVM resource group module `Azure/avm-res-resources-resourcegroup/azurerm ~> 0.2` is publicly accessible from the Terraform Registry in the CI runner environment.

## 8. Related Specifications / Further Reading

- `ARCHITECTURE.md`
- `PRODUCT.md`
- `CONTRIBUTING.md`
- Terraform backend documentation: https://developer.hashicorp.com/terraform/language/backend/azurerm
- Azure CLI authentication documentation: https://learn.microsoft.com/cli/azure/authenticate-azure-cli-service-principal
- Azure Verified Modules catalog: https://azure.github.io/Azure-Verified-Modules/
- AVM Resource Group module: https://registry.terraform.io/modules/Azure/avm-res-resources-resourcegroup/azurerm/latest