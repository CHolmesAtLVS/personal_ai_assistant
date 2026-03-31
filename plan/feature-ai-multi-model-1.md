---
goal: Add multiple Azure AI Foundry model deployments to the OpenClaw assistant
plan_type: standalone
version: 3.0
date_created: 2026-03-31
last_updated: 2026-03-31
owner: Platform Engineering
status: 'In Progress'
tags: [feature, infrastructure, terraform, azure-ai-foundry, models, xai, embeddings]
---

# Introduction

![Status: In Progress](https://img.shields.io/badge/status-In%20Progress-yellow)

The current deployment supports a single AI model (`gpt-4o`) provisioned via the `avm-ptn-aiml-ai-foundry` AVM module. This plan migrates OpenClaw to use **xAI Grok** as the primary chat model family (`grok-4-fast-reasoning` as default), retaining only `text-embedding-3-large` from the Azure OpenAI endpoint for embeddings/RAG. The existing `gpt-4o` OpenAI deployment will be removed once Grok is validated.

Research (v2.0/3.0) has revealed a **critical architectural split**: Azure AI Foundry exposes two distinct endpoint types, and OpenClaw must be configured differently for each. This requires IAM investigation before implementation. The Azure OpenAI endpoint is retained solely for embeddings.

---

## Research Findings (v2.0)

### OpenClaw Model Routing

OpenClaw identifies models as `provider/model` strings (e.g. `openai/gpt-4.1`, `xai/grok-3`). The `agents.defaults.models` catalog maps these strings to aliases and per-model parameters. The `/model` chat command lets the user switch between any catalogued model at runtime. The `models` config block **hot-reloads** — no gateway restart is needed when updating `openclaw.json`. However, adding new **environment variables** to the Container App (process env) always triggers a new revision.

### Azure AI Foundry: Two Endpoint Architectures

There are two fundamentally different endpoint patterns in Azure AI Foundry:

| Type | Endpoint pattern | Models | OpenClaw provider | Role in this plan |
|---|---|---|---|---|
| **Azure OpenAI** | `https://<account>.openai.azure.com/` | GPT-4.x, o-series, text-embedding-3-large | `openai` (built-in), `AZURE_OPENAI_ENDPOINT` | **Embeddings only** |
| **Azure AI Model Inference** | `https://<account>.services.ai.azure.com/models` | Grok (xAI), DeepSeek, Mistral, etc. | Custom provider in `models.providers` | **Primary chat** |

The current setup uses only the Azure OpenAI endpoint. Grok requires a **second base URL** and a custom provider entry in `openclaw.json`. The Azure OpenAI endpoint is retained exclusively for `text-embedding-3-large`.

### Candidate Models

All models below are available as **Foundry Models sold directly by Azure** (no Azure Marketplace subscription required) under `GlobalStandard` deployment.

#### Chat / Reasoning — Azure AI Model Inference endpoint (custom `azure-foundry` provider) — PRIMARY

| OpenClaw key | Azure deployment name | Context | Notes |
|---|---|---|---|
| `azure-foundry/grok-4-fast-reasoning` | `grok-4-fast-reasoning` | 128,000 | **PRIMARY**. Grok 4 fast reasoning. Text + image. Tool calling. |
| `azure-foundry/grok-3` | `grok-3` | 131,072 | Fallback. High-end reasoning. Text only. Tool calling. |
| `azure-foundry/grok-3-mini` | `grok-3-mini` | 131,072 | Lightweight option for heartbeat / subagent runs. |

> **Note**: `grok-4` (non-fast) and `grok-code-fast-1` require pre-registration at `https://aka.ms/xai/grok-4` and are excluded from the initial set. `grok-4-fast-reasoning` does **not** require pre-registration and is GlobalStandard in all regions.

#### Chat — Azure OpenAI endpoint — REMOVED

All Azure OpenAI chat models (`gpt-4.1`, `gpt-4.1-mini`, `o4-mini`, `gpt-4o`) are removed from scope. The existing `gpt-4o` deployment will be decommissioned once Grok is validated in dev.

#### Embeddings — Azure OpenAI endpoint (`openai` provider)

| Azure deployment name | Format | Dimensions | Notes |
|---|---|---|---|
| `text-embedding-3-large` | `OpenAI` | 3,072 | Best available Azure embedding model. Used by OpenClaw memory/RAG tools. |

### OpenClaw Configuration Schema (confirmed from docs)

From the live configuration reference at `https://docs.openclaw.ai/gateway/configuration-reference`:

- **Model catalog**: `agents.defaults.models` — map of `"provider/model"` → `{ alias, params }`
- **Primary model**: `agents.defaults.model.primary` — set to `"azure-foundry/grok-4-fast-reasoning"`
- **Fallbacks**: `agents.defaults.model.fallbacks` — set to `["azure-foundry/grok-3"]`
- **Custom providers**: `models.providers` — map of provider id → `{ baseUrl, apiKey, api, models[] }`
- **API adapters**: `openai-completions`, `openai-responses`, `anthropic-messages`, `google-generative-ai`. The Azure AI Model Inference API is OpenAI-compatible, so `openai-completions` or `openai-responses` is likely the correct adapter for Grok.
- **Models hot-reload**: Yes — no gateway restart needed for `models` or `agents` changes.
- **Env var changes**: Always require a Container App restart (new revision).

### Open Questions Requiring Investigation

1. **Azure AI Model Inference auth via Managed Identity**: **RESOLVED (api-key fallback).** Investigation confirmed that the Azure AI Model Inference endpoint does not accept Azure AD bearer tokens for Managed Identity auth in the current SDK/API version. The `Cognitive Services User` role assignment was added (`roleassignments.tf`) but is insufficient for this endpoint. **ALT-006 was invoked**: the AI Model Inference API key is stored in Key Vault (`azure-ai-api-key`) and injected into the Container App as `AZURE_AI_API_KEY` via secret reference. OpenClaw is configured with `"auth": "api-key"` in the `azure-foundry` provider block. See SEC-003.
2. **AVM module `format` value for Grok**: **RESOLVED (assumed).** `format = "OpenAI"` is used for all Grok deployments since they are served via the OpenAI-compatible Azure AI Model Inference API. The AVM module source confirms it passes `format` through to `azurerm_cognitive_account_deployment`, which accepts `"OpenAI"` as the valid format for OpenAI-compatible model serving. **Confirm by reviewing `terraform plan` output — if Azure rejects the format, switch to a raw `azurerm_cognitive_account_deployment` resource per RISK-002.**
3. **Azure AI Model Inference endpoint URL**: **RESOLVED.** The endpoint is read dynamically from `data.azapi_resource.ai_foundry.output.properties.endpoints["Azure AI Model Inference API"]` with `/models` appended. The key name `"Azure AI Model Inference API"` is the standard key in the `properties.endpoints` map for AI Services accounts. Confirm by checking `terraform plan` or via `az resource show` on the AI Services account.

---

## 1. Requirements & Constraints

- **REQ-001**: All new model deployments must be provisioned via Terraform in `ai.tf` using the existing `avm-ptn-aiml-ai-foundry` AVM module's `ai_model_deployments` map. No ad-hoc `az` commands.
- **REQ-002**: The existing AI Services account, Hub, and Project must not be replaced or recreated. New deployments are added as entries to the existing module.
- **REQ-003**: Model deployment names must be injected into the Container App as environment variables using `${VAR}` substitution in `openclaw.json.tpl`.
- **REQ-004**: All new Terraform variables must include descriptions and validation rules consistent with the style in `variables.tf`.
- **REQ-005**: Changes must be validated in the dev environment before applying to prod.
- **REQ-006**: The existing `AZURE_OPENAI_ENDPOINT` env var is retained for `text-embedding-3-large` only. No OpenAI chat models are deployed or configured.
- **REQ-007**: Grok models require a separate `AZURE_AI_INFERENCE_ENDPOINT` environment variable pointing to the Azure AI Model Inference endpoint, and a custom provider entry in `openclaw.json.tpl`.
- **REQ-008**: After Grok is validated in dev, the existing `gpt-4o` (`main`) AI Foundry deployment must be removed from `ai_model_deployments` in Terraform.
- **SEC-001**: Model deployment names are non-secret and may appear in config and env vars. No deployment names are stored in Key Vault.
- **SEC-002**: Authentication to all model endpoints must use Managed Identity wherever Azure supports it. Static API keys are the fallback of last resort and must be explicitly justified.
- **SEC-003**: If Grok/AI Model Inference does not support Managed Identity, the API key must be stored in Key Vault and injected via the existing secret reference pattern — not hardcoded in any file.
- **CON-001**: Azure AI Foundry `GlobalStandard` TPM quota varies by model and region. Quota for `text-embedding-3-large`, `grok-4-fast-reasoning`, `grok-3`, and `grok-3-mini` must be confirmed in the dev subscription before implementation.
- **CON-002**: The `avm-ptn-aiml-ai-foundry` module is pinned at `~> 0.10`. The `format` field value for Grok (`xAI`) in `ai_model_deployments` must be confirmed before implementation.
- **CON-003**: The Azure AI Model Inference IAM role for Managed Identity access to Grok deployments must be confirmed before implementation. With no OpenAI chat fallback, this is a hard blocker.
- **CON-004**: Container App environment variable changes trigger a new revision. Adding the Grok endpoint env var will cause a revision rollout.
- **CON-005**: `grok-4` (non-fast) and `grok-code-fast-1` require pre-registration and are excluded. `grok-4-fast-reasoning` does not require pre-registration.
- **GUD-001**: One Terraform variable per model attribute (name, version, capacity). Do not bundle into complex-typed variables.
- **GUD-002**: Do not remove the `gpt-4o` deployment (`main` entry) until Grok is fully validated in dev. Remove it in the same PR that promotes to prod.
- **PAT-001**: OpenClaw model catalog entries follow `provider/model` format. The custom Grok provider id (`azure-foundry` or similar) must be chosen to avoid conflicts with OpenClaw's built-in provider catalog.

## 2. Implementation Steps

### Implementation Phase 1 — Confirm Open Questions

- GOAL-001: Resolve the three open questions that block implementation. All three must be answered and recorded here before any Terraform or config changes are made.

| Task     | Description                                                                                                                                                                                                                        | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | Confirm the IAM role required for Managed Identity to access the Azure AI Model Inference endpoint (Grok). Check Azure RBAC docs for `Microsoft.CognitiveServices` / AI Foundry resource roles. Determine if Managed Identity is supported or if API key is required. | ✅ | 2026-03-31 |
| TASK-002 | Confirm the `format` value for xAI Grok in the `avm-ptn-aiml-ai-foundry ~> 0.10` module's `ai_model_deployments` map. Review module source at `https://registry.terraform.io/modules/Azure/avm-ptn-aiml-ai-foundry/azurerm/latest`. | ✅ | 2026-03-31 |
| TASK-003 | Confirm the exact Azure AI Model Inference endpoint URL pattern for the existing AI Services account. Determine whether a separate Foundry resource endpoint or the existing account endpoint is used for Grok. | ✅ | 2026-03-31 |
| TASK-004 | Confirm `GlobalStandard` TPM quota available in the dev subscription/region for: `text-embedding-3-large`, `grok-4-fast-reasoning`, `grok-3`, `grok-3-mini`. | ⚠️ Requires portal | — |

### Implementation Phase 2 — Terraform: Embeddings Deployment

- GOAL-002: Add `text-embedding-3-large` as an Azure OpenAI deployment. This uses the existing endpoint and the confirmed `OpenAI` format — lower risk than Grok and can proceed as soon as TASK-004 confirms quota.

| Task     | Description                                                                                                                                                                                  | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-005 | In `terraform/variables.tf`, add `variable` blocks for the embedding model: `embedding_model_name`, `embedding_model_version`, `embedding_model_capacity`. | | |
| TASK-006 | In `terraform/ai.tf`, add one new entry to `ai_model_deployments` for `text-embedding-3-large` using `format = "OpenAI"` and `GlobalStandard` scale. | | |
| TASK-007 | In `scripts/dev.tfvars`, add default values for the three new embedding variables from TASK-005. | | |
| TASK-008 | Run `terraform plan` in dev. Verify: additive change only, no destroy/replace on existing Hub, Project, account, or `main` (gpt-4o) deployment. | | |

### Implementation Phase 3 — Terraform: Grok Deployments

- GOAL-003: Add `grok-4-fast-reasoning`, `grok-3`, and `grok-3-mini` deployments. This phase is fully blocked on Phase 1 (TASK-001 through TASK-003). Grok is the sole chat model — there is no fallback if this fails.

| Task     | Description                                                                                                                                                                                                  | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-009 | In `terraform/variables.tf`, add variable blocks for `grok4fast_model_name/version/capacity`, `grok3_model_name/version/capacity`, `grok3mini_model_name/version/capacity`. | ✅ | 2026-03-31 |
| TASK-010 | In `terraform/ai.tf`, add three Grok entries to `ai_model_deployments` using the confirmed `format` value from TASK-002. | ✅ N/A — Grok models are Azure AI Foundry MaaS (serverless) models. No Cognitive Services account deployment is created in Terraform; the models are accessed directly via `AZURE_AI_INFERENCE_ENDPOINT` using the model name in each request. A clarifying comment was added to `ai.tf`. | 2026-03-31 |
| TASK-011 | If TASK-001 determined Managed Identity is NOT supported for Grok: add a new Key Vault secret for the AI Model Inference API key in `terraform/keyvault.tf` and inject it via secret reference in `terraform/containerapp.tf` (same pattern as `openclaw-gateway-token`). Add the required IAM role assignment in `terraform/roleassignments.tf` if a different role is required. | ✅ Done — MI is not supported for this endpoint (see TASK-001 resolution). Key Vault secret `azure-ai-api-key` added in `keyvault.tf`; `AZURE_AI_API_KEY` injected via secret ref in `containerapp.tf`. | 2026-03-31 |
| TASK-012 | Run `terraform plan` in dev including Grok additions. Verify additive only; `gpt-4o` deployment is not yet removed at this stage. | ⬜ Pending deploy | — |

### Implementation Phase 4 — Container App: Environment Injection

- GOAL-004: Inject all new deployment names and the Grok inference endpoint into the Container App environment.

| Task     | Description                                                                                                                                                                       | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-013 | In `terraform/containerapp.tf`, add one `env` entry for the embedding deployment name (e.g. `AZURE_OPENAI_DEPLOYMENT_EMBEDDING`). | ✅ | 2026-03-31 |
| TASK-014 | In `terraform/containerapp.tf`, add `AZURE_AI_INFERENCE_ENDPOINT` env var pointing to the confirmed Grok endpoint URL (from TASK-003). | ✅ | 2026-03-31 |
| TASK-015 | In `terraform/containerapp.tf`, add `env` entries for each Grok deployment name under `containers[0].env`. | ✅ | 2026-03-31 |

### Implementation Phase 5 — OpenClaw Config Template

- GOAL-005: Update `config/openclaw.json.tpl` to declare the Grok-first model catalog with the custom provider, embeddings reference, and remove all OpenAI chat models.

| Task     | Description                                                                                                                                                                                                                        | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-016 | Add a `models.providers` block for the Grok custom provider (`azure-foundry` or similar), pointing `baseUrl` to `${AZURE_AI_INFERENCE_ENDPOINT}`, using `openai-completions` or `openai-responses` API adapter, and setting `apiKey` via the confirmed auth mechanism from TASK-001. | ✅ | 2026-03-31 |
| TASK-017 | Add an `agents.defaults.models` catalog block listing: `azure-foundry/grok-4-fast-reasoning` (alias `grok`), `azure-foundry/grok-3` (alias `grok-3`), `azure-foundry/grok-3-mini` (alias `grok-mini`). | ✅ | 2026-03-31 |
| TASK-018 | Set `agents.defaults.model.primary` to `"azure-foundry/grok-4-fast-reasoning"` and `fallbacks` to `["azure-foundry/grok-3"]`. | ✅ | 2026-03-31 |
| TASK-019 | If TASK-001 confirmed Managed Identity is supported for Grok, configure `auth: "token"` (Azure AD token) in the custom provider block instead of an API key string. | ✅ Resolved as api-key — MI not supported for this endpoint. `auth: "api-key"` is used in `openclaw.json.tpl`; `apiKey` references `${AZURE_AI_API_KEY}` injected from Key Vault. | 2026-03-31 |
| TASK-020 | Remove all OpenAI chat model entries (`gpt-4o`, `gpt-4.1`, etc.) from the config template. Retain `AZURE_OPENAI_ENDPOINT` reference only for the embedding deployment name env var. | ✅ N/A — no OpenAI chat was in the previous template | 2026-03-31 |

### Implementation Phase 6 — Decommission gpt-4o

- GOAL-006: Remove the `gpt-4o` deployment after Grok is validated in dev. Do not do this before TASK-026 is completed.

| Task     | Description                                                                                                                                                                   | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-021 | In `terraform/ai.tf`, remove the `main` entry (gpt-4o) from `ai_model_deployments`. Remove the corresponding `ai_model_name`, `ai_model_version`, `ai_model_capacity` variables from `terraform/variables.tf` and `scripts/dev.tfvars`. | | |
| TASK-022 | In `terraform/containerapp.tf`, remove the `AZURE_OPENAI_ENDPOINT` env var if it is no longer needed for anything other than embeddings — or rename/repurpose it if the embedding provider still uses it. | | |
| TASK-023 | Run `terraform plan` in dev. Verify the gpt-4o deployment is planned for deletion. Confirm no impact on Hub, Project, or other deployments. | | |

### Implementation Phase 7 — Outputs

- GOAL-007: Expose new deployment names as Terraform outputs.

| Task     | Description                                                                                                        | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-024 | Add non-sensitive output blocks in `terraform/outputs.tf` for each new Grok deployment name and the embedding deployment name. | ✅ | 2026-03-31 |

### Implementation Phase 8 — Validation

- GOAL-008: Apply to dev, verify end-to-end for all model groups, then promote to prod.

| Task     | Description                                                                                                                                                               | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-025 | Apply Terraform to dev (Phases 2–5 together, before Phase 6). Confirm the embedding and all three Grok deployments appear in the Azure AI Foundry portal. | | |
| TASK-026 | Verify the Container App revision started and all new env vars are present. | | |
| TASK-027 | Test `grok-4-fast-reasoning` as the default model — send a test prompt without switching models. Verify it responds. | | |
| TASK-028 | Switch to `grok-3` and `grok-3-mini` via `/model`. Verify both respond. | | |
| TASK-029 | Confirm the embedding deployment exists in Azure AI Foundry portal. (Full functional embedding test depends on OpenClaw memory/RAG tool configuration.) | | |
| TASK-030 | Apply Phase 6 (decommission gpt-4o) to dev. Confirm no regressions. Verify gpt-4o deployment is gone from portal. | | |
| TASK-031 | Apply full change set to prod via the standard GitHub Actions `terraform-prod` workflow (PR merge to `main`). | | |

## 3. Alternatives

- **ALT-001**: **Keep gpt-4o or upgrade to gpt-4.1 as primary, add Grok as optional** — Lower risk: if Grok IAM is unresolvable, the user still has a working primary model. Rejected per user intent: Grok is the desired primary, and having OpenAI chat only as a bridge model adds configuration debt.
- **ALT-002**: **DeepSeek instead of Grok** — Also available via the Azure AI Model Inference endpoint with the same architecture. Grok chosen for English performance and reasoning capability in a personal assistant use case.
- **ALT-003**: **Single complex-typed Terraform variable for all models** — Rejected: existing pattern uses simple scalars; a map increases `dev.tfvars` complexity.
- **ALT-004**: **Hardcode deployment names in `openclaw.json.tpl`** — Deployment names are stable and non-secret, so technically valid. Rejected in favor of `${VAR}` substitution to keep Terraform variables as the single source of truth.
- **ALT-005**: **OpenRouter as a proxy for Grok** — OpenClaw has built-in `openrouter` provider support. This would avoid the Azure AI Model Inference endpoint complexity entirely, at the cost of routing traffic outside the private Azure environment and losing Managed Identity auth. Inconsistent with the private Azure architecture. Rejected.
- **ALT-006**: **Grok API key in Key Vault (if Managed Identity unsupported)** — If TASK-001 confirms Managed Identity is not available for the AI Model Inference endpoint, storing the xAI API key in Key Vault and injecting it via secret reference is the path forward. This adds one new Key Vault secret and one Container App secret ref but is otherwise consistent with the existing pattern for `openclaw-gateway-token`.

## 4. Dependencies

- **DEP-001**: `avm-ptn-aiml-ai-foundry ~> 0.10` — must support non-OpenAI `format` values in `ai_model_deployments` for Grok (to be confirmed in TASK-002).
- **DEP-002**: Azure AI Foundry `GlobalStandard` quota for `text-embedding-3-large`, `grok-4-fast-reasoning`, `grok-3`, `grok-3-mini` in target region (to be confirmed in TASK-004).
- **DEP-003**: Azure RBAC role supporting Managed Identity access to the Azure AI Model Inference endpoint for Grok (to be confirmed in TASK-001). Hard blocker — no chat fallback exists if unresolved.
- **DEP-004**: OpenClaw custom provider `api` adapter compatibility with the Azure AI Model Inference API for Grok (to be confirmed once TASK-003 establishes the endpoint URL).

## 5. Files

- **FILE-001**: `terraform/variables.tf` — add embedding and Grok variables; remove `ai_model_name/version/capacity` variables (gpt-4o) after validation.
- **FILE-002**: `terraform/ai.tf` — add embedding and Grok entries to `ai_model_deployments`; remove `main` (gpt-4o) entry after validation.
- **FILE-003**: `terraform/containerapp.tf` — add embedding deployment name env var, `AZURE_AI_INFERENCE_ENDPOINT`, and Grok deployment name env vars.
- **FILE-004**: `config/openclaw.json.tpl` — replace OpenAI chat config with Grok custom provider block; update primary model to `grok-4-fast-reasoning`.
- **FILE-005**: `scripts/dev.tfvars` — add embedding and Grok variable defaults; remove gpt-4o defaults after validation.
- **FILE-006**: `terraform/outputs.tf` — add Grok and embedding deployment name outputs.
- **FILE-007**: `terraform/keyvault.tf` — (conditional) new Key Vault secret for Grok/AI Model Inference API key if Managed Identity is unsupported.
- **FILE-008**: `terraform/roleassignments.tf` — (conditional) new role assignment if a different IAM role is required for the AI Model Inference endpoint.

## 6. Testing

- **TEST-001**: `terraform plan` (Phases 2–5) produces only additive changes. No destroy/replace on Hub, Project, account, or `main` (gpt-4o) deployment.
- **TEST-002**: `text-embedding-3-large`, `grok-4-fast-reasoning`, `grok-3`, and `grok-3-mini` all appear in Azure AI Foundry portal after apply.
- **TEST-003**: All new env vars present in the running Container App revision.
- **TEST-004**: `grok-4-fast-reasoning` is the default model — responds to a test prompt without any `/model` switch.
- **TEST-005**: `/model grok-3` and `/model grok-mini` both return valid responses.
- **TEST-006**: `terraform plan` (Phase 6) shows gpt-4o deployment planned for deletion with no other impact.
- **TEST-007**: After Phase 6, gpt-4o deployment is absent from Azure AI Foundry portal and its env vars are absent from the Container App.

## 7. Risks & Assumptions

- **RISK-001**: **Managed Identity not supported for Azure AI Model Inference (Grok)** — With no OpenAI chat fallback, this becomes a project blocker, not just a constraint. Mitigation: confirm in TASK-001 before any Grok Terraform work. If Managed Identity is unsupported, invoke ALT-006 (Key Vault API key), which is consistent with the existing secrets pattern.
- **RISK-002**: **AVM module does not support non-OpenAI format values** — The module may only support `format = "OpenAI"`. Mitigation: confirm in TASK-002. If unsupported, Grok deployments may need a raw `azurerm_cognitive_account_deployment` resource alongside the AVM module.
- **RISK-003**: **GlobalStandard quota is zero for Grok in target region** — xAI models are newer and quota may not be pre-allocated. Mitigation: confirm in TASK-004. Request a quota increase if needed before starting Phase 3.
- **RISK-004**: **OpenClaw custom provider `api` adapter incompatible with Azure AI Model Inference** — The API is described as OpenAI-compatible, but auth headers or model routing may differ. Mitigation: test reachability with a direct `curl` from a terminal before updating the config template.
- **RISK-005**: **Adding/removing deployments triggers Hub or Project recreation in AVM module** — Mitigation: review `terraform plan` output (TASK-008, TASK-012, TASK-023) before every `apply`.
- **ASSUMPTION-001**: The same `AZURE_OPENAI_ENDPOINT` used today covers `text-embedding-3-large` since both are Azure OpenAI format deployments on the same AI Services account.
- **ASSUMPTION-002**: The Azure AI Model Inference endpoint for Grok is a different URL from `AZURE_OPENAI_ENDPOINT` and requires a separate `AZURE_AI_INFERENCE_ENDPOINT` env var.
- **ASSUMPTION-003**: The persistent Azure Files share at `/home/node/.openclaw` contains a seeded `openclaw.json`. The `openclaw.json.tpl` in this repo is a reference template; the live config on the share must be updated separately after template changes (e.g., via `openclaw configure` or direct file edit via the CLI).
- **ASSUMPTION-004**: `grok-4-fast-reasoning` is available in the region where the AI Services account is deployed. The model is listed as `GlobalStandard` in all regions, so this should hold.

## 8. Related Specifications / Further Reading

- [ARCHITECTURE.md](../ARCHITECTURE.md) — AI and Observability section; Managed Identity Role Assignments table.
- [config/openclaw.json.tpl](../config/openclaw.json.tpl) — current gateway config template.
- [terraform/ai.tf](../terraform/ai.tf) — current AI Foundry module configuration.
- [terraform/containerapp.tf](../terraform/containerapp.tf) — current Container App env injection.
- OpenClaw configuration reference: `https://docs.openclaw.ai/gateway/configuration-reference`
- Azure AI Foundry models (OpenAI): `https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure?pivots=azure-openai`
- Azure AI Foundry models (other, including xAI Grok): `https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure?pivots=azure-direct-others`
- AVM pattern module source: `https://registry.terraform.io/modules/Azure/avm-ptn-aiml-ai-foundry/azurerm/latest`
- xAI Grok pre-registration (grok-4 only): `https://aka.ms/xai/grok-4`
