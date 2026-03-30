# Triage & Diagnostic Commands

Reference: [docs.openclaw.ai/help/troubleshooting](https://docs.openclaw.ai/help/troubleshooting) · [docs.openclaw.ai/help/debugging](https://docs.openclaw.ai/help/debugging)

## Full diagnostic commands

| Command | Purpose |
|---|---|
| `openclaw status` | Fast summary: channels, agents, gateway reachability |
| `openclaw status --all` | Full read-only report with log tail (tokens redacted) |
| `openclaw status --deep` | Health + provider probes (requires reachable gateway) |
| `openclaw gateway probe` | Test gateway connectivity |
| `openclaw gateway status` | Runtime vs RPC reachability, probe target URL |
| `openclaw doctor` | Detect and repair config/state issues |
| `openclaw doctor --non-interactive` | Same, no prompts (for scripted/container use) |
| `openclaw doctor --fix` | Auto-apply repairs |
| `openclaw health --json` | Full gateway snapshot (WebSocket only) |
| `openclaw health --verbose` | Health snapshot with URL and config path on errors |
| `openclaw channels status --probe` | Channel connectivity checks |
| `openclaw logs --follow` | Tail gateway log |
| `cat ~/.openclaw/openclaw.json` | View active config on disk |

**Expected good output:** `openclaw gateway probe` → `Reachable: yes` · `openclaw gateway status` → `Runtime: running`, `RPC probe: ok` · `openclaw doctor` → no blocking errors · `openclaw channels status --probe` → `connected` or `ready`

## `/debug` runtime overrides

Enable with `commands.debug: true` in config. Sets runtime-only overrides (memory, not disk):

```
/debug show
/debug set messages.responsePrefix="[openclaw]"
/debug unset messages.responsePrefix
/debug reset
```

`/debug reset` reverts to on-disk config.

## Raw stream logging

Log the raw assistant stream before filtering (reasoning block debugging):

```bash
OPENCLAW_RAW_STREAM=1 openclaw gateway run
OPENCLAW_RAW_STREAM_PATH=~/.openclaw/logs/raw-stream.jsonl  # optional path override
```

**Safety:** raw stream logs contain full prompts and user data. Keep local; scrub before sharing.

## Dev profile

Isolate state for safe debugging:

```bash
OPENCLAW_PROFILE=dev openclaw gateway --dev
```

- State dir: `~/.openclaw-dev`, port: `19001`
- Auto-creates default config+workspace, skips bootstrap and channel providers
- Reset: `OPENCLAW_PROFILE=dev openclaw gateway --dev --reset`
