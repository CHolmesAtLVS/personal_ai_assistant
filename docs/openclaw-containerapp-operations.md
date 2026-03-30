# OpenClaw Container App Operations Runbook

This document covers operational procedures for the OpenClaw Container App runtime: first-time bootstrap, gateway token management, config updates, storage backup/restore, and image upgrades.

## Prerequisites

- Azure CLI authenticated with sufficient permissions on the environment resource group
- Access to the Key Vault in the environment resource group
- Terraform state is healthy and `terraform plan` shows no unexpected drift

> **Environment safety:** Unless performing an authorized production incident response, always execute these procedures against the **dev** environment first. Validate the outcome in dev before applying to prod. AI agents must only be directed to operate against dev resources; do not supply production resource names to an AI agent during a troubleshooting or debugging session.

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

The Container App's Managed Identity has `Key Vault Secrets User` access and will read this secret at startup.

> **Note:** Gateway token injection in the Container App is controlled by the `openclaw_gateway_token_enabled` Terraform variable (default: `false`). This two-phase design lets Terraform apply succeed before the KV secret exists. Once the secret is provisioned (step 1.1), set `TF_VAR_OPENCLAW_GATEWAY_TOKEN_ENABLED=true` in the GitHub Environment variable and re-apply to activate the injection.

### 1.2 Run Terraform Apply

After the secret is created, set `TF_VAR_OPENCLAW_GATEWAY_TOKEN_ENABLED=true` in the GitHub Environment variable, then run Terraform to provision or update the Container App:

```bash
# Via CI: open a PR to trigger terraform-dev, or merge to main for terraform-prod
# Locally (dev only): uses scripts/dev.tfvars (copied from scripts/dev.tfvars.example)
./scripts/terraform-local.sh dev apply
```

### 1.3 Seed the Gateway Configuration File

OpenClaw reads its gateway configuration from `/home/node/.openclaw/openclaw.json` on the persistent Azure Files share. The file must exist with a schema-valid baseline before the app successfully starts under strict config validation.

**Normal path (automated):** The `Seed OpenClaw Config` step in the `terraform-deploy.yml` workflow automatically renders `config/openclaw.json.tpl` (using `envsubst` for `${APP_FQDN}`) and uploads it to the Azure Files share after every `terraform apply`. No manual action is required for routine deployments.

**Emergency recovery only:** If the automated seed step fails or the file is corrupt, use the following manual procedure to re-seed:

```bash
# Replace placeholders with actual values from Terraform outputs
STORAGE_ACCOUNT=$(terraform -chdir=terraform output -raw openclaw_state_storage_account_name)
SHARE_NAME=$(terraform -chdir=terraform output -raw openclaw_state_file_share_name)

# Retrieve the storage account key
STORAGE_KEY=$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "<env-resource-group>" \
  --query "[0].value" --output tsv)

# Retrieve the Container App FQDN
APP_FQDN=$(az containerapp show \
  --name "<app-name>" \
  --resource-group "<env-resource-group>" \
  --query "properties.configuration.ingress.fqdn" -o tsv)

# Render and upload (mirrors the automated workflow step)
export APP_FQDN
envsubst < config/openclaw.json.tpl > /tmp/openclaw.json

az storage file upload \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$STORAGE_KEY" \
  --share-name "$SHARE_NAME" \
  --source /tmp/openclaw.json \
  --path "openclaw.json"

rm /tmp/openclaw.json
```

> **Canonical source of truth:** `config/openclaw.json.tpl` in the repository is the authoritative template. The `${APP_FQDN}` placeholder is substituted at deploy time. `gateway.auth.token` is intentionally absent — the KV-injected `OPENCLAW_GATEWAY_TOKEN` env var supplies it.

#### Schema reference

All fields below are required for `bind=lan` operation. An invalid or missing `openclaw.json` prevents the gateway from starting.

| Field | Valid values | Notes |
|-------|-------------|-------|
| `gateway.mode` | `"local"`, `"remote"` | `"local"` for standard single-instance deployments. `"server"` is **not** a valid value. |
| `gateway.port` | positive integer | Must match Container App ingress `targetPort` (`18789`). Defaults to `18789` if omitted. |
| `gateway.bind` | `"lan"`, `"loopback"` | `"lan"` binds to all LAN interfaces and is required for Container Apps reachability. Use `"loopback"` for localhost-only testing. |
| `gateway.auth.mode` | `"token"`, `"none"` | `"token"` required for authenticated operation. |
| `gateway.controlUi.allowedOrigins` | Non-empty array of `https://` URIs | Required when `bind=lan`; an empty array `[]` causes a gateway startup failure. |
| `gateway.auth.token` | string | Optional when `OPENCLAW_GATEWAY_TOKEN` env var is set (KV-injected); env var takes priority. |

