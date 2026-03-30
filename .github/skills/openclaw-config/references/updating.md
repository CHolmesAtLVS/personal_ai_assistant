# Updating OpenClaw

Reference: [docs.openclaw.ai/install/updating](https://docs.openclaw.ai/install/updating)

## Recommended: `openclaw update`

Detects install type (npm or git), fetches latest, runs `openclaw doctor`, restarts gateway:

```bash
openclaw update
openclaw update --channel beta    # switch channel
openclaw update --tag main        # specific version/tag
openclaw update --dry-run         # preview without applying
```

## Alternative methods

```bash
curl -fsSL https://openclaw.ai/install.sh | bash  # re-run installer
npm i -g openclaw@latest                           # npm
pnpm add -g openclaw@latest                        # pnpm
```

## Auto-updater (off by default)

```jsonc
{
  "update": {
    "channel": "stable",
    "auto": {
      "enabled": true,
      "stableDelayHours": 6,
      "stableJitterHours": 12,
      "betaCheckIntervalHours": 1
    }
  }
}
```

| Channel | Behaviour |
|---|---|
| `stable` | Waits `stableDelayHours`, then applies with deterministic jitter |
| `beta` | Checks every `betaCheckIntervalHours`, applies immediately |
| `dev` | No auto-apply; use `openclaw update` manually |

Disable startup hint: `update.checkOnStart: false`.

## After updating

```bash
openclaw doctor          # migrate config, audit DM policies, check gateway health
openclaw gateway restart # restart gateway
openclaw health          # verify
```

## Rollback

```bash
# npm:
npm i -g openclaw@<version>
openclaw doctor && openclaw gateway restart

# source/git:
git fetch origin
git checkout "$(git rev-list -n 1 --before="2026-01-01" origin/main)"
pnpm install && pnpm build && openclaw gateway restart
# Return to latest: git checkout main && git pull
```

> **Container App deployments:** change the image tag in Terraform and re-deploy. Do not run `openclaw update` inside a managed container.
