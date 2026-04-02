# OpenClaw Product

## What It Is

OpenClaw is a personal AI assistant that runs as a secure, private cloud service — always available on demand, always yours. It connects to state-of-the-art AI models and gives you a capable, extensible assistant accessible from anywhere on your approved devices.

The guiding design principle is **deploy first, use immediately**: a fresh deployment boots into a fully functional assistant without any manual setup. From there, users personalize the experience — adding channels, agent personas, tool integrations, and automations — while the assistant builds up context and history over time.

## Who It's For

OpenClaw is designed for a single user — a home user running a private assistant from a trusted connection. The assistant retains your conversation history, builds context over time, and is available across devices and messaging platforms.

## Ready to Use on Day One

A deployment is immediately functional. Users don't need to configure infrastructure, manage credentials, or set up authentication — those concerns are handled automatically at deploy time.

What users get from the first boot:

- **AI conversation** — a capable assistant powered by Azure AI Foundry, ready for chat
- **Secure, private access** — end-to-end encrypted connections; only approved users can reach the service
- **Persistent memory** — conversation history, workspace files, and context survive across sessions and service updates
- **Full tool suite** — web browsing, file handling, messaging, automation, and canvas tools enabled by default

## What You Can Customize

After deployment, users personalize the assistant through the web UI or CLI:

| Area | What you can do |
|---|---|
| **Channels** | Connect Slack, Teams, SMS, Discord, or use the built-in web interface |
| **Agent personas** | Create named agents with custom personalities, system prompts, and roles |
| **Per-agent model routing** | Assign specific AI models to specific agents, or define fallback chains |
| **Tool integrations** | Add GitHub, database connectors, browser automation, and more via MCP |
| **Skills and automation** | Schedule jobs, add post-processing hooks, and install custom skill packages |

Channels, agents, model routing, and skills apply immediately — no restart required.

## Persistent State and Backup

Everything that makes the assistant yours — conversation history, device registrations, installed plugins, workspace files — is stored durably and survives service updates and restarts.

State is backed up automatically:

- **Point-in-time snapshots** — frequent captures of the full assistant state for fast recovery
- **Offsite export** — an independent durable copy stored separately, recoverable from serious incidents

Both backup mechanisms run in the background without interrupting the service.

## Capabilities

### Conversation and Reasoning

- Access to frontier AI models via Azure AI Foundry
- Multi-model support: route different tasks and agents to different models
- Reasoning-optimized and lightweight models available for cost-aware workflows

### Multi-Channel Access

- Built-in web interface available immediately
- Connect the assistant to Slack, Teams, SMS, Discord, and other platforms to reach it where you already work

### Tools and Automation

- Full tool suite enabled by default: browsing, file handling, automation, canvas, messaging
- MCP integrations extend reach to external systems and APIs
- Skills, cron jobs, and hooks enable proactive and scheduled behaviors

### Security and Privacy

- All traffic is end-to-end encrypted
- Credentials and conversation data never leave your private cloud environment
- Access is locked to approved users — all others are denied at the network boundary
- All secrets are managed by Azure at runtime; nothing sensitive enters source control

### Observability and Cost Control

- Service health is always visible
- Budget alerts notify you at spend thresholds so costs are never a surprise
- Logs and diagnostics available for operational clarity

## Roadmap

1. **Grok model suite** — Grok-4-fast-reasoning as primary, Grok-3 fallback, Grok-3-mini for lightweight tasks *(In Progress)*
2. **Custom domain** — a personal domain name with a managed HTTPS certificate
3. **Authentication layer** — user-facing login in front of the assistant, beyond gateway token auth
4. **Multi-user support** — assign a dedicated agent persona to each person sharing a deployment, with independent configuration per user
5. **Container image scanning** — automated security scanning in the CI pipeline
6. **Availability alerting** — proactive notification for service degradation or failed requests

## Guardrails

- Secrets never enter source control — all credentials are managed by the cloud platform at runtime
- Identity-based authentication is preferred over static credentials wherever supported
- The baseline ships with minimum surface area — optional capabilities require explicit action to enable
- Infrastructure changes are declarative and reviewed before they take effect
- Deployment metadata (tenant names, subscription IDs, DNS names) is treated as private operational information
