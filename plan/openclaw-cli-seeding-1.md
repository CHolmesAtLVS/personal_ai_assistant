---
goal: Establish CLI-only config seeding for the OpenClaw gateway via container exec
plan_type: standalone
version: 1.1
date_created: 2026-04-01
last_updated: 2026-04-01
owner: Platform Engineering
status: In Progress
tags: [openclaw, config, seed, cli, container-exec]
---

# Introduction

![Status: In Progress](https://img.shields.io/badge/status-In%20Progress-yellow)

The previous config seeding approach (`az storage file upload` + `envsubst`) was fragile and unsupported — it bypassed the OpenClaw config layer by writing directly to the Azure Files share, which could be overwritten by the gateway on reload. This plan documents the replacement: **CLI-only seeding via `openclaw config set --batch-file` executed inside the container**.

The approach has been validated in the dev environment (model `gpt-5.4-mini`). A dedicated seed script (`scripts/seed-openclaw-config.sh`) exists. Outstanding work: agents/skills config seeding and CI workflow integration.

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
- **REQ-003**: Config seeding must not leave batch or staging files persisted on the Azure Files share after completion. The batch file is staged under `.seed/seed.batch.json` (a transient path) and deleted via `az storage file delete` after the exec apply completes.
- **REQ-004**: After seeding `gateway.*` settings, restart the gateway revision and verify via `gateway probe`.
- **REQ-005**: Agents and skills config must be seeded as part of initial bootstrap, not left at defaults.
- **SEC-001**: All commands must target the **dev** environment. Never run against production without explicit confirmation.
- **CON-001**: `config/openclaw.batch.json` is the authoritative source for gateway config structure.
- **CON-002**: The batch file format is a JSON array of `{ "path": "...", "value": ... }` objects — see Section 4 for schema.
- **CON-003**: `az containerapp exec` is rate-limited to approximately 5 sessions per 10 minutes. HTTP 429 means wait 10 minutes. Plan exec calls carefully — each `seed-openclaw-config.sh` run uses 1 exec session (apply only).

---

## 3. Prerequisites

1. `az login` with access to the dev resource group and Key Vault.
2. Container app is running (check with `az containerapp show --name <app-name> --resource-group <rg-name>`).
3. `openclaw` CLI installed locally (`npm install -g openclaw`).
4. `config/openclaw.batch.json` is up to date and valid JSON.
5. `scripts/seed-openclaw-config.sh` is present and executable.

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

## 5. Canonical Seeding Method (Azure Files upload + exec)

**Approach:** Upload `config/openclaw.batch.json` directly to the Azure Files share (mounted at `/home/node/.openclaw` in the container) using `az storage file upload`, then apply via `az containerapp exec`. The file is staged under `.seed/seed.batch.json` and removed after apply.

This avoids the exec command-length limit. The `az containerapp exec` WebSocket endpoint URL-encodes the command argument — embedding ~2 KB of base64 inline causes HTTP 404 (URL too long). Uploading via the storage API has no such constraint.

### Run the seed script (preferred)

```bash
bash scripts/seed-openclaw-config.sh dev
```

This uses 1 exec session:
1. Apply: `node /app/openclaw.mjs config set --batch-file /home/node/.openclaw/.seed/seed.batch.json`

Upload, cleanup, and post-seed validation happen outside exec (via `az storage file upload`, `az storage file delete`, and local `openclaw config validate`).

If you hit HTTP 429, wait 10 minutes and retry.

### Manual equivalent (for debugging)

```bash
STORAGE_KEY=$(az storage account keys list \
  --account-name <storage-account> --resource-group <rg-name> \
  --query "[0].value" -o tsv)

# Stage batch file on the Azure Files share
az storage directory create --account-name <storage-account> --account-key "$STORAGE_KEY" \
  --share-name openclaw-state --name .seed --output none || true
az storage file upload --account-name <storage-account> --account-key "$STORAGE_KEY" \
  --share-name openclaw-state --source config/openclaw.batch.json \
  --path .seed/seed.batch.json --no-progress --output none

# Apply via exec (file is visible at the mount path)
az containerapp exec --name <app-name> --resource-group <rg-name> \
  --command "node /app/openclaw.mjs config set --batch-file /home/node/.openclaw/.seed/seed.batch.json"

# Clean up
az storage file delete --account-name <storage-account> --account-key "$STORAGE_KEY" \
  --share-name openclaw-state --path .seed/seed.batch.json --output none

# Validate locally (download + openclaw config validate)
bash scripts/test-openclaw-config.sh dev
```

### Previously attempted: base64 + /tmp via `node -e`

Encode batch as base64 and embed in a `node -e` exec command to write to `/tmp`. **Does not work** — the command string (≥2100 chars with 2 KB of base64) exceeds the exec WebSocket URL limit, causing HTTP 404. Abandoned in favour of the Azure Files upload approach above.

---

## 6. What Works ✅

| Technique | Result | Notes |
|---|---|---|
| `az storage file upload` + exec from share mount | ✅ **Canonical** | Avoids exec URL limit; changedPaths=12 confirmed |
| `openclaw config set --batch-file <share-mount-path>` | ✅ Works | Confirms changedPaths + sha256 |
| `openclaw config set <key> <value>` (scalar) | ✅ Works | Reliable for simple string/number values |
| `node /app/openclaw.mjs config get <key>` | ✅ Works | Best way to verify remote config values |
| `node /app/openclaw.mjs models list` (exec) | ✅ Works | Confirms model auth and deployment |
| `openclaw gateway probe` (remote CLI) | ✅ Works | Fast reachability check once device is approved |
| `max_completion_tokens` for gpt-5.4-mini | ✅ Works | Required — `max_tokens` is rejected with HTTP 400 |

---

## 7. What Does Not Work ❌

| Technique | Problem |
|---|---|
| `node -e` + base64 inline in exec command | Exec command URL-encodes the argument; ≥2 KB base64 causes HTTP 404 (URL too long) |
| `openclaw config set` from outside container | Writes to local `~/.openclaw/openclaw.json`, not the remote gateway |
| `az storage file upload` to seed `openclaw.json` directly | Bypasses config layer; gateway may ignore or overwrite on reload |
| JSON arrays via `openclaw config set <key> '[...]'` through exec | Shell strips double-quotes; value arrives as invalid JSON |
| `/usr/local/bin/openclaw` as exec command | Symlink points to `/app/openclaw.mjs`; exec `stat` fails on symlinks in some Container Apps versions |
| `openclaw models list` (remote CLI via WebSocket) | Hangs indefinitely against remote `OPENCLAW_GATEWAY_URL` — use exec instead |
| `openclaw status` RPC when device not approved | Returns exit 1; gateway/channel/agent sections skipped in test script |
| `max_tokens` with gpt-5.4-mini | HTTP 400 `unsupported_parameter` — use `max_completion_tokens` |
| `&&` chains across exec sessions | Only the first command in a chain produces output; subsequent commands parsed by openclaw.mjs not the shell |
| `envsubst` for secret expansion at CI time | Exposes secrets in the file system before they reach the container |
| `az containerapp exec` > ~5 times/10min | HTTP 429, retry-after: 600s — plan exec calls carefully |

---

## 8. Agents and Skills — Outstanding Work

The `main` agent is running with `gpt-5.4-mini` as primary model. The workspace files on the share are defaulted:

| File | Status | Action needed |
|---|---|---|
| `BOOTSTRAP.md` | Default ("Hello World") | Customise with persona, instructions, memory init |
| `IDENTITY.md` | Absent | Create via first conversation or seed via exec |
| `USER.md` | Absent | Create via first conversation |
| `AGENTS.md` | Present | Review routing rules — currently 0 rules |
| `SOUL.md`, `TOOLS.md`, `HEARTBEAT.md` | Present | Review content |
| Skills | Not inspected | Run `node /app/openclaw.mjs skills list` to audit |

**Next steps:**
- Seed `agents.main.systemPrompt` or custom BOOTSTRAP.md via `openclaw config set` or exec
- Add routing rules to `agents.defaults.routing` if multi-agent is needed
- Audit skills: `az containerapp exec --name <app-name> --resource-group <rg-name> --command "node /app/openclaw.mjs skills list"`
- Confirm memory (SQLite) is healthy: `node /app/openclaw.mjs memory status --deep` via exec

**Stale config to clean up:**
- `agents.defaults.models` block still contains `azure-openai/gpt-4o: {}` — a leftover entry from the old config. Remove with:
  ```bash
  az containerapp exec --name <app-name> --resource-group <rg-name> \
    --command "node /app/openclaw.mjs config unset agents.defaults.models"
  ```

---

## 9. Workflow Plan

The CI workflow (`terraform-deploy.yml`) is now **Terraform-only** — the seeding and health-check steps were removed. Config seeding is a manual one-time operation per environment.

### Proposed workflow after first Terraform apply

```
terraform apply        (CI — provisions Container App, Key Vault, Azure AI Foundry)
       ↓
bash scripts/seed-openclaw-config.sh dev   (manual — applies openclaw.batch.json)
       ↓
az containerapp revision restart ...       (manual — if gateway.* paths changed)
       ↓
bash scripts/test-multi-model.sh dev       (manual — validate all config + live inference)
       ↓
openclaw configure (interactive)           (manual — channels, agents, skills via CLI)
```

**Config drift:** If `openclaw.batch.json` is updated (e.g. new model), re-run `seed-openclaw-config.sh dev`. The apply is idempotent — unchanged paths produce no effect.

**CI integration (future):** The seed script could be added back to the workflow as a conditional step (only on first deploy or drift detection), but this requires a paired device token in CI secrets and is deferred.

---

## 10. Verification Results

### Session 1 — 2026-04-01 (revision 0000006, gpt-4o)

| Check | Result |
|---|---|
| Batch exec output | `changedPaths=16`, `Updated 17 config paths` |
| sha256 changed | ✅ |
| `openclaw gateway probe` | ✅ Remote connect ok (229ms), RPC ok |
| `openclaw models list` (exec) | ✅ `azure-openai/gpt-4o` |

### Session 2 — 2026-04-01 (revision 0000007, gpt-5.4-mini)

| Check | Result |
|---|---|
| `gpt-5.4-mini` deployed in Azure AI Foundry | ✅ |
| Batch applied via base64 + /tmp | ✅ `changedPaths=10`, 3 paths updated |
| `agents.defaults.model.primary` | ✅ `azure-openai/gpt-5.4-mini` |
| `models.providers.azure-openai.models` | ✅ `gpt-5.4-mini` |
| `openclaw models list` (exec) | ✅ auth: yes, default |
| Live inference HTTP | ✅ HTTP 200, reply=OK |
| Test suite | ✅ **33 passed, 0 failed** |

---

## 11. Known Limitations

- **`openclaw models list` remote hang**: Hangs when `OPENCLAW_GATEWAY_URL` is set. Use `az containerapp exec` + `node /app/openclaw.mjs models list` instead.
- **exec rate limit**: ~5 sessions per 10 minutes. `seed-openclaw-config.sh` uses 1 exec session (apply only) per run.
- **`&&` chain silence**: Only the first command in an exec `&&` chain produces output. Subsequent commands succeed but print nothing — verified by checking config values separately.
- **No idempotency guard**: Re-running the batch writes the same values; sha256 changes only when values actually differ.
- **Agents/skills not seeded**: `BOOTSTRAP.md` is the default template. Agent persona, routing rules, and skills require separate configuration.

---

## 12. Future Work

| Item | Status |
|---|---|
| `scripts/seed-openclaw-config.sh` | ✅ Created — test below |
| Test seed script against dev | ✅ changedPaths=12, verified working (Azure Files upload approach) |
| Customise `BOOTSTRAP.md` / agent persona | ⬜ Pending |
| Seed agents routing + skills config | ⬜ Pending |
| Remove stale `agents.defaults.models.azure-openai/gpt-4o` entry | ⬜ Pending |
| CI workflow integration (conditional seed step) | ⬜ Deferred |
| Remove `config/openclaw.json.tpl` references from plan docs | ✅ Done |
