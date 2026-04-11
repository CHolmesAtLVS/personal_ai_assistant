---
goal: Central tfvars in Azure Blob Storage; reduce GitHub Secrets; update CI and terraform-local.sh
plan_type: sub
parent_plan: parent-multi-instance-aks-feature-1.md#SUB-002
version: 1.0
date_created: 2026-04-11
last_updated: 2026-04-11
status: 'Completed'
tags: [terraform, ci, secrets, infrastructure]
---

# Introduction

![Status: Completed](https://img.shields.io/badge/status-Completed-brightgreen)

Move all non-sensitive Terraform input variables from GitHub Secrets and GitHub Variables into a central `.auto.tfvars` file stored in Azure Blob Storage alongside the Terraform state file. CI downloads this file before each Terraform run. `scripts/terraform-local.sh` downloads it before local runs. GitHub Secrets are reduced to credentials and true secrets only.

**Before:** ~21 GitHub Secrets/Variables per environment  
**After:** 11 GitHub Secrets per environment (credentials + 4 true secrets)

## 1. Requirements & Constraints

- **REQ-001**: Central tfvars file path: `{TFSTATE_CONTAINER}/tfvars/{env}.auto.tfvars` in the Terraform state storage account.
- **REQ-002**: CI must download the file before `terraform init`; file is placed at `terraform/{env}.auto.tfvars` so Terraform auto-loads it.
- **REQ-003**: `scripts/terraform-local.sh` must download the file using `az storage blob download` before running Terraform.
- **REQ-004**: `scripts/dev.tfvars` (local secrets file) must be reduced to bootstrap-only variables: SP credentials, `TFSTATE_*` variables, `TF_VAR_public_ip`, `BUDGET_ALERT_EMAIL`, `TF_VAR_azure_ai_api_key`.
- **REQ-005**: `scripts/prod.tfvars.example` must be updated to reflect the reduced secret set.
- **SEC-001**: True secrets (`AZURE_CLIENT_SECRET`, API keys, `public_ip`, `budget_alert_email`) must remain in GitHub Secrets and the local `*.tfvars` file. They must never appear in the Blob-stored tfvars file.
- **CON-001**: The storage account name (`TFSTATE_STORAGE_ACCOUNT`) must remain a GitHub Secret because it is needed to download the tfvars file before Terraform initializes.
- **CON-002**: The `tfvars/` blob path must be within the existing `tfstate` container to reuse existing storage access configuration.

## 2. Implementation Steps

### Implementation Phase 1 — Create Central tfvars Blobs

- GOAL-001: Create the central tfvars files in Azure Blob Storage for dev and prod environments.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-001 | Create `scripts/central-tfvars.example` as a documented template for the central tfvars file format, listing all variables that move out of GitHub: `project`, `environment`, `location`, `owner`, `cost_center`, `ai_model_name`, `ai_model_version`, `ai_model_capacity`, `openclaw_image_tag`, `openclaw_state_share_quota_gb`, `monthly_budget_amount`, `embedding_model_name`, `embedding_model_version`, `embedding_model_capacity`, `openclaw_instances` | | |
| TASK-002 | Upload `dev.auto.tfvars` to blob path `{TFSTATE_CONTAINER}/tfvars/dev.auto.tfvars` in the Terraform state storage account. Initial content: all non-secret dev values from `scripts/dev.tfvars`, plus `openclaw_instances = ["ch", "jh"]`. Do not include any secrets. | | |
| TASK-003 | Upload `prod.auto.tfvars` to blob path `{TFSTATE_CONTAINER}/tfvars/prod.auto.tfvars`. Initial content: prod non-secret values plus `openclaw_instances = ["ch", "jh", "kjm"]`. Do not include any secrets. | | |

### Implementation Phase 2 — Update CI Workflow

- GOAL-002: Add tfvars download step to all Terraform CI jobs in `.github/workflows/terraform-infra.yml`.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-004 | In `.github/workflows/terraform-infra.yml`, add a "Download central tfvars" step in each job (`terraform-dev`, `terraform-prod-plan`, `terraform-prod`) immediately after Azure Login and before Terraform Init. Step: `az storage blob download --account-name "$TFSTATE_STORAGE_ACCOUNT" --container-name "$TFSTATE_CONTAINER" --name "tfvars/${ENVIRONMENT}.auto.tfvars" --file "terraform/${ENVIRONMENT}.auto.tfvars" --auth-mode login --output none`. Set `ENVIRONMENT: dev` or `prod` per job. | | |
| TASK-005 | Remove all non-secret `env:` variables from CI job definitions that now live in the central tfvars file: `TF_VAR_project`, `TF_VAR_environment`, `TF_VAR_location`, `TF_VAR_owner`, `TF_VAR_cost_center`, `TF_VAR_ai_model_name`, `TF_VAR_ai_model_version`, `TF_VAR_ai_model_capacity`, `TF_VAR_openclaw_image_tag`, `TF_VAR_openclaw_state_share_quota_gb`, `TF_VAR_monthly_budget_amount`, `TF_VAR_embedding_model_name`, `TF_VAR_embedding_model_version`, `TF_VAR_embedding_model_capacity`. | | |
| TASK-006 | Keep these secrets in CI job `env:` blocks (they cannot move to the central file): `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `TFSTATE_RG`, `TFSTATE_LOCATION`, `TFSTATE_STORAGE_ACCOUNT`, `TFSTATE_CONTAINER`, `TFSTATE_KEY`, `TF_VAR_PUBLIC_IP` → `TF_VAR_public_ip`, `BUDGET_ALERT_EMAIL` → `TF_VAR_budget_alert_email`, `TF_VAR_AZURE_AI_API_KEY` → `TF_VAR_azure_ai_api_key`. | | |
| TASK-007 | Add `terraform/{env}.auto.tfvars` to `.gitignore` to prevent accidental commit of the downloaded file. | | |

### Implementation Phase 3 — Update terraform-local.sh

- GOAL-003: Update `scripts/terraform-local.sh` to download the central tfvars file before running Terraform.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-008 | After loading the local `scripts/{env}.tfvars` file (which provides `TFSTATE_STORAGE_ACCOUNT` and `TFSTATE_CONTAINER`), add a block that runs: `az storage blob download --account-name "${TFSTATE_STORAGE_ACCOUNT}" --container-name "${TFSTATE_CONTAINER}" --name "tfvars/${ENV}.auto.tfvars" --file "${TF_DIR}/${ENV}.auto.tfvars" --auth-mode login --output none`. Print a status message on success. Exit with a clear error if the blob is not found (prompt to create it). | | |
| TASK-009 | Add a cleanup trap at the end of `terraform-local.sh` that removes `${TF_DIR}/${ENV}.auto.tfvars` on exit, ensuring it is never left on disk after the script completes. | | |
| TASK-010 | Update the script header comment to document the new setup step: "Central tfvars is downloaded automatically from Azure Blob Storage; ensure `az login` is complete before running." | | |

### Implementation Phase 4 — Reduce Local Secrets File

- GOAL-004: Trim `scripts/dev.tfvars` and update `scripts/prod.tfvars.example` to reflect the reduced secret set.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-011 | Remove all non-secret TF_VAR entries from `scripts/dev.tfvars`. Keep: `AZURE_SUBSCRIPTION_ID`, `TFSTATE_*` variables, `TF_VAR_public_ip`, `TF_VAR_budget_alert_email`, `TF_VAR_azure_ai_api_key`. Add explanatory comment: "Non-secret variables (project, location, model config, instance list) are stored centrally in Azure Blob Storage and downloaded automatically." | | |
| TASK-012 | Update `scripts/prod.tfvars.example` — remove all non-secret TF_VAR lines, update header comment to describe the central tfvars approach, and add the blob download path. | | |

### Implementation Phase 5 — Remove Obsolete GitHub Secrets/Variables

- GOAL-005: Clean up GitHub Environment Secrets and Variables that have moved to central tfvars.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-013 | In GitHub repo settings → Environments → `dev`: delete GitHub Variables `TF_VAR_PROJECT`, `TF_VAR_LOCATION`, `TF_VAR_OWNER`, `TF_VAR_COST_CENTER`, `TF_VAR_AI_MODEL_NAME`, `TF_VAR_AI_MODEL_VERSION`, `TF_VAR_AI_MODEL_CAPACITY`, `TF_VAR_OPENCLAW_IMAGE_TAG`, `TF_VAR_OPENCLAW_STATE_SHARE_QUOTA_GB`, `TF_VAR_MONTHLY_BUDGET_AMOUNT`, `TF_VAR_EMBEDDING_MODEL_NAME`, `TF_VAR_EMBEDDING_MODEL_VERSION`, `TF_VAR_EMBEDDING_MODEL_CAPACITY`. | | |
| TASK-014 | Repeat TASK-013 for the `prod` environment. | | |

## 3. Alternatives

- **ALT-001**: Store central tfvars in the Git repository — rejected; would expose non-secret but sensitive operational config (location names, instances) in a public repo.
- **ALT-002**: Use GitHub Environment Variables (non-secret) for non-sensitive values — rejected; does not scale as instance count grows; requires per-value GitHub API management.
- **ALT-003**: Use Azure App Configuration instead of Blob Storage — rejected; adds a new Azure service dependency; Blob Storage already exists as part of the Terraform state backend.

## 4. Dependencies

- **DEP-001**: Terraform state storage account and container must exist (already in place).
- **DEP-002**: Azure CLI must be authenticated before running `terraform-local.sh` (already required for dev work).
- **DEP-003**: GitHub Environments (`dev`, `prod`) must have `TFSTATE_STORAGE_ACCOUNT` and `TFSTATE_CONTAINER` populated before CI can download the central tfvars.

## 5. Files

- **FILE-001**: [scripts/central-tfvars.example](../scripts/central-tfvars.example) — documentation template for the central tfvars format (new file)
- **FILE-002**: [scripts/terraform-local.sh](../scripts/terraform-local.sh) — add central tfvars download; cleanup trap
- **FILE-003**: [scripts/dev.tfvars](../scripts/dev.tfvars) — reduce to bootstrap secrets only
- **FILE-004**: [scripts/prod.tfvars.example](../scripts/prod.tfvars.example) — update to reflect reduced set
- **FILE-005**: [.github/workflows/terraform-infra.yml](../.github/workflows/terraform-infra.yml) — add download step; remove non-secret env vars
- **FILE-006**: [.gitignore](../.gitignore) — add `terraform/*.auto.tfvars`

## 6. Testing

- **TEST-001**: Run `./scripts/terraform-local.sh dev plan` end-to-end on a clean checkout; verify the central tfvars is downloaded, Terraform picks it up, and the file is removed on exit.
- **TEST-002**: Trigger the `terraform-dev` CI job on a draft PR; confirm the "Download central tfvars" step succeeds and `terraform plan` shows no unexpected diff.
- **TEST-003**: Verify no GitHub Variable or Secret value appears in `terraform plan` output that should now come from central tfvars.

## 7. Risks & Assumptions

- **RISK-001**: If `az storage blob download --auth-mode login` is used, the CI Service Principal must have `Storage Blob Data Reader` role on the tfvars container. Confirm this role assignment exists or add it to `terraform/roleassignments.tf` for the CI SP.
- **RISK-002**: The `dev.tfvars` file changes may require developers to re-upload their local file; communicate via CONTRIBUTING.md or PR description.
- **ASSUMPTION-001**: The `az` CLI is available in the CI runner (it is — `ubuntu-latest` includes it).
- **ASSUMPTION-002**: The CI SP credentials in GitHub Secrets have at minimum `Storage Blob Data Reader` on the state storage account.

## 8. Related Specifications / Further Reading

- [plan/feature-multi-instance-aks-1.md](../plan/feature-multi-instance-aks-1.md)
- [ARCHITECTURE.md — Central Terraform Variables File section](../ARCHITECTURE.md)