> **Security note:** The gateway token value appears in the config file stored on the Azure Files share. By default, `public_network_access_enabled = true`, so the share is reachable from the public internet for callers that have the storage account key or a valid SAS token. There is no anonymous access, and access is additionally constrained by the Container Apps Environment network boundary. For stronger network isolation, update the storage account Terraform configuration to disable public network access and/or use private endpoints and virtual network integration.

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

For `controlUi.allowedOrigins` updates, edit `config/openclaw.json.tpl` in the repo and open a PR — the `Seed OpenClaw Config` workflow step will render and upload the updated config automatically after `terraform apply`.

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

---

## 7. Troubleshooting

> **Environment safety:** Always troubleshoot against the **dev** environment. Never supply production resource names to a diagnostic command or AI agent during a troubleshooting session. If the target environment is ambiguous, confirm explicitly before running any command.

### 7.1 Quick Start

Run the diagnostic script to capture a complete snapshot without needing Terraform state or `.tfvars` files:

```bash
bash scripts/diagnose-containerapp.sh dev
# Output written to: scripts/diag-dev-<timestamp>.txt  (git-ignored)
```

The script derives all resource names from the `env` argument using the standard naming convention (`paa-dev-*`) and runs sections A–H in order. It always exits 0 — treat its output as a report, not a pass/fail gate.

### 7.2 Step-by-Step Diagnostic Procedure

Work through these sections in order, stopping when the root cause is found.

#### A — Revision list

First stop for any startup failure. Shows all revisions with health state, replica count (0 = crashed), and traffic weight.

```bash
az containerapp revision list \
  --name paa-dev-app \
  --resource-group paa-dev-rg \
  -o table
```

#### B — Active revision detail

Gets the human-readable failure reason from `runningStateDetails` (e.g. `"1/1 Container crashing: openclaw"`).

```bash
az containerapp revision show \
  --name paa-dev-app \
  --resource-group paa-dev-rg \
  --revision <revision-name> \
  --query "properties.{runningState:runningState, healthState:healthState, details:runningStateDetails}" \
  -o json
```

#### C — Container console logs

Pull container stdout/stderr (the actual crash output). Requires a running replica — skip if replicas=0.

```bash
# Get replica name
az containerapp replica list \
  --name paa-dev-app --resource-group paa-dev-rg \
  --revision <revision-name> -o table

# Pull logs
az containerapp logs show \
  --name paa-dev-app --resource-group paa-dev-rg \
  --revision <revision-name> --replica <replica-name> \
  --tail 100 --follow false
```

#### D — System event stream

Streams Container App controller events. **This surfaced the `PortMismatch` error in the 2026-03-30 incident.** Works even when replicas=0.

```bash
az containerapp logs show \
  --name paa-dev-app \
  --resource-group paa-dev-rg \
  --type system \
  --tail 50 --follow false
```

Sample `PortMismatch` event pattern:

```json
{"reason":"PortMismatch","message":"Container port 18789 does not match ingress port 80"}
```

#### E — Container exit events (diagnostics API)

Yields exit code summary and backoff-restart counts across all revisions in a time window.

```bash
RESOURCE_ID=$(az containerapp show \
  --name paa-dev-app --resource-group paa-dev-rg \
  --query id -o tsv)

az rest --method GET \
  --url "https://management.azure.com${RESOURCE_ID}/detectors/containerappscontainerexitevents?api-version=2023-05-01"
```

#### F — Storage mount failures (diagnostics API)

A non-clean status means the Azure Files share failed to mount — the container will not start.

```bash
az rest --method GET \
  --url "https://management.azure.com${RESOURCE_ID}/detectors/containerappsstoragemountfailures?api-version=2023-05-01"
```

#### G — Config file inspection

Downloads `openclaw.json` from the Azure Files share. **Redact `auth.token` before sharing output. Delete the local copy immediately.**

```bash
STORAGE_KEY=$(az storage account keys list \
  --account-name paadevocstate \
  --resource-group paa-dev-rg \
  --query "[0].value" -o tsv)

az storage file download \
  --account-name paadevocstate \
  --account-key "$STORAGE_KEY" \
  --share-name openclaw-state \
  --path "openclaw.json" \
  --dest /tmp/openclaw.json

cat /tmp/openclaw.json   # Verify gateway.mode, port, auth.mode
rm /tmp/openclaw.json    # Delete immediately — never leave on disk
```

Valid values: `gateway.mode` must be `"local"` or `"remote"` (`"server"` is **not** valid). Port must be `18789`.

#### H — Identity role assignments

Confirms the Managed Identity has required roles: `Key Vault Secrets User`, `AcrPull`, and any AI/Cognitive Services user role.

```bash
PRINCIPAL_ID=$(az identity show \
  --name paa-dev-id \
  --resource-group paa-dev-rg \
  --query principalId -o tsv)

az role assignment list \
  --assignee-object-id "$PRINCIPAL_ID" \
  --all -o table
```

#### I — Image schema inspection

