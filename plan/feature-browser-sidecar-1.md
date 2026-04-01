---
goal: Deploy headless Chromium sidecar Container App for OpenClaw browser tool
plan_type: standalone
version: 1.0
date_created: 2026-03-31
last_updated: 2026-03-31
owner: Platform Engineering
status: 'Planned'
tags: [feature, infrastructure, terraform, azure-container-apps, browser, security, sidecar]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

OpenClaw's browser tool requires a running Chromium instance accessible via Chrome DevTools Protocol (CDP). Azure Container Apps provides no Docker daemon to the container process, so OpenClaw's built-in Docker sandbox browser is unavailable. This plan deploys a headless Chromium Container App as a stateless internal-only sidecar within the same ACA Environment. OpenClaw connects to it via a `cdpUrl` remote browser profile — attach-only, no browser control service spawned, CRITICAL security finding from `openclaw security audit` eliminated.

The `browser` block in `openclaw.json.tpl` is configured in [feature-openclaw-config-hardening-1.md](feature-openclaw-config-hardening-1.md) (TASK-005), which depends on this plan's Phase 1 completing first.

---

## 1. Requirements & Constraints

- **REQ-001**: The browser sidecar Container App must have **no external ingress**. The CDP port must only be reachable within the ACA Environment (internal FQDN). No public route to any CDP port.
- **REQ-002**: The sidecar must have no Managed Identity, no Key Vault access, no access to the OpenClaw state file share (`openclaw-state`). It is a stateless, isolated compute unit.
- **REQ-003**: The Chromium image must be pinned to a specific digest (not `latest` or a mutable tag). The digest must be recorded in this plan before TASK-003 is actioned.
- **REQ-004**: The sidecar must inject `BROWSER_SIDECAR_HOST` (its own internal FQDN) into the OpenClaw Container App env so `openclaw.json.tpl` can reference `${BROWSER_SIDECAR_HOST}` without a hard-coded hostname.
- **SEC-001**: SSRF hardening is enforced at the OpenClaw config layer (`browser.ssrfPolicy.dangerouslyAllowPrivateNetwork: false` in `openclaw.json.tpl`) — configured in [feature-openclaw-config-hardening-1.md](feature-openclaw-config-hardening-1.md). This plan must not relax that requirement.
- **SEC-002**: The Chromium container must not run as root. Confirm the chosen image supports a non-root user and document the UID.
- **CON-001**: OpenClaw's Docker sandbox browser backend is not available in ACA (no Docker daemon). The `cdpUrl` remote profile is the only viable browser approach.
- **CON-002**: ACA internal ingress routes traffic on the configured `target_port` to the container. The sidecar's ingress `target_port` must match the port Chromium listens on for CDP connections. Confirm before Terraform apply.
- **CON-003**: ACA intra-environment TCP connectivity on non-HTTP ports (e.g. raw CDP port 9222) must be verified in dev. If ACA only routes HTTP/HTTPS over internal ingress, a Chromium image with an HTTP wrapper (e.g. `browserless/chrome` on port 3000) may be required.
- **CON-004**: All Terraform changes must be validated in dev before applying to prod.
- **GUD-001**: Follow the existing `${local.name_prefix}-*` naming convention from `terraform/locals.tf`. Browser sidecar name: `${local.name_prefix}-browser`.
- **PAT-001**: Use `Azure/avm-res-app-containerapp/azurerm ~> 0.3` — the same AVM module already used for the main OpenClaw Container App. Do not introduce raw `azurerm_container_app` resource blocks.

---

## 2. Implementation Steps

### Implementation Phase 1 — Image Evaluation and Terraform Infrastructure

- GOAL-001: Select, evaluate, and pin a headless Chromium image. Deploy the browser sidecar Container App via Terraform. Inject `BROWSER_SIDECAR_HOST` into the OpenClaw Container App env.

