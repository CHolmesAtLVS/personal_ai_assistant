---
goal: Add multiple Azure AI Foundry model deployments to the OpenClaw assistant
plan_type: standalone
version: 1.0
date_created: 2026-03-31
last_updated: 2026-03-31
owner: Platform Engineering
status: 'Planned'
tags: [feature, infrastructure, terraform, azure-ai-foundry, models]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

The current deployment supports a single AI model (`gpt-4o`) provisioned via the `avm-ptn-aiml-ai-foundry` AVM module. This plan extends the system to support multiple named model deployments in Azure AI Foundry, surfacing them as selectable models in OpenClaw. The change spans four layers: Terraform variables, the AI Foundry model deployment map, Container App environment injection, and the `openclaw.json` config template.

## 1. Requirements & Constraints

- **REQ-001**: All new model deployments must be provisioned via Terraform in `ai.tf` using the existing `avm-ptn-aiml-ai-foundry` AVM module's `ai_model_deployments` map. No ad-hoc `az` commands.
- **REQ-002**: The existing AI Services account, Hub, and Project must not be replaced or recreated. New deployments are added as entries to the existing module.
- **REQ-003**: Model deployment names must be injected into the Container App as environment variables using `${VAR}` substitution in `openclaw.json.tpl`, consistent with the existing pattern for `OPENCLAW_GATEWAY_TOKEN` and `AZURE_OPENAI_ENDPOINT`.
- **REQ-004**: No new Managed Identity role assignments are required. The existing `Cognitive Services OpenAI User` role scoped to the AI Services account grants access to all deployments under that account.
- **REQ-005**: All new Terraform variables must include descriptions and validation rules consistent with the style in `variables.tf`.
- **REQ-006**: Changes must be validated in the dev environment before applying to prod.
- **SEC-001**: Model deployment names are non-secret and may appear in config and env vars. No deployment names are stored in Key Vault.
- **SEC-002**: No API keys are introduced. Authentication to all model endpoints continues to use Managed Identity exclusively.
- **CON-001**: Azure AI Foundry capacity quota limits (`GlobalStandard` TPM) vary by model family and region. Available quota for new models must be confirmed in the dev subscription before setting `ai_model_capacity` values.
- **CON-002**: The `avm-ptn-aiml-ai-foundry` module version is pinned at `~> 0.10`. The schema for multiple entries in `ai_model_deployments` must be confirmed against that module version's documentation or source before implementation.
- **CON-003**: OpenClaw's `models` config block must be verified against the OpenClaw docs (`https://docs.openclaw.ai/gateway/configuration-reference`) to confirm the correct schema for Azure OpenAI multi-model configuration before editing `openclaw.json.tpl`.
- **CON-004**: Environment variable changes in the Container App require a container restart (not a hot-reload). This means adding new models triggers a revision deployment.
- **GUD-001**: Each Terraform variable for a new model must have a corresponding default that matches the deployed model name to keep `dev.tfvars` minimal.
- **PAT-001**: Follow the existing naming pattern: one variable for model name, one for version, one for capacity — per model. Do not bundle all models into a single complex-typed variable.

## 2. Implementation Steps

### Implementation Phase 1 — Investigation

- GOAL-001: Confirm all preconditions before writing any code. Record findings in this plan before proceeding to Phase 2.

| Task     | Description                                                                                                                                                  | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-001 | Fetch `https://docs.openclaw.ai/gateway/configuration-reference` and document the exact `models` block schema required for Azure OpenAI multi-model config.   |           |      |
| TASK-002 | Confirm the `ai_model_deployments` map schema for multiple entries in `avm-ptn-aiml-ai-foundry ~> 0.10` by reviewing the module's source or published docs.   |           |      |
| TASK-003 | Identify which additional models are desired (names, versions, TPM capacity) and record them here as the authoritative list for Phase 2.                       |           |      |
| TASK-004 | Confirm available `GlobalStandard` quota for each candidate model in the dev subscription/region before committing to capacity values.                        |           |      |

