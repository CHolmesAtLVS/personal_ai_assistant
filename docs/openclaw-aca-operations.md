# OpenClaw Operations Runbook

This document covers operational procedures for the OpenClaw gateway runtime: first-time bootstrap, gateway token management, config updates, storage backup/restore, and image upgrades.

## Prerequisites

- Azure CLI authenticated with sufficient permissions on the environment resource group
- Access to the Key Vault in the environment resource group
- Terraform state is healthy and `terraform plan` shows no unexpected drift

> **Environment safety:** Unless performing an authorized production incident response, always execute these procedures against the **dev** environment first. Validate the outcome in dev before applying to prod. AI agents must only be directed to operate against dev resources; do not supply production resource names to an AI agent during a troubleshooting or debugging session.

---

## AKS Operations

These procedures apply to the AKS deployment of OpenClaw (post-migration from ACA). ACA procedures below are preserved and marked as **Legacy (ACA)** until ACA decommission is confirmed complete per `plan/feature-aks-decommission-1.md`.

### Prerequisites

- `kubectl` and `argocd` CLI installed
- Kubeconfig obtained: `az aks get-credentials --name paa-<env>-aks --resource-group paa-<env>-rg`
- ArgoCD UI accessible at `https://paa-<env>.acmeadventure.ca/argocd`

### AKS.1 First-Time Bootstrap

1. AKS cluster and platform bootstrap complete (SUB-001 + SUB-002 per `plan/feature-aks-migration-1.md`).
2. Obtain kubeconfig:
   ```bash
   az aks get-credentials --name paa-<env>-aks --resource-group paa-<env>-rg
   ```
3. Apply CRDs (SecretProviderClass and supporting manifests):
   ```bash
   envsubst < workloads/<env>/openclaw/crds/secretproviderclass.yaml | kubectl apply -f -
   ```
4. Apply the ArgoCD Application to deploy OpenClaw:
   ```bash
   kubectl apply -f argocd/apps/openclaw-<env>.yaml
   ```
5. Monitor pod startup:
   ```bash
   kubectl get pods -n openclaw -w
   ```
6. Load remote credentials and approve device:
   ```bash
   source <(./scripts/openclaw-connect.sh <env> --export)
   openclaw devices list
   openclaw devices approve <requestId>
   ```
7. Validate:
   ```bash
   openclaw status --all
   openclaw doctor
   ```

### AKS.2 Gateway Token Rotation

1. Generate a new token:
   ```bash
   NEW_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(24))")
   ```
2. Update the Key Vault secret:
   ```bash
   az keyvault secret set \
     --vault-name "<kv-name>" \
     --name "openclaw-gateway-token" \
     --value "$NEW_TOKEN"
   ```
3. The CSI driver rotates the Kubernetes Secret automatically at the configured 2-minute interval. To force immediate refresh:
   ```bash
   kubectl rollout restart deployment/openclaw -n openclaw
   ```
   > **Confirm with the user before restarting.** The rollout briefly interrupts gateway availability.
4. Confirm:
   ```bash
   kubectl rollout status deployment/openclaw -n openclaw
   openclaw status
   ```

### AKS.3 Configuration Updates

**Bulk updates (primary path):** Update `workloads/<env>/openclaw/values.yaml` in Git, open a pull request, and merge. ArgoCD syncs automatically. `configMode: merge` means runtime state (paired devices, UI changes) is preserved across syncs.

For an immediate forced sync without waiting for Git merge:
```bash
argocd app sync openclaw-<env>
```

**Individual key (immediate in-place change):**
```bash
kubectl exec -n openclaw deployment/openclaw -- node /app/openclaw.mjs config set <key> <value>
```

If `gateway.*` was changed, restart the pod (confirm with user first):
```bash
kubectl rollout restart deployment/openclaw -n openclaw
```

> **Note:** `openclaw config set` writes to the local shell's `~/.openclaw`, not the gateway pod. Always use `kubectl exec` for gateway config changes.

### AKS.4 Logs and Diagnostics

```bash
# Live logs
kubectl logs -n openclaw deployment/openclaw --follow --tail=100

# Pod status
kubectl get pods -n openclaw -o wide

# Describe pod (events, volume mounts)
kubectl describe pod -n openclaw <pod-name>

# ArgoCD sync status
kubectl get application openclaw-<env> -n argocd

# CSI secret health
kubectl get secret openclaw-env-secret -n openclaw
kubectl get secretproviderclass -n openclaw
```

Log Analytics (AKS diagnostics) — use `azure-mcp-server/monitor` with KQL:
```kql
ContainerLogV2
| where ContainerName == "openclaw"
| order by TimeGenerated desc
| take 100
```

