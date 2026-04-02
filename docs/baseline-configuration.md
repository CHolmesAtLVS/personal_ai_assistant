# OpenClaw Baseline Configuration Reference

This document covers the out-of-the-box gateway configuration seeded at deployment time, the rules governing config changes, and the backup strategy for persistent state. For Azure infrastructure details, see [ARCHITECTURE.md](../ARCHITECTURE.md). For operational procedures, see [openclaw-containerapp-operations.md](openclaw-containerapp-operations.md).

## How the Baseline is Delivered

Terraform writes an `openclaw.json` template to the Azure Files share before the container starts. All sensitive values use `${VAR_NAME}` substitution — they are resolved at runtime from Container App environment variables injected via Managed Identity. No secrets are hardcoded.

## Baseline `openclaw.json` Settings

| Config area | Baseline value | Notes |
|---|---|---|
| Gateway port | `18789` | Fixed; change requires restart |
| Gateway bind | `lan` | Fixed; change requires restart |
| Gateway auth | `token` via `${OPENCLAW_GATEWAY_TOKEN}` | Token sourced from Key Vault at startup |
| Control UI allowed origins | `${APP_FQDN}` | Scoped to the deployed Container App FQDN |
| AI model provider | `azure-foundry` | Points at the Azure AI Model Inference endpoint |
| AI auth | `${AZURE_AI_API_KEY}` | API key from Key Vault; Managed Identity planned |
| Primary chat model | `grok-4-fast-reasoning` (fallback: `grok-3`) | |
| Lightweight model | `grok-3-mini` | For cost-sensitive routing |
| Tool profile | `full` | All tools enabled; restrict post-deploy with `deny` rules |
| In-container update checks | Disabled (`update.checkOnStart: false`) | Image updates managed via Terraform image tag variable |

The baseline does not include channels, custom agents, skills, or integrations — those are added by users after deployment.

## Hot-Reload vs. Restart Required

| Config area | Behavior |
|---|---|
| Gateway block (port, bind, auth, TLS) | **Restart required** |
| Models, agents, channels, skills, routing | **Hot-reload** — applies without restart |

## Config Validation

OpenClaw enforces strict config validation on startup. An invalid `openclaw.json` (unknown keys, malformed types) prevents the gateway from starting entirely. If this happens, only `openclaw doctor`, `openclaw logs`, `openclaw health`, and `openclaw status` remain usable.

Always run `openclaw doctor` after first deployment and after any bulk config change to confirm the config is valid.

## Persistent State

All state that evolves over time is stored on the Azure Files share mounted at `/home/node/.openclaw`:

- Conversation history and session data
- Device registrations and auth tokens
- Installed plugin and skill state
- Workspace files generated during sessions

This state survives container restarts, revision deployments, and image updates because the share is mounted into every revision.

## Backup Strategy

The unit of backup is the Azure Files share at `/home/node/.openclaw`.

### Azure Files Share Snapshots (primary)

Native Azure Files snapshots capture point-in-time consistent copies of the share on a schedule. Recovery is performed by restoring from a snapshot in-place, or mounting the snapshot as read-only for selective file recovery.

### Offsite Blob Export (secondary)

A scheduled job exports the share contents to an Azure Blob Storage container in the same Storage Account. The Blob copy is an independent durable copy that survives share-level incidents and is accessible via standard Azure Storage tools.

Both mechanisms operate without stopping the container.
