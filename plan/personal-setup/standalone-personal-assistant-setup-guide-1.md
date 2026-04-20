---
goal: Personal Setup Guide — Configure OpenClaw as a Personal Assistant
plan_type: standalone
version: 1.0
date_created: 2026-04-19
owner: Individual user / instance owner
status: 'Planned'
tags: [guide, configuration, personal, channels, agents, skills]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

This guide covers everything you need to do **after the infrastructure is deployed** to get OpenClaw working as your personal assistant. Infrastructure provisioning (Terraform, ArgoCD, AKS) is handled separately — this is the Layer 3 (user-configuration) walkthrough.

The guide is sequential. Complete Phase 1 first (verify the baseline is healthy), then add capabilities in whatever order suits you.

---

## 1. Requirements & Constraints

- **REQ-001**: OpenClaw instance must already be deployed and reachable at `https://{instance}.{domain}`.
- **REQ-002**: You must be on the approved home IP address — ingress is IP-restricted.
- **REQ-003**: You need your gateway token; it is stored in Azure Key Vault (your platform admin can retrieve it, or use `./scripts/openclaw-connect.sh` from the management repo).
- **REQ-004**: Each person's instance is their own — do not share gateway tokens across instances.
- **SEC-001**: Never save your gateway token in a plaintext file, browser bookmark, or shared note.
- **CON-001**: Gateway `.*` settings (port, bind, auth) require a pod restart. All other config (channels, agents, models, skills) hot-reloads with no restart.
- **GUD-001**: Use `openclaw doctor` after any significant config change to confirm the config is valid.
- **GUD-002**: Prefer the web UI or `openclaw configure` for first-time setup; edit `openclaw.json` directly only for bulk or advanced changes.

---

## 2. Implementation Steps

### Phase 1 — Access Your Instance & Verify Health

- **GOAL-001**: Confirm the baseline is healthy and you can authenticate before adding any personalisation.

| Task     | Description                                                                                                                                                                                                            | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | Open `https://{instance}.{domain}` in your browser. You should see the OpenClaw web UI login/connect screen.                                                                                                          |           |      |
| TASK-002 | Enter your gateway token when prompted. Your token is unique to your instance — obtain it from your platform admin or from Key Vault via `./scripts/openclaw-connect.sh {instance} --export` in the management repo. |           |      |
| TASK-003 | The UI should show the assistant ready to chat. Send a simple message (e.g. "Hello") to verify end-to-end AI connectivity.                                                                                             |           |      |
| TASK-004 | Optional: pair the device formally. In the web UI go to **Settings → Devices** and approve the pending pair request, or use the CLI: `openclaw devices list` then `openclaw devices approve <requestId>`.              |           |      |
| TASK-005 | Run a health check: open the CLI or use the browser console command `openclaw status --all`. All services should report healthy. If anything is red, run `openclaw doctor` and follow the suggested fixes.             |           |      |

---

### Phase 2 — Connect Your First Messaging Channel

- **GOAL-002**: Receive and reply to messages on at least one platform so the assistant works outside the web UI.

> OpenClaw supports: WhatsApp, Telegram, Signal, Slack, Discord, Teams, SMS, and more. Pick the one you use most.

| Task     | Description                                                                                                                                                                                                                                  | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-006 | In the web UI go to **Settings → Channels** and click **Add Channel**. Select your platform.                                                                                                                                                 |           |      |
| TASK-007 | Follow the platform-specific OAuth or bot-token setup shown in the wizard. For Telegram: create a Bot via @BotFather and paste the token. For Slack: create an app at api.slack.com, install it to your workspace, and paste the bot token. |           |      |
| TASK-008 | Save the channel. The UI should show the channel status turn green within a few seconds (hot-reload — no restart needed).                                                                                                                     |           |      |
| TASK-009 | Send yourself a test message from that platform to the assistant and confirm it replies.                                                                                                                                                      |           |      |
| TASK-010 | Optionally repeat TASK-006–009 for additional platforms (e.g. add both Telegram and Slack).                                                                                                                                                  |           |      |

---

### Phase 3 — Personalise Your Agent