### Implementation Phase 2 — Terraform: Variables and Model Deployments

- GOAL-002: Add Terraform variables and new entries in the AI Foundry deployment map for each additional model identified in Phase 1.

| Task     | Description                                                                                                                                                                               | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-005 | In `terraform/variables.tf`, add one `variable` block per new model for `_name`, `_version`, and `_capacity`, following the existing `ai_model_name`, `ai_model_version`, `ai_model_capacity` pattern. |           |      |
| TASK-006 | In `terraform/ai.tf`, add one entry per new model to the `ai_model_deployments` map inside the `module "ai_foundry"` block, referencing the new variables from TASK-005.                  |           |      |
| TASK-007 | In `scripts/dev.tfvars`, add default values for each new variable introduced in TASK-005 matching the intended dev deployment names/versions/capacities.                                  |           |      |
| TASK-008 | Run `terraform plan` against the dev environment to verify the deployment map produces the expected resource additions with no destructive changes to the existing Hub, Project, or account. |           |      |

### Implementation Phase 3 — Container App: Environment Injection

- GOAL-003: Surface new model deployment names into the Container App as environment variables so `openclaw.json` can reference them via `${VAR}` substitution.

| Task     | Description                                                                                                                                                                                          | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-009 | In `terraform/containerapp.tf`, add one `env` entry per new model deployment name under the `containers[0].env` list, e.g. `{ name = "AZURE_OPENAI_DEPLOYMENT_<MODEL>", value = var.<model>_name }`. |           |      |
| TASK-010 | Confirm that the existing `AZURE_OPENAI_ENDPOINT` env var covers all deployments (single endpoint, multiple deployment names) — no additional endpoint variables needed.                              |           |      |

### Implementation Phase 4 — OpenClaw Config Template

- GOAL-004: Update `config/openclaw.json.tpl` to declare a `models` block that maps logical model names to Azure OpenAI deployments using `${VAR}` substitution.

| Task     | Description                                                                                                                                                                                        | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-011 | Add a `models` block to `config/openclaw.json.tpl` using the schema confirmed in TASK-001. Each model entry references `${AZURE_OPENAI_ENDPOINT}` and the per-model deployment name env var.        |           |      |
| TASK-012 | Ensure the original `gpt-4o` model entry is preserved (or renamed to match the logical model key) so existing conversations and settings referencing the default model are not broken.             |           |      |

### Implementation Phase 5 — Outputs (Optional)

- GOAL-005: Expose new deployment names as Terraform outputs for operational visibility.

| Task     | Description                                                                                                                                    | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-013 | Optionally add output blocks in `terraform/outputs.tf` for each new deployment name (non-sensitive, since deployment names are not secret).    |           |      |

### Implementation Phase 6 — Validation

- GOAL-006: Apply to dev and verify end-to-end model availability in OpenClaw.

| Task     | Description                                                                                                                                                                 | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-014 | Apply Terraform to the dev environment. Confirm all model deployments appear in the Azure AI Foundry portal under the correct Hub and Project.                               |           |      |
| TASK-015 | Verify the Container App revision has started and the new env vars are present using `az containerapp show` or `openclaw status` via the CLI.                                |           |      |
| TASK-016 | Confirm all models are selectable and functional in the OpenClaw UI from the approved home IP. Run a test prompt against each newly added model.                             |           |      |
| TASK-017 | Once validated in dev, apply to prod environment via the standard GitHub Actions `terraform-prod` workflow (PR merge to `main`).                                             |           |      |

## 3. Alternatives