| Task | Description | Completed | Date |
|---|---|---|---|
| TASK-001 | Evaluate headless Chromium image candidates. Primary candidate: `ghcr.io/browserless/chromium` (HTTP API wrapper on port 3000, CDP-compatible, maintained, non-root support). Alternative: `zenika/alpine-chrome` (raw CDP on port 9222, Alpine-based). Run the chosen image locally (`docker run --rm -p <port>:<port> <image>`) and verify CDP responsiveness via `http://localhost:<port>/json/version`. Record the chosen image, its CDP/HTTP port, and its current digest (e.g. `docker inspect --format='{{index .RepoDigests 0}}' <image>`) in this plan before proceeding. | | |
| TASK-002 | Record chosen image details here (update this plan): **Image**: `<image>@<digest>` · **Port**: `<port>` · **Non-root UID**: `<uid>` | | |
| TASK-003 | In `terraform/locals.tf`, add: `browser_app_name = "${local.name_prefix}-browser"`. | | |
| TASK-004 | Create `terraform/browser.tf`. Add `module "browser_container_app"` using `Azure/avm-res-app-containerapp/azurerm ~> 0.3`. Configuration: `name = local.browser_app_name`, same `resource_group_name` and `container_app_environment_resource_id` as the main app, `revision_mode = "Single"`, `enable_telemetry = true`. No `managed_identities`, no `secrets`, no `registries`. Container: image from TASK-002 (pinned digest), `cpu = 0.5`, `memory = "1Gi"`, `min_replicas = 0`, `max_replicas = 1`. Ingress: `external_enabled = false`, `target_port = <port from TASK-002>`, `transport = "auto"`. No volumes, no state share mounts. | | |
| TASK-005 | In `terraform/outputs.tf`, add output `browser_container_app_fqdn`: `value = module.browser_container_app.fqdn_url` (or the equivalent AVM module output — verify attribute name against the module's outputs after `terraform plan`). Mark `sensitive = false` (internal FQDN is not a secret). | | |
| TASK-006 | In `terraform/containerapp.tf`, add to the OpenClaw container `env` block: `{ name = "BROWSER_SIDECAR_HOST", value = module.browser_container_app.fqdn_url }` (use the same attribute reference confirmed in TASK-005). This Terraform reference must be used — no hard-coded string. | | |

---

### Implementation Phase 2 — Terraform Apply (Dev)

- GOAL-002: Apply Terraform to dev. Verify the sidecar is reachable from the OpenClaw container within the ACA Environment.

| Task | Description | Completed | Date |
|---|---|---|---|
| TASK-007 | Run `terraform plan -var-file=../scripts/dev.tfvars` from `terraform/`. Confirm plan shows: new `browser_container_app`, `BROWSER_SIDECAR_HOST` env var addition to OpenClaw Container App, no unexpected changes to ingress, KV, identity, or storage resources. | | |
| TASK-008 | Run `terraform apply -var-file=../scripts/dev.tfvars` against dev. Confirm browser Container App is provisioned and running. Record the internal FQDN from `terraform output browser_container_app_fqdn`. | | |
| TASK-009 | From within the OpenClaw container (via `openclaw exec` or `az containerapp exec`), run: `curl http://${BROWSER_SIDECAR_HOST}:<port>/json/version` and confirm a JSON response is returned. This verifies intra-environment TCP connectivity on the CDP port. If curl is not available in the OpenClaw image, use `openclaw exec "node -e \"require('http').get('http://${BROWSER_SIDECAR_HOST}:<port>/json/version', r => r.pipe(process.stdout))\""`. | | |

---

## 3. Alternatives

- **ALT-001**: Use OpenClaw's Docker sandbox browser (`agents.defaults.sandbox.browser`). Rejected: requires Docker daemon access from within the Container App process. ACA does not expose a Docker socket; Docker-in-Docker requires privileged mode which ACA does not support.
- **ALT-002**: Use `zenika/alpine-chrome` (raw CDP port 9222) instead of `browserless/chromium`. Viable if ACA internal ingress passes raw TCP on non-HTTP ports. `browserless/chromium` is preferred because its HTTP API wrapper simplifies connectivity verification (`/json/version` over HTTP) and is more actively maintained. Can be substituted in TASK-001 if the HTTP-wrapper approach causes issues.
- **ALT-003**: Run Chromium directly in the OpenClaw container (custom image). Rejected: couples browser lifecycle to the gateway process, increases image size, reintroduces the browser control service (port 18791) and the CRITICAL security finding.
- **ALT-004**: Use Playwright server image (`mcr.microsoft.com/playwright`). Viable alternative to `browserless/chromium`. Playwright server exposes a WebSocket endpoint that is CDP-compatible. Evaluate in TASK-001 if preferred.

---

## 4. Dependencies

- **DEP-001**: ACA Environment (`module.container_apps_environment`) must already exist. It does — the main OpenClaw Container App depends on it.
- **DEP-002**: Terraform dev workspace must be initialized: `terraform init -backend-config=backend.dev.hcl`.
- **DEP-003**: The AVM module `Azure/avm-res-app-containerapp/azurerm ~> 0.3` must support `external_enabled = false` for internal-only ingress. Confirmed by module documentation; verify in `terraform plan` output.
- **DEP-004**: [feature-openclaw-config-hardening-1.md](feature-openclaw-config-hardening-1.md) TASK-005 (browser block in `openclaw.json.tpl`) must be applied after this plan's Phase 1 is complete and `BROWSER_SIDECAR_HOST` is available in the OpenClaw Container App env.

---

## 5. Files

- **FILE-001**: `terraform/browser.tf` (new) — browser sidecar Container App module block (TASK-004).
- **FILE-002**: `terraform/locals.tf` — add `browser_app_name` local (TASK-003).
- **FILE-003**: `terraform/outputs.tf` — add `browser_container_app_fqdn` output (TASK-005).
- **FILE-004**: `terraform/containerapp.tf` — add `BROWSER_SIDECAR_HOST` env var to OpenClaw container (TASK-006).

---

## 6. Testing

All tests must be executed against the **dev environment** only.

### TEST-001 — Browser sidecar is internal-only (no external route)

**Steps:**
1. From outside Azure (local machine), attempt to connect to the browser sidecar FQDN on the CDP port.
2. Confirm connection is refused or times out.

**Pass criteria:** CDP port unreachable from outside the ACA environment.

### TEST-002 — Intra-environment CDP connectivity

**Steps:**
1. From inside the OpenClaw container, run: `curl http://${BROWSER_SIDECAR_HOST}:<port>/json/version`
2. Confirm JSON response with Chromium version details is returned.

**Pass criteria:** CDP endpoint responds within 30 s (allowing for cold-start).

### TEST-003 — Browser tool functional end-to-end

**Steps:**
1. After TASK-005 in [feature-openclaw-config-hardening-1.md](feature-openclaw-config-hardening-1.md) is applied (hot-reload or gateway restart), ask the agent to navigate to `https://example.com` using the browser tool.
2. Confirm the agent returns page content or a screenshot.
3. Confirm no "browser control not ready" or auth errors appear.

**Pass criteria:** Browser navigation to a public URL succeeds.

### TEST-004 — SSRF blocked (depends on openclaw.json.tpl SSRF config)

**Steps:**
1. Ask the agent to navigate the browser to `http://169.254.169.254` (Azure IMDS).
2. Confirm the request is blocked by OpenClaw's SSRF policy before reaching the sidecar.

**Pass criteria:** Navigation to Azure metadata endpoint is denied by SSRF policy.

### TEST-005 — Security audit: 0 CRITICAL

**Steps:**
1. After all changes from this plan and [feature-openclaw-config-hardening-1.md](feature-openclaw-config-hardening-1.md) are applied, run: `openclaw security audit`
2. Confirm **0 critical** findings. Confirm "Browser control has no auth" is absent.

**Pass criteria:** 0 CRITICAL security audit findings.

---

## 7. Risks & Assumptions

- **RISK-001**: ACA internal ingress may only route HTTP/HTTPS traffic and may not pass raw WebSocket upgrade on arbitrary ports. If raw CDP port 9222 (`zenika/alpine-chrome`) is unroutable, switch to `browserless/chromium` (port 3000, HTTP API) which is more reliably compatible with ACA's HTTP-oriented internal ingress model. **Mitigation:** TASK-009 (connectivity test from inside the container) surfaces this immediately.
- **RISK-002**: `min_replicas = 0` causes a cold-start delay (typically 15–40 s) on first browser tool use. Acceptable for a personal assistant; the OpenClaw browser tool has built-in retry/timeout. **Mitigation:** Set `min_replicas = 1` if cold-start latency is unacceptable.
- **RISK-003**: The AVM module FQDN output attribute name may not be `fqdn_url`. **Mitigation:** Run `terraform plan` and inspect the module's output attributes before using the reference in TASK-005/006.
- **RISK-004**: The chosen Chromium image may update its digest between plan authoring and implementation. **Mitigation:** Record the digest in TASK-002 immediately before TASK-003, not in advance.
- **ASSUMPTION-001**: ACA Environment internal networking allows Container Apps to reach each other by FQDN on the configured ingress port without additional network policy configuration. This is the documented ACA default behaviour for apps in the same environment.
- **ASSUMPTION-002**: The `browserless/chromium` or `zenika/alpine-chrome` image supports a non-root user. Confirm UID in TASK-001; if root-only, build a thin wrapper image and push to the shared ACR.

---

## 8. Related Specifications / Further Reading

- [OpenClaw Configuration Reference — browser profiles](https://docs.openclaw.ai/gateway/configuration-reference#browser)
- [feature-openclaw-config-hardening-1.md](feature-openclaw-config-hardening-1.md) — OpenClaw `browser` block config (TASK-005) depends on this plan
- [feature-sandbox-sidecar-1.md](feature-sandbox-sidecar-1.md) — SSH exec sandbox sidecar (parallel initiative)
