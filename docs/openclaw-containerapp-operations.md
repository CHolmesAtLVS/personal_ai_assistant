# OpenClaw Container App Operations Runbook

This document covers operational procedures for the OpenClaw Container App runtime: first-time bootstrap, gateway token management, config updates, storage backup/restore, and image upgrades.

## Prerequisites

- Azure CLI authenticated with sufficient permissions on the environment resource group
- Access to the Key Vault in the environment resource group
- Terraform state is healthy and `terraform plan` shows no unexpected drift

---

## 1. First-Time Bootstrap

### 1.1 Create the Gateway Token Secret in Key Vault

Before the first Terraform apply (or before the Container App starts), provision the gateway token in Key Vault. Generate a strong random token, then store it under the canonical secret name `openclaw-gateway-token`:

```bash
# Generate a 48-character random token
TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(24))")

# Store in Key Vault (replace <kv-name> with the environment Key Vault name)
az keyvault secret set \
  --vault-name "<kv-name>" \
  --name "openclaw-gateway-token" \
  --value "$TOKEN"
```

The Container App's Managed Identity has `Key Vault Secrets User` access and will read this secret at startup. Terraform references the secret by its versionless URI; no token value passes through Terraform or CI.

### 1.2 Run Terraform Apply

After the secret is created, run Terraform to provision or update the Container App:

```bash
# Via CI: open a PR to trigger terraform-dev, or merge to main for terraform-prod
# Locally (dev only):
cd terraform
terraform init -backend-config=../scripts/backend.dev.hcl
terraform apply -var-file=../scripts/dev.tfvars
```

### 1.3 Seed the Gateway Configuration File

OpenClaw reads its gateway configuration from `/home/node/.openclaw/openclaw.json` on the persistent Azure Files share. The file must exist with a schema-valid baseline before the app successfully starts under strict config validation.

**Method: Pre-seed via Azure Files (recommended)**

Use the Azure CLI to upload the config file directly to the Azure Files share before the Container App starts:

```bash
# Replace placeholders with actual values from Terraform outputs
STORAGE_ACCOUNT=$(terraform -chdir=terraform output -raw openclaw_state_storage_account_name)
SHARE_NAME=$(terraform -chdir=terraform output -raw openclaw_state_file_share_name)

# Retrieve the storage account key
STORAGE_KEY=$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "<env-resource-group>" \
  --query "[0].value" --output tsv)

# Retrieve the current gateway token from Key Vault
GATEWAY_TOKEN=$(az keyvault secret show \
  --vault-name "<kv-name>" \
  --name "openclaw-gateway-token" \
  --query "value" --output tsv)

# Retrieve the Container App FQDN
APP_FQDN=$(terraform -chdir=terraform output -raw container_app_fqdn 2>/dev/null || echo "https://<app-fqdn>")

# Write the openclaw.json config
cat > /tmp/openclaw.json <<EOF
{
  "gateway": {
    "mode": "server",
    "port": 18789,
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "${GATEWAY_TOKEN}"
    },
    "controlUi": {
      "allowedOrigins": ["${APP_FQDN}"]
    }
  }
}
EOF

# Upload to Azure Files
az storage file upload \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --share-name "$SHARE_NAME" \
  --source /tmp/openclaw.json \
  --path "openclaw.json"

# Clean up local copy
rm /tmp/openclaw.json
```

> **Security note:** The gateway token value appears in the config file stored on the Azure Files share. Ensure the share is not publicly accessible (default: `public_network_access_enabled = true` with no anonymous access, protected by storage account key and SAS). Access is further limited by the Container Apps Environment network boundary.

#### Rollback for config seed step

If the config file was seeded with incorrect values, re-upload the corrected file using the same `az storage file upload` command. The Container App will pick up the new config on the next restart or revision deployment.

---

## 2. Gateway Token Rotation

To rotate the gateway token without data loss or downtime:

```bash
# 1. Generate a new token
NEW_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(24))")

# 2. Update the Key Vault secret (the Container App reads the versionless URI and will get the new value)
az keyvault secret set \
  --vault-name "<kv-name>" \
  --name "openclaw-gateway-token" \
  --value "$NEW_TOKEN"

# 3. Update the config file on the Azure Files share with the new token
STORAGE_ACCOUNT=$(terraform -chdir=terraform output -raw openclaw_state_storage_account_name)
SHARE_NAME=$(terraform -chdir=terraform output -raw openclaw_state_file_share_name)
STORAGE_KEY=$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "<env-resource-group>" \
  --query "[0].value" --output tsv)

# Download current config, update token, re-upload
az storage file download \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --share-name "$SHARE_NAME" \
  --path "openclaw.json" \
  --dest /tmp/openclaw.json

# Edit /tmp/openclaw.json to replace the token value, then re-upload
az storage file upload \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --share-name "$SHARE_NAME" \
  --source /tmp/openclaw.json \
  --path "openclaw.json"
rm /tmp/openclaw.json

# 4. Restart the Container App to reload the KV secret and pick up the new config
az containerapp revision restart \
  --name "<app-name>" \
  --resource-group "<env-resource-group>" \
  --revision "<active-revision-name>"
```

