---
goal: Deploy SSH sandbox sidecar Container App for OpenClaw exec/file tool isolation
plan_type: standalone
version: 1.0
date_created: 2026-03-31
last_updated: 2026-03-31
owner: Platform Engineering
status: 'Planned'
tags: [feature, infrastructure, terraform, azure-container-apps, sandbox, security, sidecar, ssh]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

OpenClaw's exec and file tools run commands directly on the gateway container unless a sandbox backend is configured. This plan deploys a lightweight SSH server as a stateless internal-only Container App sidecar. OpenClaw connects to it via the `ssh` sandbox backend — exec, file, and shell tool operations are isolated to the sidecar process, not the gateway container. An SSH key pair is generated once, the private key is stored in Azure Key Vault, and secret refs inject it into the OpenClaw container without embedding credentials in config files or Terraform variables.

**Scope limitation:** The SSH backend does not support browser sandboxing. The browser sidecar (a separate Chromium container) is required for browser tool isolation and is covered in [feature-browser-sidecar-1.md](feature-browser-sidecar-1.md).

---

## 1. Requirements & Constraints

- **REQ-001**: Exec, file, and shell tool operations invoked by OpenClaw agents must execute inside the sandbox sidecar, not in the gateway container.
- **REQ-002**: The sandbox sidecar must have **no external ingress**. SSH port 22 must only be reachable within the ACA Environment. No public route to port 22.
- **REQ-003**: The SSH server must use key-based authentication only. Password authentication must be disabled.
- **REQ-004**: The SSH private key must be stored in Azure Key Vault as a secret. It must not appear in source code, Terraform variable files, `openclaw.json.tpl`, or workflow files.
- **REQ-005**: The sidecar must have no access to the OpenClaw state file share (`openclaw-state`). It is isolated compute — agent workspaces are written to temporary paths inside the sidecar container (e.g. `/tmp/openclaw-sandboxes`).
- **REQ-006**: `SANDBOX_SIDECAR_HOST` (sidecar internal FQDN) and `SSH_SANDBOX_KEY` (private key, secret ref) must be injected into the OpenClaw Container App env by Terraform reference — no hard-coded strings.
- **SEC-001**: The SSH server image must be configured with: `PermitRootLogin no`, `PasswordAuthentication no`, `AuthorizedKeysFile` pointed at a location writable at init time (to accept the injected public key), `AllowUsers openclaw` (or equivalent restricted user).
- **SEC-002**: The sandbox sidecar must not have a Managed Identity. No Azure credentials — its only function is to accept SSH connections and execute sandboxed commands.
- **SEC-003**: The SSH known-hosts host key must be captured and added to OpenClaw's `ssh.knownHosts` config (or `strictHostKeyChecking: false` must be explicitly justified and accepted as a known risk trade-off for internal-only connectivity).
- **CON-001**: OpenClaw's Docker sandbox backend is not available in ACA (no Docker daemon). The SSH backend is the only viable sandbox approach.
- **CON-002**: The SSH backend does **not** support browser sandboxing. Browser isolation requires the browser sidecar; see [feature-browser-sidecar-1.md](feature-browser-sidecar-1.md).
- **CON-003**: ACA internal ingress passes HTTP/HTTPS by default. SSH (port 22, raw TCP) may require `transport = "tcp"` or equivalent AVM module configuration. Verify in `terraform plan` output and test end-to-end in TASK-010.
- **CON-004**: Sandbox mode `"non-main"` is the recommended default for personal assistant use: Direct Message sessions run on the gateway container (host env); group/channel/subagent sessions are sandboxed. This trade-off must be documented in the `openclaw.json.tpl` change.
- **CON-005**: All Terraform changes must be validated in dev before applying to prod.
- **GUD-001**: Follow the existing `${local.name_prefix}-*` naming convention from `terraform/locals.tf`. Sandbox sidecar name: `${local.name_prefix}-sandbox`.
- **PAT-001**: Use `Azure/avm-res-app-containerapp/azurerm ~> 0.3` — the same AVM module used for the main OpenClaw Container App and browser sidecar. Do not introduce raw `azurerm_container_app` resource blocks.

---

## 2. Implementation Steps

### Implementation Phase 1 — SSH Key Generation and Key Vault Secret