### AKS.5 Image Upgrades

1. Identify the new pinned tag from the [OpenClaw GHCR release page](https://github.com/openclaw/openclaw/pkgs/container/openclaw).
2. Update `appVersion` in `workloads/<env>/openclaw/Chart.yaml` to the new tag.
3. Open a pull request — review the ArgoCD diff confirming only the image tag changes.
4. Merge to apply. ArgoCD rolls out the new pod. The Azure Files NFS share is unaffected by the rollout.

**Rollback:** Revert `appVersion` in `Chart.yaml` and merge. ArgoCD rolls back to the previous image.

---

## 1. First-Time Bootstrap

> **Legacy (ACA) — These procedures apply to the ACA deployment. See [AKS Operations](#aks-operations) for the current approach.**

### 1.1 Gateway Token — Terraform-Managed

The `openclaw-gateway-token` Key Vault secret is fully managed by Terraform. On first apply, Terraform generates a stable 48-character hex token via the `random_id` resource, stores it in Key Vault via `azurerm_key_vault_secret`, and wires the Container App to read it at startup via Managed Identity. The token value is stored in Terraform state (sensitive, encrypted at rest in the Azure Blob backend).

The secret is created once and never overwritten by subsequent applies (`lifecycle { ignore_changes = [value] }`), so manual rotations (section 2) are preserved.

> **Note:** On a brand-new environment, Terraform creates the `Key Vault Secrets Officer` role assignment for the CI SP in the same apply that creates the secret. Azure RBAC propagation can take up to a minute, which may cause the secret creation to fail on the very first apply. A retry of `terraform apply` resolves it.

**Manual rotation:** Generate a new token and update the secret directly, then restart the Container App revision so it pulls the new value:

```bash
TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(24))")
az keyvault secret set \
  --vault-name "<kv-name>" \
  --name "openclaw-gateway-token" \
  --value "$TOKEN"

az containerapp revision restart \
  --name "<app-name>" \
  --resource-group "<env-resource-group>" \
  --revision "<revision-name>"
```

### 1.2 Run Terraform Apply

> **Pre-flight: `TF_VAR_AZURE_AI_API_KEY` must be set in the GitHub Environment secrets before any apply.**
> This secret provides the Azure AI Foundry API key used by the `azure-foundry` provider for Grok/xAI MaaS models. Terraform variable validation rejects empty values on every run (not just first apply). Retrieve the key from the Azure AI Foundry portal (AI Services account → Keys and Endpoint) and set it in: GitHub repository → Settings → Environments → `dev` (or `prod`) → Secrets.
> For local runs, add `TF_VAR_azure_ai_api_key = "<key>"` to `scripts/<env>.tfvars` (for dev: `scripts/dev.tfvars`).

Terraform apply is triggered automatically by CI on every PR to `main` (dev) and on merge to `main` (prod). No manual steps are required.

```bash
# Locally (dev only): uses scripts/dev.tfvars (copied from scripts/dev.tfvars.example)
./scripts/terraform-local.sh dev apply
```

### 1.3 Seed the Gateway Configuration

OpenClaw reads its gateway configuration from `/home/node/.openclaw/openclaw.json` on the persistent Azure Files share. Config is managed exclusively via the openclaw CLI — there is no file template and no workflow seeding step.

**First-time seed (manual, once per environment):**

```bash
# Load remote gateway credentials
source <(./scripts/openclaw-connect.sh dev --export)

# Set required config values — gateway settings, model provider, agent defaults.
# Use container exec for values that require remote write (see openclaw-cli skill for full command list).
az containerapp exec --name paa-dev-app --resource-group paa-dev-rg \
  --command "node /app/openclaw.mjs config set agents.defaults.model.primary azure-openai/gpt-5"
```

See `config/openclaw.batch.json` for the full set of config paths and values. Apply each path with `az containerapp exec` + `node /app/openclaw.mjs config set <path> <value>`.

**Recovery:** If config is lost or corrupt, re-apply all paths from `config/openclaw.batch.json` using the same exec approach. Use `openclaw doctor --fix` to repair schema violations.

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

> **Security note:** `gateway.auth.token` is supplied via the `OPENCLAW_GATEWAY_TOKEN` environment variable injected from Key Vault and never written to disk. If you explicitly set `gateway.auth.token` via `openclaw config set` (for testing or non-standard setups), be aware that this value is stored in `openclaw.json` on the Azure Files share.

---

## 2. Gateway Token Rotation

> **Legacy (ACA) — These procedures apply to the ACA deployment. See [AKS.2 Gateway Token Rotation](#aks2-gateway-token-rotation) for the current approach.**

The gateway token is managed by Terraform in Key Vault. To rotate it without redeploying infrastructure:

```bash
# 1. Generate a new token
NEW_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(24))")

# 2. Update the Key Vault secret directly
#    (Terraform will skip this value on the next apply due to ignore_changes = [value])
az keyvault secret set \
  --vault-name "<kv-name>" \
  --name "openclaw-gateway-token" \
  --value "$NEW_TOKEN"

# 3. Restart the Container App revision so it pulls the new secret value
az containerapp revision restart \
  --name "<app-name>" \
  --resource-group "<env-resource-group>" \
  --revision "<active-revision-name>"
```

> **Note:** `openclaw.json` does not contain the gateway token. No config file edit is required during rotation — only the Key Vault secret update and a revision restart.

---

## 3. Gateway Configuration Updates

> **Legacy (ACA) — These procedures apply to the ACA deployment. See [AKS.3 Configuration Updates](#aks3-configuration-updates) for the current approach.**

The `openclaw` CLI is the primary interface for updating runtime config — it edits the gateway configuration in place with no file download required.

### Prerequisites

Load the CLI connection for your shell session:

```bash
source <(./scripts/openclaw-connect.sh dev --export)
```

If your device is not yet approved, approve it before proceeding:

```bash
openclaw devices list                   # find pending requestId
openclaw devices approve <requestId>
```

### Update Configuration

```bash
# Read the current value
openclaw config get gateway.controlUi.allowedOrigins

# Update a single setting
openclaw config set gateway.controlUi.allowedOrigins[0] "https://new-fqdn.example.com"

# Interactive wizard — use for multi-field or structured changes
openclaw configure
openclaw configure --section gateway    # scoped to gateway settings only
```

**Hot-reload vs. restart:** Channel, model, agent, and routing changes take effect immediately. Changes to `gateway.*` settings (port, bind, auth) require a container revision restart — confirm with the user before triggering.

> **Never download `openclaw.json` to `/tmp` for manual editing.** Local file edits are not applied to the remote gateway and bypass openclaw's config validation, hot-reload, and audit trail. Use the CLI exclusively.

### Keeping Config in Sync

`config/openclaw.batch.json` documents the canonical config paths and values. For persistent structural changes (for example, adding a new model or updating `controlUi.allowedOrigins`), update `config/openclaw.batch.json` in the repo and re-apply the changed paths via `az containerapp exec` so the batch file stays current with the live gateway.

---

## 4. State Backup and Restore

> **Legacy (ACA) — These procedures apply to the ACA deployment. AKS uses the same Azure Files NFS share; backup/restore commands are equivalent.**

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

> **Legacy (ACA) — These procedures apply to the ACA deployment. See [AKS.5 Image Upgrades](#aks5-image-upgrades) for the current approach.**

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

> **Legacy (ACA) — Probe endpoints are unchanged on AKS (same `/healthz` and `/readyz` on port 18789); Kubernetes liveness/readiness probe config is defined in the Helm chart.**

The Container App runtime configures health probes at:

| Probe | Endpoint | Port |
|-------|----------|------|
| Liveness | `/healthz` | 18789 |
| Readiness | `/readyz` | 18789 |

If the liveness probe fails repeatedly, the Container App platform restarts the container. If the readiness probe fails, the replica is removed from the ingress rotation. Both probes run over HTTP against the container's internal port.

---

## 7. Troubleshooting

> **Legacy (ACA) — These procedures apply to the ACA deployment. See [AKS.4 Logs and Diagnostics](#aks4-logs-and-diagnostics) and the `openclaw-troubleshoot` skill for the current approach.**

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
  --name <project>-<env>-app \
  --resource-group <project>-<env>-rg \
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

Read current config values via the CLI — no file download needed.

```bash
# Load CLI connection first
source <(./scripts/openclaw-connect.sh dev --export)

# Read specific values
openclaw config get gateway.mode
openclaw config get gateway.port
openclaw config get gateway.auth.mode

# Full snapshot (tokens redacted — safe to share)
openclaw status --all
```

Valid values: `gateway.mode` must be `"local"` or `"remote"` (`"server"` is **not** valid). Port must be `18789`.

**Emergency fallback only (when the gateway is down and the CLI cannot connect):** Download the config directly from storage for read-only inspection, then delete immediately:

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
| `openclaw config get <key>` | Read live config values from the remote gateway — **primary method** | Requires CLI connected to remote gateway (`source scripts/openclaw-connect.sh dev --export`) |
| `az storage file list / download` | Emergency fallback: inspect `openclaw.json` directly when CLI cannot connect | Requires storage account key; for read-only inspection; delete local copy immediately after use |
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
