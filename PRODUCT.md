# OpenClaw Product

## Product Purpose

OpenClaw is a personal AI assistant — an autonomous agent that connects to your messaging platforms, takes actions on your behalf, and works in the background while you get on with your day. It is self-hosted in your own Azure environment, backed by Azure AI Foundry, and accessible from anywhere via HTTPS.

The design goal is a **deploy-first, configure-after** baseline: everything needed to run OpenClaw is provisioned and configured automatically so it is functional on first boot. From that point, you personalize the assistant — adding communication channels, custom agent personas, skills, and integrations — while OpenClaw accumulates its own persistent state over time.

## Multi-Instance Model

OpenClaw supports deploying multiple independent instances on a shared AKS cluster. Each instance belongs to a named individual and is fully isolated in its own Kubernetes namespace, with its own persistent storage, gateway token, and managed identity. All instances share the underlying AKS cluster, AI Services endpoint, and Log Analytics workspace, which keeps infrastructure costs proportional to active usage.

Instance names are short alphabetic identifiers (2–3 letters, e.g. `ch`, `jh`, `kjm`) assigned per individual. The full DNS name is formed by prepending the instance name to the environment base domain.

| Environment | DNS pattern | Example |
|---|---|---|
| Production | `{instance}.{prod-domain}` | `ch.{prod-domain}` |
| Dev | `{instance}.{dev-domain}` | `ch.{dev-domain}` |

The authoritative list of deployed instances per environment is stored in the central Terraform variables file (see [ARCHITECTURE.md](ARCHITECTURE.md)). Adding a new instance is a one-line change to that file.

### Per-Instance User Model

- Each instance serves one named individual
- Each individual connects only to their own instance URL from an approved shared home IP address
- Each instance has its own gateway token; tokens are not shared across instances
- Each individual's conversation history, device registrations, and workspace files are stored in a dedicated Azure Files NFS share and are inaccessible to other instances

### Access Constraints

- All instance URLs are reachable over HTTPS only
- Ingress IP restriction applies at the gateway (shared home IP covers all instances)
- Gateway token authentication is required for all connections to any instance

## Baseline Definition

The baseline is the minimum set of infrastructure and configuration that makes OpenClaw fully functional on first boot, without any manual setup steps.

### Layer 1 — Infrastructure

All required Azure cloud infrastructure is provisioned automatically via Terraform before the assistant starts. This covers compute, networking, TLS certificates, secrets management, persistent storage, the AI model backend, and cost monitoring. See [ARCHITECTURE.md](ARCHITECTURE.md) for the full infrastructure inventory.

### Layer 2 — Pre-Configured Assistant Settings

Each instance is pre-configured at deploy time with the minimum settings needed to connect to the AI backend and accept authenticated requests. All instances share the same AI model endpoints but hold independent gateway tokens.

| Configuration area | Baseline value |
|---|---|
| Authentication | Token-based; each instance's token stored independently in Azure Key Vault |
| AI model provider | Azure AI Foundry (shared endpoint across all instances) |
| Primary chat model | `gpt-5.4-mini` |
| Tool access | Full — web, browser, filesystem, messaging, automation, canvas. Restrict specific tools post-deploy if needed. |
| Automatic update checks | Disabled; image updates are applied deliberately via deployment |

> **AI auth note:** The Azure AI Model Inference endpoint (Grok) currently requires an API key stored in Azure Key Vault; it is injected at runtime and never committed to source control. Managed Identity coverage for that endpoint is a planned improvement.

The baseline deliberately omits channels, custom agent personas, skills, and integrations. Those are user-configured after deployment.

> **Schema validation:** OpenClaw enforces strict config validation on startup. Run `openclaw doctor` after the first deployment to confirm the baseline config is valid.

### Layer 3 — User-Configured (post-deploy, runtime)

After the baseline is deployed and OpenClaw is running, the user personalizes the assistant through the OpenClaw web UI, CLI (`openclaw configure`), or by editing `openclaw.json` directly on the mounted Files share:

| Configuration area | Examples |
|---|---|
| Channels | Web, Slack, Teams, SMS, Discord integrations |
| Agent personas | Custom names, system prompts, specialized roles |
| MCP tool integrations | File system, browser, GitHub, database connectors |
| Model routing per agent | Assign specific models or fallback chains to individual agents |
| Skills and hooks | Cron jobs, post-processing hooks, custom skill packages |

### Layer 4 — Self-Managed by OpenClaw (evolves automatically)

OpenClaw manages this state in the persistent Files share. It evolves over time as the user interacts with the assistant:

