# Secrets Inventory

This repository uses GitHub Secrets for all sensitive values and personal deployment details.
No secret values, deployment identifiers, or personal details are committed to source control.

## Required GitHub Environment Secrets

Create these secrets in both `dev` and `prod` GitHub Environments unless intentionally different per environment.

| Secret Name | Purpose | Rotation Cadence | Owner |
| --- | --- | --- | --- |
| `AZURE_TENANT_ID` | Service Principal tenant scope for CI login | 180 days or on incident | Platform Engineering |
| `AZURE_SUBSCRIPTION_ID` | Target subscription for CI operations | On environment change | Platform Engineering |
| `AZURE_CLIENT_ID` | Service Principal application ID for CI login | On principal replacement | Platform Engineering |
| `AZURE_CLIENT_SECRET` | Service Principal credential for CI login | 90 days or less | Platform Engineering |
| `AZURE_SP_NAME` | Display name of the CI Service Principal (informational) | On principal rename | Platform Engineering |
| `TFSTATE_RG` | Terraform state resource group name | On backend redesign | Platform Engineering |
| `TFSTATE_LOCATION` | Azure region for state backend resources | Rarely; on migration | Platform Engineering |
| `TFSTATE_STORAGE_ACCOUNT` | Storage account name for Terraform state | On backend redesign | Platform Engineering |
| `TFSTATE_CONTAINER` | Blob container name for Terraform state | On backend redesign | Platform Engineering |
| `TFSTATE_KEY` | Terraform state key path/name | On state partition redesign | Platform Engineering |
| `TF_VAR_AZURE_AI_API_KEY` | Azure AI Foundry account API key; stored in Key Vault as `azure-ai-api-key`, injected as `AZURE_AI_API_KEY` in the Container App. **Required on every Terraform apply** — see note below. | On key rotation or incident | Platform Engineering |
| `BUDGET_ALERT_EMAIL` | Email address for budget overage notifications | On contact change | Platform Engineering |
| `PUBLIC_IP` | Home public IP in CIDR form for Container App ingress restriction | On IP change | Platform Engineering |

## Required GitHub Environment Variables

Configure these as environment variables (`vars`) in both `dev` and `prod` GitHub Environments.

| Variable Name | Purpose | Rotation Cadence | Owner |
| --- | --- | --- | --- |
| `TF_VAR_PROJECT` | Terraform `project` input | On naming convention change | Platform Engineering |
| `TF_VAR_LOCATION` | Terraform `location` input | On environment change | Platform Engineering |
| `TF_VAR_OWNER` | Terraform `owner` tag input | On ownership change | Platform Engineering |
| `TF_VAR_COST_CENTER` | Terraform `cost_center` tag input | On finance change | Platform Engineering |
| `TF_VAR_MONTHLY_BUDGET_AMOUNT` | Monthly USD budget cap for the resource group (number) | On budget review | Platform Engineering |
| `TF_VAR_AI_MODEL_NAME` | AI model name to deploy (default: `gpt-4o`) | On model change | Platform Engineering |
| `TF_VAR_AI_MODEL_VERSION` | AI model version (default: `2024-11-20`) | On model change | Platform Engineering |
| `TF_VAR_AI_MODEL_CAPACITY` | Model deployment TPM capacity in thousands (default: `10`) | On quota change | Platform Engineering |
| `TF_VAR_OPENCLAW_IMAGE_TAG` | Pinned OpenClaw image tag to deploy (default: `2026.2.26`) | Per release | Platform Engineering |
| `TF_VAR_OPENCLAW_STATE_SHARE_QUOTA_GB` | Azure Files share quota in GiB for persisted OpenClaw state (default: `100`) | On storage review | Platform Engineering |
| `TF_VAR_EMBEDDING_MODEL_NAME` | Embedding deployment name (default: `text-embedding-3-large`) | On model change | Platform Engineering |
| `TF_VAR_EMBEDDING_MODEL_VERSION` | Embedding model version (default: `1`) | On model change | Platform Engineering |
| `TF_VAR_EMBEDDING_MODEL_CAPACITY` | Embedding TPM capacity in thousands (default: `50`) | On quota change | Platform Engineering |
| `TF_VAR_GROK4FAST_MODEL_NAME` | grok-4-fast-reasoning model name for env var injection (default: `grok-4-fast-reasoning`) | On model change | Platform Engineering |
| `TF_VAR_GROK3_MODEL_NAME` | grok-3 model name for env var injection (default: `grok-3`) | On model change | Platform Engineering |
| `TF_VAR_GROK3MINI_MODEL_NAME` | grok-3-mini model name for env var injection (default: `grok-3-mini`) | On model change | Platform Engineering |

## Policy Notes

- Personal details are secrets and must remain in GitHub Secrets only.
- Azure deployment identifiers are treated as sensitive operational metadata and must not be committed.
- CI logs must be reviewed to ensure no secret values are echoed.
- Pull requests are plan-only for both environments; apply must not run on PR events.
- Non-main push events use `dev` environment secrets/vars for auto-apply.
- `main` push events use `prod` environment secrets/vars and remain subject to prod environment protections.