- GOAL-001: Generate an SSH key pair for the sandbox sidecar, store the private key in Azure Key Vault, and prepare references for Terraform injection.

| Task | Description | Completed | Date |
|---|---|---|---|
| TASK-001 | On the local dev machine, generate an Ed25519 SSH key pair (no passphrase): `ssh-keygen -t ed25519 -C "openclaw-sandbox" -f /tmp/openclaw-sandbox-key -N ""`. This produces `/tmp/openclaw-sandbox-key` (private) and `/tmp/openclaw-sandbox-key.pub` (public). | | |
| TASK-002 | Store the private key in Key Vault (dev): `az keyvault secret set --vault-name <dev-kv-name> --name "openclaw-sandbox-ssh-key" --file /tmp/openclaw-sandbox-key --content-type "text/plain"`. The Key Vault name is retrieved from `terraform output key_vault_name` (dev). Confirm the secret is created. Delete the local private key file after upload: `shred -u /tmp/openclaw-sandbox-key`. | | |
| TASK-003 | Record the public key content from `/tmp/openclaw-sandbox-key.pub`. This value will be injected into the sandbox container at startup as the `authorized_keys` entry for the `openclaw` user. The public key is not a secret and is safe to embed in Terraform as a variable or local. | | |

---

### Implementation Phase 2 — SSH Image Evaluation and Terraform Infrastructure

- GOAL-002: Select and evaluate an SSH server image. Deploy the sandbox sidecar Container App. Inject `SANDBOX_SIDECAR_HOST` and `SSH_SANDBOX_KEY` into the OpenClaw Container App env.

| Task | Description | Completed | Date |
|---|---|---|---|
| TASK-004 | Evaluate SSH server image candidates. Primary candidate: `lscr.io/linuxserver/openssh-server` (configurable via `USER_NAME`, `PUBLIC_KEY` env vars, non-root friendly, maintained). Alternative: a minimal `alpine/sshd` or custom Dockerfile based on `alpine:3` with `openssh-server`. Record chosen image and its digest before proceeding. The image must support injecting the authorized public key via an environment variable or a mounted file (not a command-line argument). | | |
| TASK-005 | Record chosen image details in this plan (update): **Image**: `<image>@<digest>` · **Public key env var name**: `<var>` · **SSH user name**: `<user>`. | | |
| TASK-006 | In `terraform/variables.tf`, add: `variable "sandbox_ssh_public_key" { type = string; description = "Ed25519 public key for OpenClaw SSH sandbox authentication" }`. Add the public key value (from TASK-003) to `scripts/dev.tfvars` under key `sandbox_ssh_public_key`. This is not a secret — public keys are safe in variable files. | | |
| TASK-007 | In `terraform/locals.tf`, add: `sandbox_app_name = "${local.name_prefix}-sandbox"`. | | |
| TASK-008 | In `terraform/keyvault.tf` (or the appropriate Key Vault secret resource file), add a `azurerm_key_vault_secret` data source or resource to reference the `openclaw-sandbox-ssh-key` secret created in TASK-002. Add the `SSH_SANDBOX_KEY` secret ref to the OpenClaw Container App's `secrets` block in `terraform/containerapp.tf`, referencing the Key Vault secret URI. This follows the same pattern as the existing `AZURE_AI_API_KEY` and `OPENCLAW_GATEWAY_TOKEN` secret refs. | | |
| TASK-009 | Create `terraform/sandbox.tf`. Add `module "sandbox_container_app"` using `Azure/avm-res-app-containerapp/azurerm ~> 0.3`. Configuration: `name = local.sandbox_app_name`, same `resource_group_name` and `container_app_environment_resource_id` as the main app, `revision_mode = "Single"`, `enable_telemetry = true`. No `managed_identities`, no Key Vault access from the sidecar itself, no ACR registry (if using a public image). Container: image from TASK-005 (pinned digest), `cpu = 0.5`, `memory = "1Gi"`, `min_replicas = 0`, `max_replicas = 1`. Env vars: `PUBLIC_KEY = var.sandbox_ssh_public_key`, `USER_NAME = "openclaw"`, `SUDO_ACCESS = "false"`, `PASSWORD_ACCESS = "false"`. Ingress: `external_enabled = false`, `target_port = 2222`, `transport = "tcp"`. Note: port 2222 is used by `linuxserver/openssh-server` by default; adjust if using a different image. No volumes, no state share mounts. | | |
| TASK-010 | In `terraform/outputs.tf`, add output `sandbox_container_app_fqdn`: `value = module.sandbox_container_app.fqdn_url` (or the equivalent AVM FQDN attribute — verify after `terraform plan`). Mark `sensitive = false`. | | |
| TASK-011 | In `terraform/containerapp.tf`, add to the OpenClaw container `env` block: `{ name = "SANDBOX_SIDECAR_HOST", value = module.sandbox_container_app.fqdn_url }`. Add to the `secrets` block: `{ name = "SSH_SANDBOX_KEY", key_vault_secret_id = data.azurerm_key_vault_secret.sandbox_ssh_key.id }` (adjust ref to match TASK-008 pattern). Add to the container `env` block a secret-sourced entry: `{ name = "SSH_SANDBOX_KEY", secret_name = "SSH_SANDBOX_KEY" }`. | | |

