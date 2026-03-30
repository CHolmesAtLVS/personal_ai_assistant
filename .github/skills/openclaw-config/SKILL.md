---
name: openclaw-config
description: "Expert reference for the OpenClaw gateway: openclaw.json schema, environment variables, env-var precedence, ${VAR} substitution, SecretRef, hot-reload rules, triage CLI, debugging, updating, and Kubernetes deployment. WHEN: \"configure openclaw\", \"openclaw config\", \"openclaw.json\", \"env var openclaw\", \"openclaw environment\", \"openclaw doctor\", \"config not loading\", \"gateway won't start\", \"openclaw troubleshoot\", \"update openclaw\", \"openclaw kubernetes\", \"openclaw k8s\", \"openclaw upgrade\""
license: MIT
metadata:
  author: Platform Engineering
  version: "1.3.0"
  domain: openclaw
  scope: configuration
---

# OpenClaw Configuration

Expert reference for configuring an OpenClaw gateway. Fetch the relevant page with `web` — docs are ground truth.  
[gateway/configuration](https://docs.openclaw.ai/gateway/configuration) · [configuration-reference](https://docs.openclaw.ai/gateway/configuration-reference) · [help/environment](https://docs.openclaw.ai/help/environment) · [help/troubleshooting](https://docs.openclaw.ai/help/troubleshooting) · [help/debugging](https://docs.openclaw.ai/help/debugging) · [help/faq](https://docs.openclaw.ai/help/faq) · [install/updating](https://docs.openclaw.ai/install/updating) · [install/kubernetes](https://docs.openclaw.ai/install/kubernetes)

## When to Use

- Writing or editing `openclaw.json`
- Configuring env vars, secrets, model providers, or channels
- Diagnosing gateway startup failures, channel disconnects, or model auth errors
- Understanding hot-reload rules, updating, or rollback procedures

---

## Config File

Location: `~/.openclaw/openclaw.json` (JSON5, optional — safe defaults if missing)

| Env var | Purpose |
|---|---|
| `OPENCLAW_CONFIG_PATH` | Override config file path |
| `OPENCLAW_STATE_DIR` | Override state directory (default `~/.openclaw`) |
| `OPENCLAW_HOME` | Override home directory for all path resolution |

**Strict validation:** Invalid `openclaw.json` prevents gateway startup. Only `openclaw doctor`, `openclaw logs`, `openclaw health`, and `openclaw status` remain available. Run `openclaw doctor --fix` to repair.

Edit interactively: `openclaw configure` or via the Control UI. Large configs can use `$include` to split across files.

---

## Environment Variables

### Precedence (highest → lowest)

1. Process environment (shell / service-injected)
2. `.env` in CWD (non-overriding)
3. `~/.openclaw/.env` (non-overriding)
4. Config `env` block in `openclaw.json` (non-overriding)
5. Shell env import (`OPENCLAW_LOAD_SHELL_ENV=1`, non-overriding)

→ Full env vars table + `env` block patterns: [references/env-vars.md](references/env-vars.md)

---

## Secret Injection

Use `${VAR_NAME}` in any config string value to reference process env vars. Use SecretRef objects for secret-typed fields. Both resolve from process env at activation time.

→ Examples and patterns: [references/secret-injection.md](references/secret-injection.md)

---

## Hot-Reload vs. Restart Required

| Config area | Requires restart? |
|---|---|
| `channels.*`, `agent`, `agents`, `models`, `routing` | No |
| `hooks`, `cron`, `session`, `messages`, `tools`, `skills` | No |
| `ui`, `logging`, `identity`, `bindings` | No |
| `gateway.*` (port, bind, auth, tailscale, TLS, HTTP) | **Yes** |
| `discovery`, `canvasHost`, `plugins` | **Yes** |

Default mode: `hybrid` — auto-restarts on critical changes. Environment variable changes (process env) always require a restart.

---

## Triage CLI Ladder

Run in order when something is broken:

```bash
openclaw status                  # fast local summary
openclaw status --all            # full diagnosis (tokens redacted, safe to share)
openclaw gateway probe           # check gateway reachability
openclaw gateway status          # runtime vs RPC probe state
openclaw doctor                  # repair/migrate config+state, health checks
openclaw channels status --probe # channel connectivity
openclaw logs --follow           # tail live log
```

If RPC is down: `tail -f "$(ls -t /tmp/openclaw/openclaw-*.log | head -1)"`

→ Full commands + debug tools: [references/triage-commands.md](references/triage-commands.md)

---

## Debugging Tools

Enable `/debug` in chat for runtime-only config overrides (requires `commands.debug: true`). Use `OPENCLAW_RAW_STREAM=1` to log the raw assistant stream before filtering.

→ Full details: [references/triage-commands.md](references/triage-commands.md)

---

## Common Config Issues

→ Symptom → fix table: [references/faq.md](references/faq.md)

---

## Deployment Notes (Azure Container Apps)

Process env (Container App vars injected from Key Vault via Managed Identity) is the highest-priority source. Use `${VAR}` in config for references. Do not use `env.shellEnv` (no login shell in container). Config: `/home/node/.openclaw/openclaw.json`.

→ Full ACA patterns: [references/azure-container-apps.md](references/azure-container-apps.md)

---

## Updating

Quick update: `openclaw update` (detects install type, fetches latest, runs `openclaw doctor`, restarts gateway).  
After any update: `openclaw doctor && openclaw gateway restart && openclaw health`

> **Container App deployments:** change the image tag in Terraform and re-deploy. Do not run `openclaw update` inside a managed container.

→ Full update methods, auto-updater config, rollback: [references/updating.md](references/updating.md)

---

## Kubernetes Deployment

Single pod with a PVC, ConfigMap (`openclaw.json` + `AGENTS.md`), and a Secret. Deploy with `./scripts/k8s/deploy.sh`.

→ Full operations guide: [references/kubernetes.md](references/kubernetes.md)

---

## References

- [Env vars & shell import](references/env-vars.md) — full `OPENCLAW_*` vars table + `env` block patterns
- [Secret injection](references/secret-injection.md) — `${VAR}` substitution and SecretRef patterns
- [Triage & diagnostic commands](references/triage-commands.md) — full CLI ladder, `/debug`, raw stream, dev profile
- [Common config issues](references/faq.md) — symptom → fix table
- [Azure Container Apps](references/azure-container-apps.md) — ACA-specific env/config patterns
- [Updating](references/updating.md) — `openclaw update`, auto-updater config, rollback
- [Kubernetes](references/kubernetes.md) — K8s deployment and operations