> **⚠️ TF_VAR_AZURE_AI_API_KEY must be set in both GitHub Environments before any Terraform apply.**
> Although the `azure-ai-api-key` Key Vault secret uses `lifecycle { ignore_changes = [value] }` (preventing overwrite after first apply), Terraform **variable validation** still runs on every apply. An empty or missing `TF_VAR_AZURE_AI_API_KEY` secret will fail the workflow immediately with `azure_ai_api_key must not be empty`.
> The workflow includes a preflight step that catches this early with a clear error. For local runs, set `TF_VAR_azure_ai_api_key` in `scripts/dev.tfvars` or `scripts/prod.tfvars`.

## Key Vault-Managed Runtime Secrets

The following secrets are provisioned in Azure Key Vault by Terraform. The Container App reads them at runtime via its Managed Identity.

> **Note:** `azure-ai-api-key` is seeded from `TF_VAR_azure_ai_api_key` on first apply (stored in Terraform remote state, sensitive output, encrypted at rest). Subsequent applies do not overwrite the Key Vault secret value due to `lifecycle { ignore_changes = [value] }`, but the Terraform variable must still be provided and non-empty on every apply. The `openclaw-gateway-token` is generated by Terraform (`random_id`) and is also present in state.

| Secret Name (Key Vault) | Purpose | Rotation Cadence | Owner |
| --- | --- | --- | --- |
| `openclaw-gateway-token` | Authentication token for the OpenClaw gateway. Created and managed by Terraform (`azurerm_key_vault_secret` + `random_id`). The value is stored in Terraform remote state (sensitive, encrypted at rest). Never overwritten by subsequent applies; manual rotation is preserved via `lifecycle { ignore_changes = [value] }`. | On compromise or scheduled rotation | Platform Engineering |
| `azure-ai-api-key` | API key for the Azure AI Foundry account. Set via `TF_VAR_AZURE_AI_API_KEY` on first apply; never overwritten by subsequent applies (`lifecycle { ignore_changes = [value] }`). Injected as `AZURE_AI_API_KEY` into the Container App and referenced in `openclaw.json` as `${AZURE_AI_API_KEY}` for the `azure-foundry` model provider. | On key rotation or incident | Platform Engineering |

See [openclaw-containerapp-operations.md](openclaw-containerapp-operations.md) for provisioning and rotation procedures.

## Managed Identity Access Patterns

The Container App's User-Assigned Managed Identity is the authentication mechanism for Azure service access that does not use API keys. The `azure-foundry` model provider uses API key auth (`AZURE_AI_API_KEY` from Key Vault) rather than Managed Identity.

| Access Path | Role | Notes |
| ----------- | ---- | ----- |
| Azure Container Registry (pull) | AcrPull | Prod only; dev uses a public placeholder image |
| Azure Key Vault (secret read) | Key Vault Secrets User | All environments |
| Azure AI Services (OpenAI inference) | Cognitive Services OpenAI User | All environments — used for the embedding deployment (`text-embedding-3-large`) |

## CI/CD Service Principal Access Patterns

The CI/CD Service Principal (used by GitHub Actions) has the following data-plane permissions beyond its ARM Contributor role.

| Access Path | Role | Notes |
| ----------- | ---- | ----- |
| Azure Key Vault (secret write) | Key Vault Secrets Officer | Allows Terraform to create and manage `openclaw-gateway-token`. Granted by Terraform via `azurerm_role_assignment.ci_sp_kv_secrets_officer`. |

**AI API keys are managed via Key Vault.** The `azure-ai-api-key` secret is seeded via Terraform from `TF_VAR_azure_ai_api_key` and injected into the Container App as `AZURE_AI_API_KEY`. It is used by the `azure-foundry` provider in `openclaw.json` for Grok model access via the Azure AI Model Inference endpoint. The Azure OpenAI embedding endpoint continues to use Managed Identity.

## Container App Runtime Environment Variables

The following non-sensitive values are injected as container environment variables by Terraform. They are not secrets and do not need to be stored in Key Vault or GitHub Secrets.

| Variable | Source | Description |
| -------- | ------ | ----------- |
| `AZURE_OPENAI_ENDPOINT` | Terraform output from AI Services (`azapi_resource` read) | AI Services endpoint URL for the OpenAI embedding deployment |
| `AZURE_AI_INFERENCE_ENDPOINT` | Terraform local `ai_inference_endpoint` | Azure AI Model Inference endpoint URL (`/models` appended) for Grok MaaS model access |
| `AZURE_OPENAI_DEPLOYMENT_EMBEDDING` | Terraform variable `embedding_model_name` | Deployment name for the `text-embedding-3-large` embedding model |
| `AZURE_AI_DEPLOYMENT_GROK4FAST` | Terraform variable `grok4fast_model_name` | Model name for `grok-4-fast-reasoning` (MaaS — passed as request model identifier) |
| `AZURE_AI_DEPLOYMENT_GROK3` | Terraform variable `grok3_model_name` | Model name for `grok-3` (MaaS) |
| `AZURE_AI_DEPLOYMENT_GROK3MINI` | Terraform variable `grok3mini_model_name` | Model name for `grok-3-mini` (MaaS) |
| `OPENCLAW_GATEWAY_PORT` | Hardcoded `18789` | Gateway listen port; ensures the correct port is used even before `openclaw.json` is seeded |
| `OPENCLAW_GATEWAY_TOKEN` | Key Vault secret reference (`openclaw-gateway-token`) | Gateway authentication token; read from Key Vault by the Container App at startup via Managed Identity |
| `AZURE_AI_API_KEY` | Key Vault secret reference (`azure-ai-api-key`) | API key for the Azure AI Model Inference endpoint; used by `openclaw.json` `azure-foundry` provider |