- **ALT-001**: **Single complex-typed Terraform variable for all models** — a `map(object(...))` variable could replace the per-model scalar variables. Rejected: the existing pattern uses simple scalars, and a map would require updating `dev.tfvars` and `prod.tfvars.example` with a more complex syntax, increasing onboarding friction.
- **ALT-002**: **Hardcode deployment names in `openclaw.json.tpl`** — deployment names are stable and non-secret, so hardcoding is valid. Rejected in favor of `${VAR}` substitution to keep Terraform variables as the single source of truth and to allow name changes without editing the config template.
- **ALT-003**: **Separate AI Services accounts per model** — would require new Managed Identity role assignments and new endpoints. Rejected: one account supports multiple deployments, and the current IAM design already covers this.

## 4. Dependencies

- **DEP-001**: `avm-ptn-aiml-ai-foundry ~> 0.10` module — must support multiple entries in `ai_model_deployments` (to be confirmed in TASK-002).
- **DEP-002**: Azure AI Foundry `GlobalStandard` quota availability per model in the target region (to be confirmed in TASK-004).
- **DEP-003**: OpenClaw `models` config schema for Azure OpenAI multi-model setup (to be confirmed in TASK-001).

## 5. Files

- **FILE-001**: `terraform/variables.tf` — new variables for each additional model (name, version, capacity).
- **FILE-002**: `terraform/ai.tf` — new entries in `ai_model_deployments` map.
- **FILE-003**: `terraform/containerapp.tf` — new env vars for deployment names in the container template.
- **FILE-004**: `config/openclaw.json.tpl` — new `models` block with `${VAR}` references.
- **FILE-005**: `scripts/dev.tfvars` — default values for new variables.
- **FILE-006**: `terraform/outputs.tf` — optional new outputs for deployment names.

## 6. Testing

- **TEST-001**: `terraform plan` (TASK-008) produces only additive changes — no destroy/replace on the existing AI Services account, Hub, Project, or `main` model deployment.
- **TEST-002**: All new model deployments visible in the Azure AI Foundry portal after `terraform apply` to dev.
- **TEST-003**: New env vars present in the running Container App revision after apply.
- **TEST-004**: Each new model returns a valid response to a test prompt in the OpenClaw UI.
- **TEST-005**: Original `gpt-4o` model continues to function without regression after config template change.

## 7. Risks & Assumptions

- **RISK-001**: `GlobalStandard` TPM quota for a desired model may be zero or insufficient in the target region. Mitigation: confirm quota in TASK-004 before setting capacity values.
- **RISK-002**: The `avm-ptn-aiml-ai-foundry ~> 0.10` module may not cleanly support adding new deployments to an existing hub without triggering a plan that recreates managed resources. Mitigation: run `terraform plan` in dev (TASK-008) and review the diff carefully before applying.
- **RISK-003**: OpenClaw may require a full gateway restart (not hot-reload) to pick up changes to the `models` block if the config is seeded via the persistent Azure Files share. Mitigation: confirm hot-reload behavior per the skill config reference; plan for a manual `openclaw restart` if needed.
- **ASSUMPTION-001**: One Azure AI Services endpoint serves all model deployments. Only the deployment name differs per model — the endpoint URL is shared.
- **ASSUMPTION-002**: The persistent Azure Files share at `/home/node/.openclaw` already contains a seeded `openclaw.json`. The `openclaw.json.tpl` in this repo is a reference template, and the live config on the share must be updated separately after template changes.

## 8. Related Specifications / Further Reading

- [ARCHITECTURE.md](../ARCHITECTURE.md) — AI and Observability section; Managed Identity Role Assignments table.
- [config/openclaw.json.tpl](../config/openclaw.json.tpl) — current gateway config template.
- [terraform/ai.tf](../terraform/ai.tf) — current AI Foundry module configuration.
- [terraform/containerapp.tf](../terraform/containerapp.tf) — current Container App env injection.
- OpenClaw configuration reference: `https://docs.openclaw.ai/gateway/configuration-reference`
- AVM pattern module source: `https://registry.terraform.io/modules/Azure/avm-ptn-aiml-ai-foundry/azurerm/latest`
