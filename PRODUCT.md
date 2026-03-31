# OpenClaw Product

## Product Purpose

OpenClaw is a personal AI assistant deployed as a containerized service on Azure Container Apps, backed by Azure AI Foundry as the LLM provider. The product is exposed via HTTPS with strict source-IP access control.

The design goal is a **deploy-first, configure-after** baseline: Terraform provisions all required Azure infrastructure and seeds a working initial `openclaw.json` so that OpenClaw is functional immediately on first boot. From that point, the user personalizes the assistant — adding channels, agents, skills, and integrations — while OpenClaw accumulates its own persistent state over time. All state is backed up automatically.

## Primary User and Access Model

### Primary User

- The home user who operates OpenClaw from an approved public IP address

### Access Constraints

- The service is internet-reachable only through HTTPS ingress
- Ingress is allow-listed to the user's home public IP only
- Requests from non-approved source IP addresses are denied

This provides a simple but effective protection boundary for a public endpoint.

## Baseline Definition

The baseline is the minimum set of infrastructure and configuration that makes OpenClaw fully functional on first boot, without any manual setup steps by the user.

### Layer 1 — Azure Infrastructure (Terraform-deployed)

These components are provisioned declaratively by Terraform and must be in place before the container starts:

| Component | Purpose |
|---|---|
| Azure Container Apps Environment + Container App | Hosts the OpenClaw container; HTTPS ingress, IP-restricted |
| Azure Files share (mounted at `/home/node/.openclaw`) | Persistent state: config, auth profiles, skills, workspace files |
| Azure Key Vault | Stores the gateway token secret; injected at runtime via Managed Identity |
| Azure AI Services account + AI Foundry Hub + Project | LLM endpoint and model deployments |
| User-Assigned Managed Identity | Authenticates the Container App to Key Vault and AI Services without static credentials |
| Log Analytics Workspace | Centralized telemetry sink for Container Apps Environment and Key Vault diagnostics |
| Azure Storage Account (shared with Files share) | Also serves as the backup target for Blob-based state exports |
| Consumption Budget + Monitor Action Group | Cost alerts at 50 %, 80 %, 100 % actual and 110 % forecasted thresholds |

### Layer 2 — Pre-Seeded OpenClaw Configuration (first-run `openclaw.json`)

Terraform writes an `openclaw.json` template to the Azure Files share before the container starts. This file configures the minimum required settings so OpenClaw connects to AI Foundry and accepts authenticated requests on first boot. It contains no hardcoded secrets — all sensitive values are referenced as `${VAR_NAME}` and resolved from Container App environment variables injected via Managed Identity at runtime.

| Configuration area | Baseline value |
|---|---|
| Gateway port | `18789` |
| Gateway bind | `lan` |
| Gateway auth mode | `token` — token resolved from Key Vault via `${OPENCLAW_GATEWAY_TOKEN}` |
| Control UI allowed origins | Restricted to the deployed Container App FQDN via `${APP_FQDN}` |
| AI model provider | Custom `azure-foundry` provider pointing at the AI Model Inference endpoint |
| AI auth method | API key injected from Key Vault via `${AZURE_AI_API_KEY}` (see note below) |
| Primary chat model | `grok-4-fast-reasoning` (falls back to `grok-3`) |
| Lightweight model | `grok-3-mini` |
| Tool profile | `full` — all tools unrestricted; the assistant needs web, browser, messaging, automation, and canvas in addition to filesystem and runtime tools. User can add explicit `deny` rules post-deploy to restrict specific tools. |
| In-container update checks | Disabled (`update.checkOnStart: false`); image updates are applied by bumping the Terraform image tag variable |

> **AI auth note:** Key Vault access and Azure RBAC use Managed Identity throughout. The Azure AI Model Inference endpoint (Grok) currently requires an API key because OpenClaw's custom provider does not yet support Azure Managed Identity token acquisition for that endpoint type. The API key is stored in Key Vault and injected at runtime — it is never committed to source control. Managed Identity coverage for the inference endpoint is a planned improvement pending OpenClaw provider support.

The baseline config deliberately omits channels, custom agents, skills, and integrations. Those are user-configured after deployment.

Changes to the gateway block (port, bind, auth, TLS) require a container restart. All other config areas (models, agents, channels, skills, routing) hot-reload without a restart.

> **Schema validation:** OpenClaw enforces strict config validation — an invalid `openclaw.json` (unknown keys, malformed types) prevents the gateway from starting entirely. Only `openclaw doctor`, `logs`, `health`, and `status` remain usable in that state. Run `openclaw doctor` after the first deployment to confirm the pre-seeded config is valid.

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

This state is preserved across container restarts and revision deployments because the Azure Files share is mounted into every revision.

## Backup

> **Implementation status:** Neither backup mechanism is implemented in Terraform yet — this section describes the target design. Automated backup is Roadmap item 2.