---

### Implementation Phase 3 — OpenClaw Config (`openclaw.json.tpl`)

- GOAL-003: Add sandbox backend config to `openclaw.json.tpl`. This config references `${SANDBOX_SIDECAR_HOST}` and `${SSH_SANDBOX_KEY}` env vars injected by Terraform in Phase 2.

| Task | Description | Completed | Date |
|---|---|---|---|
| TASK-012 | In `config/openclaw.json.tpl`, add a `sandbox` block under `agents.defaults`. Add immediately after the existing `memorySearch` block (or after `model` if `memorySearch` is not yet merged from the hardening plan): `"sandbox": { "mode": "non-main", "backend": "ssh", "scope": "session", "workspaceAccess": "rw", "ssh": { "target": "${SANDBOX_SIDECAR_HOST}:2222", "workspaceRoot": "/tmp/openclaw-sandboxes", "strictHostKeyChecking": false, "identityData": { "source": "env", "provider": "default", "id": "SSH_SANDBOX_KEY" } } }`. The `strictHostKeyChecking: false` trade-off is documented in RISK-003 below — acceptable for an internal-only private-network sidecar. | | |
| TASK-013 | Add a JSON comment key near the sandbox block to document the mode trade-off: `"_note_sandbox_mode": "non-main: DM sessions run on gateway host; group/channel/subagent sessions are sandboxed. Upgrade to 'all' only after confirming gateway tools still function when sandboxed."` | | |

---

### Implementation Phase 4 — Terraform Apply (Dev) and SSH Connectivity Test

- GOAL-004: Apply Terraform to dev. Verify SSH connectivity from the OpenClaw container to the sandbox sidecar.

| Task | Description | Completed | Date |
|---|---|---|---|
| TASK-014 | Run `terraform plan -var-file=../scripts/dev.tfvars` from `terraform/`. Confirm plan shows: new `sandbox_container_app`, `SSH_SANDBOX_KEY` secret addition, `SANDBOX_SIDECAR_HOST` env var addition to OpenClaw Container App, no unexpected changes to ingress, KV, identity, or storage resources. | | |
| TASK-015 | Run `terraform apply -var-file=../scripts/dev.tfvars` against dev. Confirm sandbox Container App is provisioned and running. Record the internal FQDN from `terraform output sandbox_container_app_fqdn`. | | |
| TASK-016 | From within the OpenClaw container, verify SSH port reachability: `nc -zv ${SANDBOX_SIDECAR_HOST} 2222`. If `nc` is unavailable: `timeout 5 bash -c "echo > /dev/tcp/${SANDBOX_SIDECAR_HOST}/2222" && echo open`. Confirm connection succeeds. If timeout/refused, revisit `transport = "tcp"` AVM config (CON-003). | | |
| TASK-017 | Hot-reload the OpenClaw config by touching `~/.openclaw/openclaw.json` or restarting the gateway. Run `openclaw doctor` and confirm: no sandbox-related warnings; `ssh` backend is active; memory search is still functional. | | |

---

## 3. Alternatives

