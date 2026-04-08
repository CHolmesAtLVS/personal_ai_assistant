# OpenClaw Product

## Product Purpose

OpenClaw is a personal AI assistant — an autonomous agent that connects to your messaging platforms, takes actions on your behalf, and works in the background while you get on with your day. It is self-hosted in your own Azure environment, backed by Azure AI Foundry, and accessible from anywhere via HTTPS.

The design goal is a **deploy-first, configure-after** baseline: everything needed to run OpenClaw is provisioned and configured automatically so it is functional on first boot. From that point, you personalize the assistant — adding communication channels, custom agent personas, skills, and integrations — while OpenClaw accumulates its own persistent state over time.

## Primary User and Access Model

### Primary User

- The home user who operates OpenClaw from an approved public IP address

### Access Constraints

- The service is reachable over HTTPS at `paa-dev.acmeadventure.ca` (dev) and `paa.acmeadventure.ca` (prod)
- Access is restricted to the user's approved home IP address
- Gateway token authentication is required for all connections

## Baseline Definition

The baseline is the minimum set of infrastructure and configuration that makes OpenClaw fully functional on first boot, without any manual setup steps.

### Layer 1 — Infrastructure

All required Azure cloud infrastructure is provisioned automatically via Terraform before the assistant starts. This covers compute, networking, TLS certificates, secrets management, persistent storage, the AI model backend, and cost monitoring. See [ARCHITECTURE.md](ARCHITECTURE.md) for the full infrastructure inventory.

### Layer 2 — Pre-Configured Assistant Settings

The assistant is pre-configured at deploy time with the minimum settings needed to connect to the AI backend and accept authenticated requests:

| Configuration area | Baseline value |
|---|---|
| Authentication | Token-based; token stored in Azure Key Vault |
| AI model provider | Azure AI Foundry |
| Primary chat model | `grok-4-fast-reasoning` (falls back to `grok-3`) |
| Lightweight model | `grok-3-mini` |
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

1. Maintainer opens a PR with the desired change (infrastructure, image version, or configuration).
2. CI/CD provisions or updates all Azure infrastructure and cluster platform tools automatically.
3. ArgoCD detects the change in Git and deploys the updated assistant configuration.
4. On first boot, the assistant loads its configuration, connects to the AI backend, and starts accepting requests.
5. Run `openclaw doctor` to confirm everything is healthy.

### User Configuration (post-deploy)

6. Access the OpenClaw web UI from `https://paa.acmeadventure.ca`.
7. Add messaging channels, custom agent personas, skills, and tool integrations.
8. Most changes take effect immediately; no restart required.

### Ongoing Operation

9. Interact with the assistant; conversation history, workspace files, and plugin state grow over time.
10. Persistent state is backed up automatically (once backup is implemented).
11. Monitor health and costs via `openclaw status` and Azure alerts.

## Product Guardrails

- Public repository is allowed, but never for secret storage
- Prefer identity-based service auth over static credentials
- Keep infrastructure changes declarative and reviewable
- Restrict exposure first, then incrementally add convenience features
- Baseline config ships with the minimum surface area; all optional capabilities require explicit user action to enable

## Near-Term Roadmap

1. **ACA decommission** — remove Azure Container Apps runtime after AKS validation (dev then prod, 7-day soak). See [plan/feature-aks-decommission-1.md](plan/feature-aks-decommission-1.md). *(In Progress)*
2. **Automated backup** — Azure Files share snapshots and Blob export scheduled via Terraform or a container sidecar.
3. **Authentication layer** in front of OpenClaw (in addition to gateway token auth).
4. **Image scanning** in CI pipeline.
5. **Alerting** for availability and failed-request signals.
6. **Managed Identity for Grok inference endpoint** — eliminate the last static API key once OpenClaw provider support is available.
