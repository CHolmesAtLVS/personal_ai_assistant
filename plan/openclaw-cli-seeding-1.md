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

The previous config seeding approach (`az storage file upload` + `envsubst`) was fragile and unsupported — it bypassed the OpenClaw config layer by writing directly to the Azure Files share, which could be overwritten by the gateway on reload. This plan documents the replacement and the operating model for CI-reliable seeding.

**Current canonical approach (CI + local):** Upload `config/openclaw.batch.json` to the Azure Files share, apply via `az containerapp exec` (wrapped in `script -q -c "..." /dev/null` to allocate a pseudo-TTY), then validate with a second exec call. Uses `node /app/openclaw.mjs` inside the container directly — no openclaw CLI on the runner or local machine needed.

**`az containerapp exec` + PTY workaround:** `az containerapp exec` calls `termios.tcgetattr()` during WebSocket setup. Without a TTY (CI runners), this raises ENOTTY (errno 25). Wrapping with `script -q -c "..." /dev/null` allocates a pseudo-TTY via `openpty()`, satisfying `tcgetattr()`. Available on all `ubuntu-latest` runners (util-linux) and in the devcontainer. This is the approach used by both `seed-openclaw-ci.sh` (CI) and `seed-openclaw-config.sh` (local).

The approach has been validated in the dev environment (model `gpt-5.4-mini`, changedPaths=12, `config validate` confirmed clean). Outstanding work: agents/skills config seeding.

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

- **REQ-001**: Config must be applied via `openclaw config set --batch-file` running inside the container process (`node /app/openclaw.mjs config set --batch-file`). The batch file is staged on the Azure Files share and applied from the container-side mount path.
- **REQ-002**: Secret values (`AZURE_AI_API_KEY`, `OPENCLAW_GATEWAY_TOKEN`) must be stored as `${VAR}` literals in the batch file — never expanded before the gateway process resolves them at runtime.
- **REQ-003**: Config seeding must not leave batch or staging files persisted on the Azure Files share after completion. The batch file is staged under `.seed/seed.batch.json` (a transient path) and deleted via `az storage file delete` after exec apply completes.
- **REQ-004**: After seeding `gateway.*` settings, restart the gateway revision and verify via `gateway probe`.
- **REQ-005**: Agents and skills config must be seeded as part of initial bootstrap, not left at defaults.
- **SEC-001**: All commands must target the **dev** environment. Never run against production without explicit confirmation.
- **CON-001**: `config/openclaw.batch.json` is the authoritative source for gateway config structure.
- **CON-002**: The batch file format is a JSON array of `{ "path": "...", "value": ... }` objects — see Section 4 for schema.
- **CON-003**: `az containerapp exec` fails in GitHub Actions with ENOTTY (errno 25) — the Azure CLI calls `termios.tcgetattr()` during WebSocket setup and CI runners have no TTY. **Workaround:** wrap with `script -q -c "az containerapp exec ..." /dev/null` to allocate a pseudo-TTY. `script(1)` is available on `ubuntu-latest` runners via util-linux. Strip carriage returns from output with `tr -d '\r'`.

---

## 3. Prerequisites

1. `az login` with access to the dev resource group and Key Vault.
2. Container app is running (check with `az containerapp show --name <app-name> --resource-group <rg-name>`).
3. `config/openclaw.batch.json` is up to date and valid JSON.
4. `scripts/seed-openclaw-ci.sh` (CI) or `scripts/seed-openclaw-config.sh` (local) is present and executable.
5. `script(1)` available — provided by util-linux (pre-installed on `ubuntu-latest` and the devcontainer).

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

## 5. Seeding Scripts

Two scripts with the same logic, different TTY handling:

| Script | Environment | TTY method |
|---|---|---|
| `scripts/seed-openclaw-ci.sh` | GitHub Actions (CI) | `script -q -c "az containerapp exec ..." /dev/null` — pseudo-TTY via `openpty()` |
| `scripts/seed-openclaw-config.sh` | Local / devcontainer | Direct `az containerapp exec` — shell already has a TTY |

Both scripts:
1. Validate `config/openclaw.batch.json` as JSON (python3)
2. Fetch storage key via `az storage account keys list`
3. Upload batch to share at `.seed/seed.batch.json`
4. exec: `node /app/openclaw.mjs config set --batch-file <container-mount-path>`  (apply)
5. Delete `.seed/seed.batch.json` from share
6. exec: `node /app/openclaw.mjs config validate`  (verify)