- **ALT-001**: Use OpenClaw's Docker sandbox backend. Rejected: requires Docker daemon access from within the Container App process. ACA does not expose a Docker socket; Docker-in-Docker requires privileged mode which ACA does not support.
- **ALT-002**: Use `sandbox.mode = "all"` to sandbox every session including DMs. Viable in principle, but risks breaking gateway-level tools (cron, integrations) that expect to run in the host environment. Mode `"non-main"` is safer as a first deployment and can be upgraded later.
- **ALT-003**: Build a custom SSH server image from `alpine:3` with `openssh-server`. More control over sshd config; slightly more maintenance burden. Use if `linuxserver/openssh-server` proves incompatible with ACA internal TCP ingress.
- **ALT-004**: Use `strictHostKeyChecking: true` with a pre-computed `knownHosts` entry. More secure (MITM-resistant even on the internal ACA network). Requires capturing the host key fingerprint after first container start and embedding it in config. Upgrade from ALT approach in TASK-012 after initial deployment confirms the sidecar is stable.
- **ALT-005**: Inject the Key Vault secret as a volume mount (ACA managed secret store) rather than an env var. Viable but more complex; the env var approach matches the existing pattern for `AZURE_AI_API_KEY` and `OPENCLAW_GATEWAY_TOKEN`.

---

## 4. Dependencies

- **DEP-001**: ACA Environment (`module.container_apps_environment`) must already exist.
- **DEP-002**: Key Vault (dev) must already exist and the deploying identity must have `Key Vault Secrets Officer` role. Confirmed by existing use of KV for `AZURE_AI_API_KEY` and `OPENCLAW_GATEWAY_TOKEN`.
- **DEP-003**: OpenClaw SSH backend must be available in the installed version. Verify `openclaw --version` and check the sandbox backends page in OpenClaw docs.
- **DEP-004**: Terraform dev workspace must be initialized: `terraform init -backend-config=backend.dev.hcl`.
- **DEP-005**: [feature-openclaw-config-hardening-1.md](feature-openclaw-config-hardening-1.md) TASK-001 (`memorySearch` block) should be applied before or alongside Phase 3 of this plan to avoid merge conflicts in `openclaw.json.tpl`.

---

## 5. Files

- **FILE-001**: `terraform/sandbox.tf` (new) — sandbox sidecar Container App module block (TASK-009).
- **FILE-002**: `terraform/locals.tf` — add `sandbox_app_name` local (TASK-007).
- **FILE-003**: `terraform/variables.tf` — add `sandbox_ssh_public_key` variable (TASK-006).
- **FILE-004**: `terraform/outputs.tf` — add `sandbox_container_app_fqdn` output (TASK-010).
- **FILE-005**: `terraform/containerapp.tf` — add `SSH_SANDBOX_KEY` secret ref and `SANDBOX_SIDECAR_HOST` env var (TASK-011).
- **FILE-006**: `terraform/keyvault.tf` (or equivalent) — add data source reference for `openclaw-sandbox-ssh-key` (TASK-008).
- **FILE-007**: `config/openclaw.json.tpl` — add `agents.defaults.sandbox` block (TASK-012, TASK-013).
- **FILE-008**: `scripts/dev.tfvars` — add `sandbox_ssh_public_key` (TASK-006).

---

## 6. Testing

All tests must be executed against the **dev environment** only.

### TEST-001 — Sandbox sidecar is internal-only (no external route)

**Steps:**
1. From outside Azure (local machine), attempt TCP connection to the sandbox sidecar FQDN on port 2222.
2. Confirm connection is refused or times out.

**Pass criteria:** Port 2222 unreachable from outside the ACA environment.

### TEST-002 — SSH port reachable from OpenClaw container

**Steps:**
1. From inside the OpenClaw container: `nc -zv ${SANDBOX_SIDECAR_HOST} 2222`
2. Confirm "succeeded" (or equivalent success output).

**Pass criteria:** TCP connection to port 2222 established within 30 s (allowing for cold-start).

### TEST-003 — Exec tool runs inside sidecar

**Steps:**
1. Ask the agent to run `hostname` using the exec tool.
2. Confirm the returned hostname is the **sandbox container's** hostname, not the OpenClaw container's hostname. (Container hostnames in ACA are derived from the container app name — the sandbox container's hostname will include `sandbox` while the gateway's will include `app`.)

**Pass criteria:** `hostname` output matches the sandbox container app name prefix.

### TEST-004 — File write isolation