- **GOAL-003**: Give the assistant a name, personality, and system prompt that matches how you want to use it.

| Task     | Description                                                                                                                                                                                                                    | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-011 | In the web UI go to **Settings → Agents** and open the default agent.                                                                                                                                                          |           |      |
| TASK-012 | Set a **name** (e.g. your preferred call-sign for the assistant).                                                                                                                                                              |           |      |
| TASK-013 | Write a **system prompt** that describes how you want the assistant to behave. Examples: tone (professional/casual), domains it specialises in, what it should always or never do, standing context about you (role, timezone). |           |      |
| TASK-014 | Optionally create additional specialised agents (e.g. one for research, one for writing, one for scheduling) each with its own system prompt.                                                                                   |           |      |
| TASK-015 | Save. Changes hot-reload immediately. Chat with the assistant to verify the persona is applied.                                                                                                                                 |           |      |

---

### Phase 4 — Install Skills from ClawHub

- **GOAL-004**: Extend the assistant's capabilities by installing skills that match your use case.

> Skills are packages that give the assistant new abilities — web search, calendar access, file processing, coding tools, etc.

| Task     | Description                                                                                                                                                                                          | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-016 | In the web UI go to **Settings → Skills → Browse ClawHub**. Browse available skill packages.                                                                                                         |           |      |
| TASK-017 | Install skills relevant to your use case. Good starting points for a personal assistant: **Web Search**, **Calendar**, **File Manager**, **Notes**, **Weather**.                                      |           |      |
| TASK-018 | After each install, test the skill by asking the assistant to use it (e.g. "Search the web for the latest on X", "Add a reminder for tomorrow at 9am").                                              |           |      |
| TASK-019 | For skills that require API keys (e.g. a calendar integration), the UI will prompt for the credential. Store it via the UI (it is written to your Azure Disk volume config — never to the Git repository). |           |      |

---

### Phase 5 — Add MCP Tool Integrations (Optional)

- **GOAL-005**: Connect external tools that the assistant can use autonomously to complete tasks.

> MCP (Model Context Protocol) integrations allow the assistant to browse the web, interact with GitHub, read/write files, query databases, and more. These are more powerful than skills and require a bit more configuration.

| Task     | Description                                                                                                                                                                                                         | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-020 | In the web UI go to **Settings → Tools / MCP**. The baseline ships with `tools.profile: full` so file system, browser, messaging, and automation are already enabled.                                               |           |      |
| TASK-021 | Add any additional MCP connectors you need. Common ones: **GitHub MCP** (reads/writes repos), **Browser MCP** (full web browsing), **Database MCP** (query your own databases).                                     |           |      |
| TASK-022 | For each connector, provide the required credentials via the UI wizard. Credentials are written to the config on your Azure Disk volume and referenced as `${VAR_NAME}` — never stored in plaintext in the YAML/JSON. |           |      |
| TASK-023 | Test each tool by asking the assistant to use it directly: "Open https://github.com/{your-repo} and summarise the last 5 commits."                                                                                  |           |      |

---

### Phase 6 — Day-to-Day Tips

- **GOAL-006**: Establish habits that keep the assistant useful and reliable over time.

| Task     | Description                                                                                                                                                                                                                   | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-024 | Bookmark `https://{instance}.{domain}` on your primary device. This is your main web interface.                                                                                                                               |           |      |
| TASK-025 | Register additional devices (phone, tablet) by visiting the URL from each device and approving the pair request via **Settings → Devices**.                                                                                   |           |      |
| TASK-026 | Be aware that conversation history, workspace files, and installed plugin state are all stored on your personal Azure Disk volume (`managed-csi-premium` PVC at `/home/node/.openclaw`) and persist across restarts. You do not need to re-configure after a pod restart or image upgrade.  |           |      |
| TASK-027 | To check health at any time: `openclaw status` (from CLI after running `source <(./scripts/openclaw-connect.sh {instance} --export)`) or visit **Settings → Status** in the web UI.                                          |           |      |
| TASK-028 | If something breaks: run `openclaw doctor`. It identifies and often auto-fixes config and state issues without requiring a restart.                                                                                            |           |      |
| TASK-029 | Image updates (new OpenClaw versions) are applied by the platform admin via a `Chart.yaml` `appVersion` bump merged to Git. ArgoCD rolls out the update automatically. Your config and state are preserved across updates.   |           |      |