> **Note:** Azure Container Apps refreshes secrets from Key Vault when the Container App restarts or deploys a new revision. A manual restart is required for the token rotation to take immediate effect.

---

## 3. Gateway Configuration Updates

To update gateway settings (for example, adding an allowed origin):

```bash
STORAGE_ACCOUNT=$(terraform -chdir=terraform output -raw openclaw_state_storage_account_name)
SHARE_NAME=$(terraform -chdir=terraform output -raw openclaw_state_file_share_name)
STORAGE_KEY=$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "<env-resource-group>" \
  --query "[0].value" --output tsv)

# Download, edit, re-upload
az storage file download \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --share-name "$SHARE_NAME" \
  --path "openclaw.json" \
  --dest /tmp/openclaw.json

# Edit /tmp/openclaw.json with desired changes, validate JSON, then re-upload
python3 -m json.tool /tmp/openclaw.json > /dev/null && echo "JSON valid"

az storage file upload \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --share-name "$SHARE_NAME" \
  --source /tmp/openclaw.json \
  --path "openclaw.json"
rm /tmp/openclaw.json
```

After re-uploading the config, restart the Container App revision for the changes to take effect.

If adding an origin to `controlUi.allowedOrigins`, also update `TF_VAR_OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS_JSON` in the GitHub Environment variable so Terraform keeps the value in sync with the `OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS` environment variable injected into the container.

---

## 4. State Backup and Restore

The Azure Files share holds all persistent OpenClaw state under `/home/node/.openclaw`. Key paths:

| Path | Contents |
|------|----------|
| `openclaw.json` | Gateway and runtime configuration |
| `auth/` | Authentication profiles |
| `skills/` | Installed skills state |
| `workspace/` | Session workspace files |
| `cron/runs/` | Scheduled task run logs |
| `media/` | Uploaded media files |
| `logs/` | Application log files |

### 4.1 Backup

Use AzCopy or `az storage file` to snapshot the share contents:

```bash
STORAGE_ACCOUNT=$(terraform -chdir=terraform output -raw openclaw_state_storage_account_name)
SHARE_NAME=$(terraform -chdir=terraform output -raw openclaw_state_file_share_name)
STORAGE_KEY=$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "<env-resource-group>" \
  --query "[0].value" --output tsv)

BACKUP_DIR="./openclaw-backup-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"

azcopy copy \
  "https://${STORAGE_ACCOUNT}.file.core.windows.net/${SHARE_NAME}/*?$(az storage account generate-sas \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$STORAGE_KEY" \
    --services f --resource-types co \
    --permissions rl --expiry "$(date -u -d '+1 hour' '+%Y-%m-%dT%H:%MZ')" \
    --output tsv)" \
  "$BACKUP_DIR" \
  --recursive
```

### 4.2 Restore

```bash
azcopy copy \
  "$BACKUP_DIR/*" \
  "https://${STORAGE_ACCOUNT}.file.core.windows.net/${SHARE_NAME}/?<sas-token>" \
  --recursive
```

After restoring, restart the Container App revision to reload the configuration from the restored state.

---

## 5. Image Upgrades

OpenClaw uses a pinned image tag defined in `terraform/variables.tf` as `openclaw_image_tag` (default: `2026.2.26`). To upgrade:

### 5.1 Upgrade procedure

1. Identify the new pinned tag from the [OpenClaw GHCR release page](https://github.com/openclaw/openclaw/pkgs/container/openclaw).
2. Update the `TF_VAR_OPENCLAW_IMAGE_TAG` GitHub Environment variable to the new tag value.
3. Open a pull request — the `terraform-dev` CI job will plan the change showing only the image tag change.
4. Confirm the plan shows only the expected image change, then merge to apply to prod.

### 5.2 Image tag via tfvars (local dev only)

```bash
# In scripts/dev.tfvars, set:
# TF_VAR_openclaw_image_tag = "2026.x.x"
```

**Do not use `latest` or any mutable tag.** The `openclaw_image_tag` variable has a validation rule that rejects `latest`.

### 5.3 Rollback

To roll back to the previous tag, revert the `TF_VAR_OPENCLAW_IMAGE_TAG` variable to the previous pinned value and apply. No persistent state is affected by a tag-only change — the Azure Files share remains mounted and intact across revisions.

---

## 6. Health Probe Endpoints

The Container App runtime configures health probes at:

| Probe | Endpoint | Port |
|-------|----------|------|
| Liveness | `/healthz` | 18789 |
| Readiness | `/readyz` | 18789 |

If the liveness probe fails repeatedly, the Container App platform restarts the container. If the readiness probe fails, the replica is removed from the ingress rotation. Both probes run over HTTP against the container's internal port.