**Steps:**
1. Ask the agent to write a test file using the file tool: write `"sandbox test"` to `/tmp/isolation-test.txt`.
2. Exec into the OpenClaw gateway container and confirm `/tmp/isolation-test.txt` does NOT exist.
3. Exec into the sandbox container and confirm `/tmp/isolation-test.txt` does exist.

**Pass criteria:** File created in sandbox is not visible in gateway container.

### TEST-005 — Gateway is not accessible from sandbox (lateral movement check)

**Steps:**
1. From inside the sandbox container shell (via exec), attempt to connect to the OpenClaw gateway port: `nc -zv <openclaw-app-fqdn> 18789`
2. This should succeed (ACA internal routing allows it) — but confirm that presenting no token returns 401, not that the port is entirely blocked. The goal is that the sandbox is not an escalation path to OpenClaw's internal network.
3. Document: sandbox sidecar has no Managed Identity → cannot access Key Vault, ACR, or Azure resources.

**Pass criteria:** Gateway reachable but auth-protected; sandbox has no Azure credentials.

### TEST-006 — `openclaw doctor`: 0 sandbox-related warnings

**Steps:**
1. After all changes applied, run `openclaw doctor`.
2. Confirm no sandbox backend warnings. Check that memory search (Issue #1), compile cache (Issue #2), and browser (Issue #3) findings are also clear.

**Pass criteria:** 0 critical/warning findings related to sandbox.

---

## 7. Risks & Assumptions

- **RISK-001**: ACA internal TCP ingress on non-HTTP port 2222 may require specific AVM module configuration (`transport = "tcp"`). The AVM module's ingress settings may not expose this directly. **Mitigation:** Check the AVM module changelog and `terraform plan` output. If TCP transport is not supported, build a thin wrapper image that wraps SSH in an HTTP tunnel (e.g. using `sshproxy` over WebSocket), or use the OpenClaw `remote-exec` HTTP-based backend as an alternative.
- **RISK-002**: `min_replicas = 0` causes cold-start delay (15–40 s) on first sandbox use. For a personal assistant this is acceptable. **Mitigation:** Set `min_replicas = 1` if latency is unacceptable.
- **RISK-003**: `strictHostKeyChecking: false` leaves the SSH connection vulnerable to MITM within the ACA private network. This is a known accepted trade-off: the threat model for an internal-only private ACA network is low. **Mitigation:** Upgrade to `strictHostKeyChecking: true` with a pre-computed `knownHosts` fingerprint after initial deployment confirms stability (ALT-004).
- **RISK-004**: The SSH private key is stored in Key Vault and injected as an env var. Env vars are visible to processes running in the container. **Mitigation:** The private key grants access to the sandbox sidecar only — which itself has no Azure credentials. Exposure of the key does not grant access to Azure resources.
- **RISK-005**: OpenClaw config changes to `openclaw.json.tpl` (TASK-012/013) will conflict if applied at the same time as unmerged changes from [feature-openclaw-config-hardening-1.md](feature-openclaw-config-hardening-1.md). **Mitigation:** Apply hardening plan changes first, or coordinate the JSON merge manually.
- **ASSUMPTION-001**: ACA intra-environment networking allows Container Apps to reach each other by TCP on internal ingress ports without additional NSG or subnet policy. This is the documented ACA default.
- **ASSUMPTION-002**: The installed version of OpenClaw supports the `ssh` sandbox backend with `identityData.source = "env"`. Verify against `openclaw --version` and release notes before TASK-009.
- **ASSUMPTION-003**: `linuxserver/openssh-server` accepts the `PUBLIC_KEY` env var to populate `authorized_keys` for the configured `USER_NAME`. Confirm in TASK-004 before pinning the image.

---

## 8. Related Specifications / Further Reading

- [OpenClaw Configuration Reference — sandbox backends](https://docs.openclaw.ai/gateway/configuration-reference#sandbox)
- [OpenClaw Sandboxing documentation](https://docs.openclaw.ai/gateway/sandboxing)
- [feature-openclaw-config-hardening-1.md](feature-openclaw-config-hardening-1.md) — Issues #1/#2/#3 config hardening (memorySearch, startup, browser config — must be applied alongside or before this plan's Phase 3)
- [feature-browser-sidecar-1.md](feature-browser-sidecar-1.md) — Chromium browser sidecar (required for browser tool isolation; independent of this plan)
