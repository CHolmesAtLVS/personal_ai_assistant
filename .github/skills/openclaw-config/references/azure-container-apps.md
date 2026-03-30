# Azure Container Apps — Config & Env Patterns

## How env vars are injected

Container App environment variables are the highest-priority source (process env). They are injected from Key Vault secrets via Managed Identity and are never overridden by lower-priority sources.

## Recommended patterns

| Pattern | Use for |
|---|---|
| Container App env var (from Key Vault secret ref) | API keys, gateway token — never on disk |
| `${VAR_NAME}` in `openclaw.json` | Reference injected vars in config string fields |
| SecretRef in config | For secret-typed fields that support it |

## What to avoid

- `env.shellEnv` — no interactive shell in container; nothing to import
- Hardcoding secrets in `openclaw.json` — it's stored on Azure Files (shared volume)
- `.env` files for secrets — lower precedence than Container App env vars; fine for non-sensitive defaults

## Key paths inside container

| Path | Purpose |
|---|---|
| `/home/node/.openclaw/openclaw.json` | Active config (Azure Files mount) |
| `/home/node/.openclaw/.env` | Optional non-overriding env vars (Azure Files mount) |
| `/tmp/openclaw/openclaw-<date>.log` | Log files |