```bash
# CI (called by terraform-deploy.yml)
bash scripts/seed-openclaw-ci.sh dev

# Local / devcontainer
bash scripts/seed-openclaw-config.sh dev
```

### Manual equivalent (debugging)

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

# Apply via exec
az containerapp exec --name <app-name> --resource-group <rg-name> \
  --command "node /app/openclaw.mjs config set --batch-file /home/node/.openclaw/.seed/seed.batch.json"

# Clean up
az storage file delete --account-name <storage-account> --account-key "$STORAGE_KEY" \
  --share-name openclaw-state --path .seed/seed.batch.json --output none

# Validate
bash scripts/test-openclaw-config.sh dev
```

### Previously attempted (abandoned)

- **Local-apply + re-upload**: Download `openclaw.json`, apply batch with `OPENCLAW_CONFIG_PATH=<tmp> openclaw config set --batch-file` locally, upload result. Avoided exec but required npm on the runner, and could not confirm the gateway's in-memory state (CIFS mount does not fire inotify — hot-reload unreliable).
- **base64 + `/tmp` via `node -e`**: Command string ≥20 KB after base64 encoding exceeds exec WebSocket URL limit → HTTP 404.
- **exec without PTY workaround in CI**: ENOTTY (errno 25) on every call. `continue-on-error: true` masked the failure — CI appeared green while config was never applied.

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
| `script -q -c "az containerapp exec ..." /dev/null` | ✅ Works | PTY workaround — resolves ENOTTY in CI and local |

---

## 7. What Does Not Work ❌

| Technique | Problem |
|---|---|
| `az containerapp exec` without PTY in GitHub Actions | ENOTTY (errno 25) — Azure CLI calls `termios.tcgetattr()` during WebSocket setup; CI runners have no TTY. `continue-on-error: true` masked this. Use `script -q -c "..." /dev/null` wrapper. |
| Local-apply + re-upload (npm approach) | Requires npm on runner; cannot confirm gateway in-memory state; CIFS mount does not fire inotify so hot-reload is unreliable. Abandoned. |
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

## 9. Operating Model

### Infrastructure (Terraform + GitHub)

Terraform is the authoritative mechanism for all Azure infrastructure. Changes are applied via the `terraform-deploy.yml` workflow — PR → dev, merge to main → prod.

### OpenClaw Configuration (batch + local-apply)

Gateway configuration is managed by `config/openclaw.batch.json`. The batch is applied by `scripts/seed-openclaw-config.sh`, which:
1. Downloads the current `openclaw.json` from Azure Files
2. Applies the batch locally (`OPENCLAW_CONFIG_PATH=<tmp> openclaw config set --batch-file`)
3. Validates (`openclaw config validate`)
4. Uploads the result back to Azure Files

The gateway hot-reloads from the Azure Files mount for most config changes. `gateway.*` changes require a revision restart.

### CI workflow after each deploy

```
Terraform Plan + Apply   (infra changes only)
       ↓
Seed OpenClaw Config     (local-apply: download → batch apply → validate → upload)
       ↓
Gateway hot-reloads from Azure Files mount
```

**Config drift:** If `openclaw.batch.json` changes (e.g. new model), the next CI run re-seeds. The batch apply is idempotent — unchanged paths produce no effect.

### Manual operations (local devcontainer)

```bash
# Apply batch (CI method, works locally)
bash scripts/seed-openclaw-config.sh dev

# Apply batch (exec method, confirms changedPaths from container)
bash scripts/seed-openclaw-config.sh dev --exec

# Validate downloaded config
bash scripts/test-openclaw-config.sh dev

# Full health validation + live inference
bash scripts/test-multi-model.sh dev

# Interactive CLI (channels, agents, skills)
source <(./scripts/openclaw-connect.sh dev --export)
openclaw configure
```

**Revision restart (after gateway.* changes):**
```bash
REVISION=$(az containerapp revision list --name <app-name> --resource-group <rg-name> --query '[0].name' -o tsv)
az containerapp revision restart --name <app-name> --resource-group <rg-name> --revision "${REVISION}"
```

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

- **`openclaw models list` remote hang**: Hangs when `OPENCLAW_GATEWAY_URL` is set. Use `az containerapp exec` + `node /app/openclaw.mjs models list` instead (local/interactive only).
- **exec in GitHub Actions**: ENOTTY on every call — not usable in CI regardless of command. `continue-on-error: true` masked this historically.
- **exec rate limit**: ~5 sessions per 10 minutes when using exec locally.
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