The unit of backup is the Azure Files share at `/home/node/.openclaw`.

### Azure Files Share Snapshots (primary, planned)

Azure Files native snapshots will capture point-in-time consistent copies of the share on a scheduled basis. Recovery will be performed by restoring from a snapshot in-place or mounting the snapshot as a read-only share for selective file recovery.

### Offsite Blob Export (secondary, planned)

A scheduled job will export the contents of the Files share to an Azure Blob Storage container in the same Storage Account on a regular cadence. The Blob copy provides an independent, durable copy that survives share-level incidents and is accessible via standard Azure Storage tools for audit or off-cloud extraction.

Both mechanisms will operate without requiring the container to be stopped.

## Functional Capabilities

### 1. LLM Interaction

- Accepts user prompts via the OpenClaw web interface and configured channels
- Routes requests to the configured Azure AI Foundry model endpoint
- Returns model responses to the user interface
- Supports multiple model deployments; user can select model per session or configure per-agent routing

### 2. Cloud-Native Runtime

- Runs OpenClaw from the pre-built public image at `ghcr.io/openclaw/openclaw`, pinned to an explicit version tag
- Hosts the container in Azure Container Apps
- Persists all long-lived user data to an Azure Files share mounted at `/home/node/.openclaw`; data survives container restarts and revision deployments
- Gateway token authentication is enforced at startup; token is stored in Azure Key Vault and injected via Managed Identity

### 3. Secure Configuration Handling

- Uses Managed Identity for Key Vault access and Azure RBAC role assignments; the Azure AI Model Inference endpoint (Grok) currently uses an API key stored in Key Vault and injected at runtime — Managed Identity coverage for that endpoint is a planned improvement
- Stores secrets outside source code in Azure-managed secret stores
- Injects non-secret settings at runtime rather than hardcoding; `${VAR_NAME}` substitution in `openclaw.json` makes the mapping auditable
- No credentials committed to source control or Terraform state output

### 4. Observability

- Emits operational logs and telemetry to Azure monitoring services
- Supports troubleshooting and health visibility through Log Analytics and `openclaw status`/`openclaw doctor` CLI
- Cost visibility via Consumption Budget alerts

## Non-Functional Requirements

- Security: no secret material in public repository artifacts
- Reliability: managed Azure runtime and repeatable deployments; persistent state survives restarts
- Maintainability: Terraform as Infrastructure as Code source of truth
- Traceability: CI/CD-driven deployments through GitHub Actions
- Network control: HTTPS ingress constrained to approved source IP
- Backup integrity: automated snapshots and Blob export (target design); both must be restorable without manual intervention once implemented
- Privacy of deployment metadata: do not expose Azure tenant, subscription, identity object, or DNS identifiers in public-facing project docs

## Product Workflow

### Deployment (first-time or update)

1. Maintainer updates Terraform (or bumps the pinned image tag variable) in GitHub.
2. CI/CD applies Terraform to provision or update all baseline Azure resources.
3. Terraform writes the pre-seeded `openclaw.json` template to the Azure Files share.
4. Container Apps pulls the pre-built OpenClaw image at the pinned tag and starts the container.
5. The container reads `openclaw-gateway-token` from Key Vault via Managed Identity and starts the gateway.
6. OpenClaw is functional on first boot — AI Foundry is reachable and gateway auth is enforced.
7. Run `openclaw doctor` (via the openclaw-cli skill) to validate the pre-seeded config and confirm gateway health.

### User Configuration (post-deploy)

8. User accesses the OpenClaw web UI or CLI from the approved home IP.
9. User adds channels, custom agents, skills, and MCP integrations through the OpenClaw interface.
10. OpenClaw hot-reloads most config changes without requiring a container restart.

### Ongoing Operation

11. User interacts with OpenClaw; conversation history, workspace files, and plugin state accumulate in the Files share.
12. Azure Files snapshots and Blob export jobs run on schedule, backing up all persistent state.
13. Logs and diagnostics are available in Log Analytics and via `openclaw status`.

## Product Guardrails

- Public repository is allowed, but never for secret storage
- Prefer identity-based service auth over static credentials
- Keep infrastructure changes declarative and reviewable
- Restrict exposure first, then incrementally add convenience features
- Baseline config ships with the minimum surface area; all optional capabilities require explicit user action to enable

## Near-Term Roadmap

1. **Multi-model deployment** — Grok-4-fast-reasoning as primary, Grok-3 fallback, Grok-3-mini lightweight; remove GPT-4o once Grok is validated in dev. *(In Progress)*
2. **Automated backup** — Azure Files share snapshots and Blob export scheduled via Terraform or a container sidecar.
3. **Custom domain and managed TLS certificate.**
4. **Authentication layer** in front of OpenClaw (in addition to gateway token auth).
5. **Dev/prod environment split.**
6. **Image scanning** in CI pipeline.
7. **Alerting** for availability and failed-request signals.
