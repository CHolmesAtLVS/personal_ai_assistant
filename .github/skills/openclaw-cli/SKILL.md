---
name: openclaw-cli
description: "Connect the local openclaw CLI to the remote Azure Container Apps gateway, run diagnostics, and update config. WHEN: \"openclaw cli\", \"openclaw connect\", \"openclaw status\", \"openclaw doctor\", \"openclaw config\", \"openclaw channels\", \"openclaw devices\", \"openclaw agents\", \"connect to gateway\", \"gateway token\", \"approve device\", \"openclaw setup\", \"openclaw troubleshoot\""
---

# OpenClaw CLI — Remote Gateway Usage

Use the local `openclaw` CLI to connect to, configure, and troubleshoot the OpenClaw gateway running on Azure Container Apps. This is the **preferred** approach over `az containerapp exec` — it's faster, interactive, and not subject to Azure exec rate limits.

## Prerequisites

**1. Install the CLI (once per devcontainer):**
```bash
npm install -g openclaw
```

**2. Load the remote gateway environment (once per shell session):**
```bash
source <(./scripts/openclaw-connect.sh dev --export)
```
This sets `OPENCLAW_GATEWAY_URL` and `OPENCLAW_GATEWAY_TOKEN` from Key Vault so all subsequent `openclaw` commands target the remote gateway.

**Persistent alias** — add to `~/.bashrc` or `~/.zshrc`:
```bash
alias ocl-dev='source <(/workspaces/personal_ai_assistant/scripts/openclaw-connect.sh dev --export)'
```

## Device Pairing (First Time Only)

New devices (browser, devcontainer CLI) require one-time gateway approval. Run:
```bash
# From inside the container (exec) — needed for the first approval only:
az containerapp exec --name paa-dev-app --resource-group paa-dev-rg \
  --command "node /app/openclaw.mjs devices list"

az containerapp exec --name paa-dev-app --resource-group paa-dev-rg \
  --command "node /app/openclaw.mjs devices approve <requestId>"

# Once paired, all future approvals can use the local CLI:
openclaw devices approve <requestId>
```

> **Azure exec rate limit:** HTTP 429, retry-after ~600s. If you hit it, wait 10 min or use an already-paired device to approve.

## Diagnostic Commands

Run in order when troubleshooting:

```bash
openclaw status                   # fast summary
openclaw status --all             # full gateway + agent + channel snapshot
openclaw gateway probe            # reachability check
openclaw gateway status           # runtime vs RPC probe state
openclaw doctor --non-interactive # detect config/state issues
openclaw channels status --probe  # channel connectivity + auth token age
openclaw logs --follow            # tail live gateway log
```

If `openclaw logs` is unavailable (RPC down), fall back to:
```bash
az containerapp logs show --name paa-dev-app --resource-group paa-dev-rg \
  --type console --tail 100 --follow false
```

## Config Commands

```bash
openclaw config get <key>           # read a value
openclaw config set <key> <value>   # write a value (hot-reloads most changes)
openclaw configure                  # interactive setup wizard (all sections)
openclaw configure --section model  # wizard scoped to model/embedding config
```

**Hot-reload:** channels, models, agents, routing — no restart needed.  
**Restart required:** `gateway.*` settings (port, bind, auth) — confirm with the user first.

## Device & Pairing Management

```bash
openclaw devices list                      # list pending + paired devices
openclaw devices approve <requestId>       # approve pending pairing
openclaw devices reject <requestId>        # reject pending pairing
openclaw devices revoke <deviceId> <role>  # revoke a device token
```

## Agent & Memory Commands

```bash
openclaw agents status              # bootstrap file status, session count
openclaw memory status --deep       # embedding provider + DB health
openclaw security audit --deep      # security posture check
```

## Container Exec Fallback

Use only when the local CLI is unavailable (not yet installed, pairing not approved, or gateway scaled to zero):

```bash
az containerapp exec \
  --name paa-dev-app \
  --resource-group paa-dev-rg \
  --command "node /app/openclaw.mjs <subcommand>"
```

| Command | Purpose |
|---|---|
| `node /app/openclaw.mjs devices list` | List pending/paired devices |
| `node /app/openclaw.mjs devices approve <id>` | Approve first-time pairing |
| `node /app/openclaw.mjs status --all` | Full status from inside container |
| `node /app/openclaw.mjs doctor --non-interactive` | Config/state diagnostics |
| `cat /home/node/.openclaw/openclaw.json` | View config on Azure Files share |
