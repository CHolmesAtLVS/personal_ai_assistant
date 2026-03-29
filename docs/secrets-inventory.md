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
| `BUDGET_ALERT_EMAIL` | Email address for budget overage notifications | On contact change | Platform Engineering |
| `PUBLIC_IP` | Home public IP in CIDR form for Container App ingress restriction | On IP change | Platform Engineering |
| `VM_ADMIN_PASSWORD` | Administrator password for the Windows dev VM — **dev environment only** | On rotation | Platform Engineering |

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
| `TF_VAR_CONTAINER_IMAGE_TAG` | Container image tag to deploy (default: `latest`) | Per release | Platform Engineering |
| `TF_VAR_ENABLE_DEV_VM` | Set to `true` in the `dev` GitHub Environment to provision the Windows dev VM (default: `false`) — **dev environment only** | On demand | Platform Engineering |

> **Note:** `TF_VAR_ENVIRONMENT` is hardcoded per job in the CI workflow (`dev` or `prod`) and does not need to be set as a GitHub Environment variable.

## Policy Notes

- Personal details are secrets and must remain in GitHub Secrets only.
- Azure deployment identifiers are treated as sensitive operational metadata and must not be committed.
- CI logs must be reviewed to ensure no secret values are echoed.
- Pull requests are plan-only for both environments; apply must not run on PR events.
- Non-main push events use `dev` environment secrets/vars for auto-apply.
- `main` push events use `prod` environment secrets/vars and remain subject to prod environment protections.

## Managed Identity Access Patterns

The Container App's User-Assigned Managed Identity is the exclusive authentication mechanism for all Azure service access. No API keys, SAS tokens, or service-specific credentials are stored or used.

| Access Path | Role | Notes |
| ----------- | ---- | ----- |
| Azure Container Registry (pull) | AcrPull | Prod only; dev uses a public placeholder image |
| Azure Key Vault (secret read) | Key Vault Secrets User | All environments |
| Azure AI Services (OpenAI inference) | Cognitive Services OpenAI User | All environments |

**AI API keys are never generated, stored, or rotated.** The AI Services endpoint URL is a non-sensitive value injected as a container environment variable (`AZURE_OPENAI_ENDPOINT`) by Terraform at deploy time. Authentication to AI Services is performed exclusively via Managed Identity token exchange at runtime.

## Container App Runtime Environment Variables

The following non-sensitive values are injected as container environment variables by Terraform. They are not secrets and do not need to be stored in Key Vault or GitHub Secrets.

| Variable | Source | Description |
| -------- | ------ | ----------- |
| `AZURE_OPENAI_ENDPOINT` | Terraform output from AI Services (`azapi_resource` read) | AI Services endpoint URL for OpenAI inference |
| `OPENCLAW_GATEWAY_BIND` | Hardcoded `lan` | Instructs OpenClaw to bind its gateway to the LAN interface |
