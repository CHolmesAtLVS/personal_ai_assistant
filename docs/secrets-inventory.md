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

## Required GitHub Environment Variables

Configure these as environment variables (`vars`) in both `dev` and `prod` GitHub Environments.

| Variable Name | Purpose | Rotation Cadence | Owner |
| --- | --- | --- | --- |
| `TF_VAR_PROJECT` | Terraform `project` input | On naming convention change | Platform Engineering |
| `TF_VAR_ENVIRONMENT` | Terraform `environment` input (`dev` or `prod`) | Rarely | Platform Engineering |
| `TF_VAR_LOCATION` | Terraform `location` input | On environment change | Platform Engineering |
| `TF_VAR_OWNER` | Terraform `owner` tag input | On ownership change | Platform Engineering |
| `TF_VAR_COST_CENTER` | Terraform `cost_center` tag input | On finance change | Platform Engineering |
| `MONTHLY_BUDGET_AMOUNT` | Monthly USD budget cap for the resource group (number) | On budget review | Platform Engineering |

## Policy Notes

- Personal details are secrets and must remain in GitHub Secrets only.
- Azure deployment identifiers are treated as sensitive operational metadata and must not be committed.
- CI logs must be reviewed to ensure no secret values are echoed.
- Pull requests are plan-only for both environments; apply must not run on PR events.
- Non-main push events use `dev` environment secrets/vars for auto-apply.
- `main` push events use `prod` environment secrets/vars and remain subject to prod environment protections.
