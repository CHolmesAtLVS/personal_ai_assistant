---
goal: Establish CLI-only config seeding for the OpenClaw gateway via container exec
plan_type: standalone
version: 1.0
date_created: 2026-04-01
last_updated: 2026-04-01
owner: Platform Engineering
status: Completed
tags: [openclaw, config, seed, cli, container-exec]
---

# Introduction

![Status: Completed](https://img.shields.io/badge/status-Completed-green)

The previous config seeding approach (`az storage file upload` + `envsubst`) was fragile and unsupported — it bypassed the OpenClaw config layer by writing directly to the Azure Files share, which could be overwritten by the gateway on reload. This plan documents the replacement: **CLI-only seeding via `openclaw config set --batch-file` executed inside the container**.

This method is the canonical approach going forward and is being evaluated as the authoritative way to seed any OpenClaw gateway from scratch.

---

## 1. Why the Old Approach Was Replaced

| Problem | Detail |
|---|---|
| Direct file write is unsupported | Writing `openclaw.json` to Azure Files bypasses OpenClaw's config layer. Values may be ignored or overwritten on restart. |
| `envsubst` requires secrets at CI time | CI had to expand `${AZURE_AI_API_KEY}` and `${OPENCLAW_GATEWAY_TOKEN}` before writing — exposing secrets in the file system before they reach the share. |
| `openclaw config set` is local-only | Running `openclaw config set` from outside the container writes to the local `~/.openclaw/openclaw.json`, not the remote gateway's config. |
| No validation | The file write gave no feedback on whether values were accepted or config was valid. |

The CLI exec approach fixes all of these:
- Uses the official `config set` path inside the process that owns the config file.
- Secrets remain in the container env — `${VAR}` refs are passed as literals and resolved by the gateway at runtime.
- Outputs `changedPaths` count and a new sha256, giving clear audit feedback.
- Works with any gateway version that supports `--batch-file`.

---

## 2. Requirements & Constraints

- **REQ-001**: Config must be applied exclusively via `openclaw config set` (or `--batch-file`) running inside the container process.
- **REQ-002**: Secret values (`AZURE_AI_API_KEY`, `OPENCLAW_GATEWAY_TOKEN`) must be stored as `${VAR}` literals in the batch file — never expanded before exec.
- **REQ-003**: The batch file must be cleaned up from the Azure Files share immediately after exec.
- **REQ-004**: After seeding, restart the gateway revision and verify via `gateway probe`.
- **SEC-001**: All commands must target the **dev** environment. Never run against production without explicit confirmation.
- **CON-001**: `config/openclaw.batch.json` is the authoritative source for gateway config structure. `config/openclaw.json.tpl` is kept as reference only.
- **CON-002**: The batch file format is a JSON array of `{ "path": "...", "value": ... }` objects — see Section 4 for schema.

---

## 3. Prerequisites

1. `az login` with access to the dev resource group (`paa-dev-rg`) and Key Vault (`paa-dev-kv`).
2. Storage account `paadevocstate`, file share `openclaw-state` accessible (SAS token or storage key via az CLI).
3. `openclaw` CLI installed locally (`npm install -g openclaw` or `npx openclaw`).
4. Container app `paa-dev-app` is running and the revision is known.

---

## 4. Batch File Format

`config/openclaw.batch.json` is a JSON array of config operations. Each object has:

```json
{ "path": "dotted.config.key", "value": <any JSON value> }
```

- **`path`**: Dot-notation path into the gateway config (e.g. `models.providers.azure-openai.apiKey`).
- **`value`**: Any JSON value — string, number, boolean, array, or object.
- **`${VAR}` refs**: String values may contain `${ENV_VAR_NAME}` — the gateway resolves these from its own process environment at runtime. Never expand them before passing to exec.

---

## 5. Implementation Steps

### Step 1 — Connect local CLI to remote gateway (verification only)

```bash
source <(./scripts/openclaw-connect.sh dev --export)
openclaw gateway probe
```

Expected: `Remote ... Connect: ok · RPC: ok`

---

### Step 2 — Upload batch file to Azure Files share

The container mounts the `openclaw-state` share at `/home/node/.openclaw/`. Uploading the batch file there makes it accessible to `az containerapp exec`.

```bash
STORAGE_ACCOUNT="paadevocstate"
SHARE_NAME="openclaw-state"
STORAGE_KEY=$(az storage account keys list \
  --account-name "${STORAGE_ACCOUNT}" \
  --resource-group paa-dev-rg \
  --query "[0].value" -o tsv)

az storage file upload \
  --account-name "${STORAGE_ACCOUNT}" \
  --account-key "${STORAGE_KEY}" \
  --share-name "${SHARE_NAME}" \
  --source config/openclaw.batch.json \
  --path openclaw.batch.json
```

---

### Step 3 — Apply config via container exec

```bash
az containerapp exec \
  --name paa-dev-app \
  --resource-group paa-dev-rg \
  --command "node /app/openclaw.mjs config set --batch-file /home/node/.openclaw/openclaw.batch.json"
```

Expected output:
```
Config overwrite: /home/node/.openclaw/openclaw.json
sha256: <old_hash> → <new_hash>
changedPaths=16
Updated 17 config paths. Restart the gateway to apply.
```

---

### Step 4 — Clean up batch file from share

```bash
az storage file delete \
  --account-name "${STORAGE_ACCOUNT}" \
  --account-key "${STORAGE_KEY}" \
  --share-name "${SHARE_NAME}" \
  --path openclaw.batch.json
```

---

### Step 5 — Restart the gateway revision

```bash
REVISION=$(az containerapp revision list \
  --name paa-dev-app \
  --resource-group paa-dev-rg \
  --query "[0].name" -o tsv)

az containerapp revision restart \
  --name paa-dev-app \
  --resource-group paa-dev-rg \
  --revision "${REVISION}"

sleep 20
```

---

### Step 6 — Verify

```bash
# Probe connectivity
source <(./scripts/openclaw-connect.sh dev --export)
openclaw gateway probe

# Verify model list directly inside container (CLI remote models list may hang — exec is reliable)
az containerapp exec \
  --name paa-dev-app \
  --resource-group paa-dev-rg \
  --command "node /app/openclaw.mjs models list"
```

Expected model list output:
```
Model                        Input      Ctx    Local Auth  Tags
azure-openai/gpt-4o          text+image 125k   no    yes   default,configured
```

---

## 6. Verification Results (2026-04-01)

Applied to dev gateway (`paa-dev-app--0000006`):

| Check | Result |
|---|---|
| Batch exec output | `changedPaths=16`, `Updated 17 config paths` |
| sha256 changed | ✅ |
| Gateway restart | ✅ triggered |
| `openclaw gateway probe` | ✅ Remote connect ok (229ms), RPC ok |
| `openclaw status --all` | ✅ Gateway: remote · reachable 195ms · auth token |
| `openclaw models list` (exec) | ✅ `azure-openai/gpt-4o` · text+image · 125k · auth yes · default,configured |
| Agent model in logs | ✅ `[gateway] agent model: azure-openai/gpt-4o` |

> **Note on `openclaw models list` over remote CLI**: This command hangs when run from outside the container against the remote gateway (via WebSocket). This is a known CLI limitation for remote targets — use `az containerapp exec` to run `models list` inside the container instead.

---

## 7. Known Limitations

- **`openclaw models list` remote hang**: The CLI `models list` command does not return when targeted at a remote gateway via `OPENCLAW_GATEWAY_URL`. Use `az containerapp exec ... "node /app/openclaw.mjs models list"` for verification.
- **`--batch-file` share dependency**: The batch file must transit the Azure Files share because `az containerapp exec` has no stdin pipe mechanism. The file is immediately deleted after exec.
- **No idempotency guard**: Running the batch multiple times writes the same values. This is safe (idempotent in effect) but produces a sha256 change on first run if any paths differ.

---

## 8. Future Work

- **Update CI workflow**: Replace the `az storage file upload + envsubst` Seed step in `.github/workflows/terraform-deploy.yml` with the exec + batch approach documented here.
- **Remove `config/openclaw.json.tpl`**: Once the workflow is updated, the old template can be deleted.
- **Automate cleanup**: The upload/exec/cleanup sequence could be wrapped in a dedicated script (`scripts/seed-openclaw-config.sh`) for CI and manual use.