- Device registrations and auth tokens
- Conversation history and session data
- Installed plugin state
- Workspace files generated during sessions

This state is preserved across restarts and redeployments because the persistent storage volume is mounted into every revision of the pod.

## Backup

> **Implementation status:** Automated backup is not yet implemented. This section describes the target design. Automated backup is Roadmap item 2.

The unit of backup is the persistent state volume at `/home/node/.openclaw`.

### Azure Files Share Snapshots (primary, planned)

Point-in-time snapshots of the storage share on a scheduled basis. Recovery restores from a snapshot in-place or mounts a snapshot for selective file recovery.

### Offsite Blob Export (secondary, planned)

A scheduled job exports the share contents to Azure Blob Storage on a regular cadence. The Blob copy survives share-level incidents and is accessible via standard Azure tools for audit or off-cloud extraction.

Both mechanisms will operate without stopping the assistant.

## Functional Capabilities

### 1. Autonomous AI Agent

- Connects to your messaging platforms (WhatsApp, Telegram, Signal, Slack, Discord, and more) and acts autonomously
- Give it a task, let it run, come back to results — less chatbot, more agent
- Supports multiple model deployments; route specific agents to specific models

### 2. Self-Hosted and Private

- Runs entirely in your own Azure environment; your data stays under your control
- No shared infrastructure; secrets managed in Azure Key Vault, never in source code
- Persistent state (conversations, sessions, installed skills, workspace files) survives restarts automatically

### 3. Extensible

- Add channels, custom agent personas, MCP tool integrations, and skills after initial deployment
- Most configuration changes take effect immediately without a restart
- Skills and integrations installed from ClawHub extend the assistant's capabilities

### 4. Observable

- Logs and diagnostics available via Azure monitoring and `openclaw status` / `openclaw doctor`
- Cost monitored via Azure Consumption Budget with configurable alert thresholds

## Non-Functional Requirements

- Security: no secret material in public repository artifacts
- Reliability: repeatable deployments; persistent state survives restarts
- Maintainability: Infrastructure as Code (Terraform) and GitOps (ArgoCD) as sources of truth
- Traceability: all deployments driven through GitHub Actions CI/CD
- Network control: HTTPS ingress; access restricted to the approved source IP
- Backup integrity: automated snapshots and Blob export (target design); both must be restorable without manual intervention once implemented
- Privacy: Azure tenant, subscription, identity, and DNS identifiers are not exposed in public-facing project docs

## Product Workflow

### Deployment (first-time or update)

1. Maintainer opens a PR with the desired change (infrastructure, image version, configuration, or new instance).
2. To add a new instance, add its short name to the `openclaw_instances` list in the environment's central Terraform variables file stored in Azure Blob Storage.
3. CI/CD provisions or updates all Azure infrastructure automatically (per-instance namespaces, managed identities, NFS shares, Key Vault secrets, OIDC federation).
4. ArgoCD detects the new or updated workload directory in Git and deploys the instance's Helm chart.
5. On first boot, the assistant loads its configuration, connects to the AI backend, and starts accepting requests.
6. Run `openclaw doctor` against the new instance's URL to confirm everything is healthy.

### User Configuration (post-deploy)

7. Access the OpenClaw web UI from `https://{instance}.{prod-domain}` (or `https://{instance}.{dev-domain}` for dev).
8. Add messaging channels, custom agent personas, skills, and tool integrations.
9. Most changes take effect immediately; no restart required.

### Ongoing Operation

10. Interact with the assistant; conversation history, workspace files, and plugin state grow over time.
11. Persistent state is isolated per instance and backed up automatically (once backup is implemented).
12. Monitor health and costs via `openclaw status` and Azure alerts.

## Product Guardrails

- Public repository is allowed, but never for secret storage
- Prefer identity-based service auth over static credentials
- Keep infrastructure changes declarative and reviewable
- Restrict exposure first, then incrementally add convenience features
- Baseline config ships with the minimum surface area; all optional capabilities require explicit user action to enable

## Near-Term Roadmap

1. **Multi-instance AKS deployment** — per-instance isolation on a shared AKS cluster; central Terraform variables file; per-instance DNS, gateway token, NFS share, and Managed Identity. *(In Progress)*
2. **Automated backup** — Azure Files share snapshots and Blob export scheduled via Terraform or a container sidecar.
3. **Authentication layer** in front of OpenClaw (in addition to gateway token auth).
4. **Image scanning** in CI pipeline.
5. **Alerting** for availability and failed-request signals.
6. **Managed Identity for Grok inference endpoint** — eliminate the last static API key once OpenClaw provider support is available.
