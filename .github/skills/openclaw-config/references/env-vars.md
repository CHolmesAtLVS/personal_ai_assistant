# OpenClaw Environment Variables

Reference: [docs.openclaw.ai/help/environment](https://docs.openclaw.ai/help/environment)

## All env vars

| Variable | Purpose |
|---|---|
| `OPENCLAW_HOME` | Override home directory (replaces `~`); enables filesystem isolation for service accounts |
| `OPENCLAW_STATE_DIR` | Override state directory (default `~/.openclaw`) |
| `OPENCLAW_CONFIG_PATH` | Override config file path (default `~/.openclaw/openclaw.json`) |
| `OPENCLAW_GATEWAY_TOKEN` | Gateway auth token (for `token` auth mode) |
| `OPENCLAW_GATEWAY_PORT` | Override gateway port (default `18789`) |
| `OPENCLAW_LOG_LEVEL` | Override log level (`debug`, `trace`, etc.). Beats `logging.level` in config |
| `OPENCLAW_LOAD_SHELL_ENV` | Set to `1` to enable shell env import at startup |
| `OPENCLAW_SHELL_ENV_TIMEOUT_MS` | Timeout ms for shell env import (default `15000`) |
| `OPENCLAW_RAW_STREAM` | Set to `1` to log raw assistant stream to file (debugging) |
| `OPENCLAW_RAW_STREAM_PATH` | Override raw stream log path (default `~/.openclaw/logs/raw-stream.jsonl`) |
| `OPENCLAW_PROFILE` | Set to `dev` to isolate state under `~/.openclaw-dev` (port shifts to `19001`) |
| `NODE_EXTRA_CA_CERTS` | CA bundle path; required for nvm-installed Node to fix `web_fetch` TLS failures |

## Config `env` block

Supply API keys without overriding the process environment:

```jsonc
{
  "env": {
    "OPENROUTER_API_KEY": "sk-or-...",
    "vars": {
      "GROQ_API_KEY": "gsk-..."
    }
  }
}
```

`env.<KEY>` and `env.vars.<KEY>` are equivalent. Both are non-overriding — they only fill in missing vars.

**Never put real secrets in committed config files.**

## Shell env import

```jsonc
{
  "env": {
    "shellEnv": {
      "enabled": true,
      "timeoutMs": 15000
    }
  }
}
```

Env var equivalents: `OPENCLAW_LOAD_SHELL_ENV=1`, `OPENCLAW_SHELL_ENV_TIMEOUT_MS=15000`.

Spawns a login shell and imports missing expected keys. NOTE: `NODE_EXTRA_CA_CERTS` must be in process env before Node starts — `.env` files are too late.