Discover valid `gateway.mode` values (or other config schema values) directly from the bundled JS — no source code needed.

```bash
docker run --rm ghcr.io/openclaw/openclaw:<tag> \
  sh -c "grep -r 'gateway.mode\|\"local\"\|\"remote\"\|\"server\"' dist/ 2>/dev/null | grep -v '.map' | head -20"
```

### 7.3 Tool Reference

All tools used during the 2026-03-30 incident.

| Tool / Command | Purpose | Key Limitation |
|---|---|---|
| `bash scripts/diagnose-containerapp.sh dev` | Single command that runs all sections A–H and writes a timestamped output file | Requires `az login`; no Terraform state needed |
| `bash scripts/dump-resource-inventory.sh` | Discover all resource names by tag via Resource Graph | Requires Resource Graph access |
| `az containerapp revision list -o table` | All revisions: health/traffic/replica counts | First stop for any startup failure |
| `az containerapp revision show --query "properties.runningStateDetails"` | Human-readable failure reason | Only meaningful on active revisions |
| `az containerapp replica list` | Get replica name for per-replica log retrieval | Returns empty when replicas=0 |
| `az containerapp logs show --revision <r> --replica <n> --follow false` | Container stdout/stderr — the actual crash output | Requires a running replica; unavailable at replicas=0 |
| `az containerapp logs show --type system --tail 50` | Container App controller events — **surfaced the 2026-03-30 `PortMismatch` error** | May be empty for very recent events |
| `az rest GET .../detectors/containerappscontainerexitevents` | Exit code summary, backoff-restart counts, last error type | Undocumented API; time-windowed results |
| `az rest GET .../detectors/containerappsstoragemountfailures` | Confirms whether Azure Files mount failures contributed | Undocumented API; clean result rules out storage |
| `az containerapp env storage show` | Verify the Azure Files share binding exists and is configured | — |
| `az storage file list / download` | Inspect `openclaw.json` on the persistent share | Requires storage account key; delete local copy after use |
| `docker inspect <image>` | Reveal `Entrypoint`, `Cmd`, and env vars baked into the image | Requires docker CLI and image pull access |
| `docker run --rm <image> sh -c "grep -r ..."` | Search bundled JS for valid config schema values | Used to discover `gateway.mode` valid values |
| `az monitor log-analytics query` | Full KQL queries against Container App console logs | **Blocked by prod NSP** — not usable from outside Azure |
| `az monitor activity-log list` | Activity log for deployment history and provisioning failures | No container-level detail |
| `az role assignment list --assignee-object-id` | Confirm Managed Identity roles (KV Secrets User, AcrPull, AI User) | — |

### 7.4 Known Limitations

| Limitation | Workaround |
|------------|------------|
| `az monitor log-analytics query` blocked by the prod NSP | Use direct CLI methods: `az containerapp logs show` (sections C, D) |
| `az containerapp logs show` returns nothing when replicas=0 | Use system events (section D) and exit codes API (section E) |
| `az containerapp exec` unreliable against crashing containers | Use `docker run` for image inspection instead (section I) |
| Diagnostics API (sections E, F) is time-windowed | Wait ~5 min after a crash before querying; retry if results are empty |

### 7.5 Real-Time System Event Stream

The system event stream exposes Container App controller events and is the fastest diagnostic for infrastructure-level failures (port mismatches, image pull errors, storage mount failures):

```bash
az containerapp logs show \
  --name paa-dev-app \
  --resource-group paa-dev-rg \
  --type system \
  --tail 50 \
  --follow false
```

To stream live events in real time, add `--follow true`.

**Sample `PortMismatch` event** — seen in the 2026-03-30 incident when `gateway.port` in `openclaw.json` was set to `80` instead of `18789`:

```
2026-03-30T12:34:56.000Z Reason: PortMismatch
  Message: Container port 18789 does not match ingress port 80
  Container: openclaw
```

Recognition: if you see `PortMismatch`, check `gateway.port` in `openclaw.json` (section G). It must be `18789` to match the Container App ingress configuration.

### 7.6 Image Schema Inspection

When the valid values for a config field are uncertain (for example, `gateway.mode`), you can discover them directly from the bundled JS inside the image — no source code or documentation needed:

```bash
docker run --rm ghcr.io/openclaw/openclaw:<tag> \
  sh -c "grep -r '\"local\"\|\"remote\"\|\"server\"\|\"mode\"' dist/ 2>/dev/null | grep -v '.map' | head -20"
```

This technique was used during the 2026-03-30 incident to confirm that `gateway.mode` valid values are `"local"` and `"remote"` only (not `"server"`, which causes a startup crash). It works because OpenClaw ships its compiled JavaScript in the image under `dist/`.

You can extend the pattern to search for any other config key:

```bash
docker run --rm ghcr.io/openclaw/openclaw:<tag> \
  sh -c "grep -r '<search-term>' dist/ 2>/dev/null | grep -v '.map' | head -20"
```