---

## 3. Alternatives

- **ALT-001**: Edit `openclaw.json` directly on the Azure Disk volume instead of using the web UI (`kubectl exec -n openclaw-<inst> deployment/openclaw -- vi /home/node/.openclaw/openclaw.json`). This is faster for bulk changes but bypasses validation — always follow with `openclaw doctor`.
- **ALT-002**: Use `openclaw configure` (interactive CLI wizard) instead of the web UI. Equivalent capability, useful if you prefer terminal workflows.
- **ALT-003**: Use the management repo CLI alias approach (`alias ocl-dev=...` in `~/.bashrc`) for frequent CLI access rather than re-running the connect script each session.

## 4. Dependencies

- **DEP-001**: Instance deployed and healthy (Terraform + ArgoCD have completed successfully).
- **DEP-002**: Gateway token available (stored in Azure Key Vault; retrieve via `./scripts/openclaw-connect.sh`).
- **DEP-003**: Client device is on the approved home IP address (ingress is IP-restricted).
- **DEP-004**: For third-party channel integrations (Slack, Telegram, etc.): a bot/app token obtained from that platform's developer portal.

## 5. Files

- **FILE-001**: `config/openclaw.batch.json` — canonical config key reference (retained from ACA era; useful for understanding key paths).
- **FILE-002**: `workloads/dev/openclaw/bootstrap/configmap.yaml` — current dev instance openclaw.json template.
- **FILE-003**: `workloads/prod/openclaw/bootstrap/configmap.yaml` — current prod instance openclaw.json template.
- **FILE-004**: `scripts/openclaw-connect.sh` — retrieves gateway URL + token from Key Vault and exports them to the shell environment.

## 6. Testing

- **TEST-001**: After Phase 1, `openclaw status --all` returns no red items.
- **TEST-002**: After Phase 2, sending a message from the connected channel produces a reply from the assistant.
- **TEST-003**: After Phase 3, the assistant's first reply reflects the custom system prompt (name, tone, domain focus).
- **TEST-004**: After Phase 4, each installed skill can be invoked via a natural-language request and produces a valid result.
- **TEST-005**: After Phase 5, each MCP integration can be used in a real task (e.g. "summarise my GitHub notifications").

## 7. Risks & Assumptions

- **RISK-001**: If the gateway token rotates (e.g. after a Key Vault secret update), all devices will need to re-pair. The platform admin controls token rotation.
- **RISK-002**: Some third-party channel integrations (especially WhatsApp Business API) require additional account setup outside the OpenClaw wizard; allow extra time for those.
- **RISK-003**: Automated backup is not yet implemented (roadmap item 2 — Azure Disk snapshot policy via Terraform). Workspace files and conversation history on the Azure Disk volume (`/home/node/.openclaw`) are not currently backed up.
- **ASSUMPTION-001**: The instance is in the `prod` environment (or `dev` if you're testing). The URL and token differ per environment.
- **ASSUMPTION-002**: The `tools.profile` is set to `full` in the baseline (as defined in `config/openclaw.batch.json`), so all built-in tools are available without manual activation.

## 8. Related Specifications / Further Reading

- [PRODUCT.md](../../PRODUCT.md) — product overview, baseline definition, layer model
- [ARCHITECTURE.md](../../ARCHITECTURE.md) — infrastructure overview
- [openclaw-config skill](.github/skills/openclaw-config/SKILL.md) — full config schema, env var reference, hot-reload rules
- [openclaw-cli skill](.github/skills/openclaw-cli/SKILL.md) — CLI commands for connecting, diagnosing, and managing your instance
- [OpenClaw docs — gateway configuration](https://docs.openclaw.ai/gateway/configuration)
- [OpenClaw docs — troubleshooting](https://docs.openclaw.ai/help/troubleshooting)
- [OpenClaw docs — skills / ClawHub](https://docs.openclaw.ai/skills)
