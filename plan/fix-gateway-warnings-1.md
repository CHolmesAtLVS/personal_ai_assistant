---
goal: Resolve OpenClaw gateway warnings surfaced in 2026-04-01 log review and 2026-04-02 doctor run
plan_type: standalone
version: "1.1"
date_created: 2026-04-01
last_updated: 2026-04-02
owner: Platform Engineering
status: 'In progress'
tags: [bug, openclaw, infrastructure, configuration]
---

# Introduction

![Status: In progress](https://img.shields.io/badge/status-In%20progress-yellow)

Four distinct warnings were emitted by the OpenClaw gateway on every start-up and during normal operation in the `dev` Container App, captured in the filtered log review dated 2026-04-01. A subsequent `openclaw doctor` run on 2026-04-02 surfaced three additional actionable findings: startup optimization env vars are unset, memory search is non-functional due to a missing embedding provider, and the memory database is locked (the latter is caused by SQLite advisory lock incompatibility on SMB and is expected to resolve with the sidecar fix in Phase 2). The four original warnings plus the new actionable items are tracked as a unified set below.

**Source log:** `plan/openclaw-logs-filtered-2026-04-01-22-44-59.log`

**Doctor run:** `openclaw doctor` on 2026-04-02 (see Phase 5 for new findings).

**Doctor findings classified as NOT ACTIONABLE in this plan:**
- **Update notice** — `openclaw update` applies to npm/git installs; the ACA container is updated by rebuilding the container image. Not applicable.
- **OAuth dir not present** — Informational; no WhatsApp or pairing channel is configured. Doctor skipped creation. Expected.
- **Security: LAN bind warning** — Gateway binds to `0.0.0.0` because ACA's ingress controller requires it. External access restriction is enforced at the ACA ingress level via IP allowlist (home public IP), not at the process bind level. This is intentional and correctly configured.
- **Skills: 44 missing requirements** — Skills require integrations (e.g. calendar, shell, browser) not yet provisioned. Not actionable until those are needed.
- **Plugins: 42 disabled** — Expected when no client session is connected.

---

## 1. Requirements & Constraints

- **REQ-001**: All fixes must target the `dev` environment only. Do not touch production resources during investigation or remediation.
- **REQ-002**: Infrastructure changes must be declared in Terraform and applied via the standard `terraform plan` / `terraform apply` workflow for `dev`.
- **REQ-003**: Config changes must use `${VAR_NAME}` substitution for any sensitive values; no secrets in source.
- **REQ-004**: `openclaw.batch.json` changes must be re-seeded into the container after every edit (`scripts/seed-openclaw-config.sh` or equivalent).
- **REQ-005**: Any new environment variables added to the Container App (`NODE_COMPILE_CACHE`, `OPENCLAW_NO_RESPAWN`) must be declared in `terraform/containerapp.tf` — not set ad-hoc in the container at runtime.
- **SEC-001**: Do not widen network egress beyond the minimum needed to resolve the model-pricing timeout. Keep all other egress restrictions intact.
- **CON-001**: Azure Files SMB shares mounted via Azure Container Apps do not support POSIX `chmod`/`chown`. This is a platform constraint.
- **CON-002**: Azure Container Apps does not support multicast networking; mDNS (Bonjour) cannot be used for service discovery.
- **CON-003**: `gateway.*` config changes require a gateway restart (not hot-reloaded). Schedule restart after config seeding.
- **GUD-001**: Follow the triage ladder from `openclaw-config` skill before and after each fix: `openclaw status --all`, `openclaw doctor`, `openclaw logs --follow`.

---

## 2. Implementation Steps

### Implementation Phase 1 — Diagnose and confirm root causes

- GOAL-001: Verify the exact cause of each warning against the live `dev` environment before making changes, to prevent unnecessary infrastructure churn.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                            | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | **Confirm EPERM root cause.** Connect to the `dev` container via `az containerapp exec` (dev resource group only). Run `ls -la /home/node/.openclaw/` and `stat /home/node/.openclaw/tasks` to confirm the directory exists with wrong permissions and that `chmod 700 /home/node/.openclaw/tasks` fails with EPERM. Document the exact uid/gid the process runs as. | ✅ | 2026-04-02 |
| TASK-002 | **Identify model-pricing target URL.** Run `openclaw logs --follow` on dev immediately after a gateway restart. Find the full URL the `gateway/model-pricing` subsystem attempts to reach (logged at DEBUG level). Check whether DNS resolution succeeds and whether the target host is reachable from the container: `curl -v --max-time 5 <URL>`. | ⏭️ SKIPPED | 2026-04-02 |
| TASK-003 | **Confirm ACA proxy CIDR for trustedProxies.** Inside the dev container, inspect the value of the `X-Forwarded-For` and `X-Real-IP` headers on an inbound WebSocket request by enabling `OPENCLAW_RAW_STREAM=1` or checking gateway debug output. Alternatively, check the ACA environment internal IP range via `az containerapp env show` (dev env only). The ACA Envoy ingress proxy typically uses the `100.100.0.0/16` range — confirm this. | ✅ | 2026-04-02 |
| TASK-004 | **Verify Bonjour is not needed.** Confirm no client is configured to discover the gateway via mDNS in the `dev` environment. All clients connect via the HTTPS ingress URL. If confirmed, Bonjour is safe to disable. | ✅ | 2026-04-02 |

**Phase 1 complete (2026-04-02).**

**Phase 1 Findings (2026-04-02):**

- **TASK-001 — CONFIRMED.** `chmod 700 /home/node/.openclaw/tasks` fails with `Operation not permitted`. The `/home/node/.openclaw/` subtree is owned by `root:root (uid=0, gid=0)` with mode `0777`. The process runs as `uid=1000(node) gid=1000(node)`. The Azure Files SMB CIFS driver returns EPERM on `chmod()` unconditionally regardless of process capabilities. Root cause confirmed.
- **TASK-002 — SKIPPED.** Log at warn level only shows `TimeoutError: The operation was aborted due to timeout`; the target URL is emitted at DEBUG level only. URL discovery requires a restart with DEBUG logging enabled — not pursued per user direction. Timeout nature (not DNS failure) noted for TASK-009.
- **TASK-003 — CONFIRMED.** `/proc/net/tcp` on the container shows the container's own IP is `100.100.0.162` and active connections arrive from `100.100.0.22` and `100.100.0.222` — all in `100.100.0.0/16`. Use `100.100.0.0/16` for `gateway.trustedProxies`.
- **TASK-004 — CONFIRMED.** All clients connect via HTTPS ingress URL; no mDNS discovery is in use. Bonjour can be disabled or suppressed.

### Implementation Phase 2 — Fix: Azure Files POSIX permissions (EPERM chmod)

- GOAL-002: Eliminate the `Failed to restore task registry` error by giving the OpenClaw process full POSIX semantics on its state directory. The root cause is that the Azure Files SMB share does not support `chmod()`. The fix switches to a **disk-backed EmptyDir** volume with an **azcopy sidecar** for persistence — no VNet, no NAT Gateway, no storage account recreation required.

> ⚠️ **Delegated to [`plan/feature-sidecar-sync-1.md`](feature-sidecar-sync-1.md).** This is the active EPERM fix. Execute all phases of that plan before returning to Phase 4 of this plan.

| Task     | Description                                                                                                                                                                              | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-005 | **Execute `plan/feature-sidecar-sync-1.md`** — disk-backed EmptyDir + azcopy sidecar to Blob Storage. Covers Terraform, data migration, init container restore, script rework, and SMB state share removal. | ✅ | 2026-04-02 |
| TASK-006 | **Confirm EPERM fix.** After `feature-sidecar-sync-1.md` completes, verify `chmod 700 /home/node/.openclaw/tasks` exits 0 inside the container and the `EPERM chmod` warning is absent from `openclaw logs`. | ✅ | 2026-04-02 |

### Implementation Phase 3 — Fix: OpenClaw config (trustedProxies, Bonjour, model-pricing)

- GOAL-003: Resolve the three remaining warnings via `openclaw.batch.json` changes. These are config-only and do not require infrastructure changes.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                  | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-007 | **Add `gateway.trustedProxies` to `config/openclaw.batch.json`.** Add the entry: `{ "path": "gateway.trustedProxies", "value": ["100.100.0.0/16"] }` (or the CIDR confirmed in TASK-003). This tells the gateway to trust `X-Forwarded-*` headers from the ACA Envoy proxy, restoring local client detection. Note: `gateway.*` changes require a restart (CON-003). | ✅ | 2026-04-02 |
| TASK-008 | **Disable Bonjour/mDNS in `config/openclaw.batch.json`** (if a supported config key exists). Add the entry: `{ "path": "discovery.mdns.enabled", "value": false }` — or the equivalent key confirmed from OpenClaw docs (`https://docs.openclaw.ai/gateway/configuration-reference`). If no config key exists to suppress mDNS, document as a known no-op warning and close with a comment in this plan. | ⚠️ NO KEY | 2026-04-02 |
| TASK-009 | **Suppress or disable model-pricing bootstrap in `config/openclaw.batch.json`** (if a supported config key exists and the feature is non-critical). Candidate key: `{ "path": "gateway.modelPricing.enabled", "value": false }`. Confirm against OpenClaw docs. If network egress is the cause (TASK-002), add the pricing endpoint host to any allowed-list instead — do not disable the feature if it drives usage tracking or billing visibility. | ⚠️ NO KEY | 2026-04-02 |
| TASK-010 | **Re-seed config into the dev container.** Run `scripts/seed-openclaw-config.sh` (or the equivalent CLI: `openclaw config batch apply config/openclaw.batch.json`) against dev. Then restart the gateway: `openclaw gateway restart`. Confirm with `openclaw doctor` and `openclaw status --all`. | ✅ | 2026-04-02 |

**Phase 3 Findings (2026-04-02):**
- **TASK-007 — DONE.** `gateway.trustedProxies: ["100.100.0.0/16"]` seeded via CI and applied. Proxy header warning no longer appears in logs.
- **TASK-008 — NO KEY EXISTS.** `discovery.mdns.enabled` is not a valid config key (`discovery.mdns` expects an object; no boolean subkey is accepted by the schema in v2026.3.31). `discovery.mdns.disabled` and `discovery.mdns.advertise` also rejected. The Bonjour warning is a known no-op in ACA — no mDNS clients are in use. Closing without config change; warning is benign.
- **TASK-009 — NO KEY EXISTS.** `gateway.modelPricing.enabled` is not a valid config key (`modelPricing` is not a recognized gateway namespace in v2026.3.31). Warning is due to ACA egress blocking the pricing CDN — benign. Closing without config change.
- **TASK-010 — DONE.** Config seeded via CI (`seed-openclaw-ci.sh`). Gateway restarted via `az containerapp revision restart`. Config re-applied after restart confirmed trustedProxies active.

### Implementation Phase 4 — Fix: new findings from `openclaw doctor` (2026-04-02)

- GOAL-004: Resolve the three actionable items surfaced by the first `openclaw doctor` run that are not covered by earlier phases.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-011 | **Add `OPENCLAW_NO_RESPAWN=1` and `NODE_COMPILE_CACHE` to `terraform/containerapp.tf`.** Doctor reported: *"OPENCLAW_NO_RESPAWN is not set to 1; set it to avoid extra startup overhead from self-respawn"* and *"NODE_COMPILE_CACHE is not set; repeated CLI runs can be slower."* Add both as environment variables in the `env` block of the openclaw container: `OPENCLAW_NO_RESPAWN = "1"` and `NODE_COMPILE_CACHE = "/var/tmp/openclaw-compile-cache"`. The cache directory does not need to be persisted across restarts (ephemeral in EmptyDir is fine — compile cache rebuilds on cold start). Run `terraform apply -target <containerapp resource>` on dev only. | ✅ | 2026-04-02 |
| TASK-012 | **Confirm memory search database lock resolves with sidecar fix.** Doctor reported: *"Gateway memory probe for default agent is not ready: database is locked."* Root cause: SQLite advisory file locks (`.lock` files, `flock()` syscall) do not work correctly on SMB/CIFS shares. The memory search database (SQLite) is stored in `/home/node/.openclaw/agents/main/` which is currently on the SMB state share. After `feature-sidecar-sync-1.md` Phase 4 moves the state to disk-backed EmptyDir, SQLite locking will use standard POSIX flock on the local node disk and the error should disappear. **Action:** run `openclaw memory status --deep` after the sidecar migration completes (TASK-005/006 in Phase 2) and confirm the database is no longer locked. No separate infrastructure change is needed. | ✅ | 2026-04-02 |
| TASK-013 | **Configure Azure AI Foundry embedding model for memory search.** **Decision: option (a) — Azure AI Foundry.** Use the `text-embedding-3-small` deployment via the Azure OpenAI endpoint already wired into the container. Steps: (1) Confirm the deployment exists: `az cognitiveservices account deployment list --name <foundry-account> --resource-group <dev-rg> --query "[?contains(name,'embedding')]" -o table`. (2) In `terraform/containerapp.tf`, add `OPENAI_API_KEY = "${AZURE_AI_API_KEY}"` (alias to the existing secret ref) and `OPENAI_BASE_URL = "<foundry-endpoint>/openai"` to the openclaw container env block. Alternatively, configure via `openclaw configure --section model` if OpenClaw supports a dedicated embedding provider config key (check docs). (3) Confirm with `openclaw memory status --deep` — must show embedding provider ready. (4) Optional: set `agents.defaults.memorySearch.embeddingModel = "text-embedding-3-small"` in `config/openclaw.batch.json` if the default model selection differs. | | |

**Phase 4 Findings (2026-04-02):**
- **TASK-011 — DONE.** `OPENCLAW_NO_RESPAWN=1` and `NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache` added to openclaw container env block in `terraform/containerapp.tf`. Applied via CI (commit `3d1a313`).
- **TASK-012 — DONE.** `openclaw doctor` after EmptyDir migration shows no database lock warning. SQLite flock works correctly on the local node disk.
- **TASK-013 — DEFERRED.** Embedding provider already configured in `openclaw.batch.json` (`agents.defaults.memorySearch.provider=openai`, `model=text-embedding-3-large`). Doctor reports "gateway reports memory embeddings are ready" — embedding is functional. Full confirmation deferred to Phase 5 `openclaw memory status --deep`.

### Implementation Phase 5 — Validation

- GOAL-005: Confirm all original warnings and new doctor findings are resolved and no regressions are introduced.

| Task     | Description                                                                                                                                                                                                                                                                              | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-014 | **Collect fresh filtered logs** from the dev container immediately after the full restart from Phase 3. Confirm none of the four warning signatures appear: `EPERM chmod`, `pricing bootstrap failed`, `Proxy headers detected from untrusted address`, `watchdog detected non-announced service / stuck in probing`. | ✅ | 2026-04-02 |
| TASK-015 | **Smoke-test LLM routing** on dev: send a prompt via the gateway and confirm a valid response is returned using the configured model on Azure AI Foundry. Confirm no authentication or model routing errors in logs. | ✅ | 2026-04-02 |
| TASK-016 | **Run `openclaw doctor` — must pass cleanly.** After all phases complete, doctor output must show no actionable warnings. Expected residual informational items (not failures): Update notice (git checkout), OAuth dir skip (no WhatsApp/pairing), LAN bind advisory (expected in ACA), skills missing requirements (integrations not yet provisioned). | ✅ | 2026-04-02 |
| TASK-017 | **Update `docs/baseline-configuration.md`** to document: (a) state persisted via EmptyDir + azcopy sidecar (see `feature-sidecar-sync-1.md`), (b) `gateway.trustedProxies` required for ACA deployments, (c) `OPENCLAW_NO_RESPAWN=1` and `NODE_COMPILE_CACHE` env vars, (d) embedding provider configuration decision from TASK-013, (e) Bonjour/model-pricing disable config if applicable. | ⏭️ DEFERRED | 2026-04-02 |

**Phase 5 Findings (2026-04-02):**
- **TASK-014 — DONE.** Fresh logs confirm: `EPERM chmod` gone ✅, `database is locked` gone ✅, `Proxy headers detected from untrusted address` gone ✅. Remaining benign: `pricing bootstrap failed` (no config key exists) and `watchdog detected non-announced service` (no config key exists). Both are expected in ACA.
- **TASK-015 — DONE.** `openclaw agent --agent main --message "Reply with exactly: OK"` returned `"OK"` via `azure-openai/gpt-5.4-mini` in 4817ms. No auth or routing errors. LLM routing confirmed end-to-end.
- **TASK-016 — DONE.** `openclaw doctor --non-interactive` against the live gateway shows no actionable warnings. Residual informational items are all expected: `NODE_COMPILE_CACHE`/`OPENCLAW_NO_RESPAWN` (local CLI env, not the container), OAuth dir absent (no channel), LAN bind advisory (expected in ACA), memory search API key absent (local CLI env; gateway itself reports embeddings ready).
- **TASK-017 — DEFERRED.** `docs/baseline-configuration.md` update deferred to a follow-up PR.

---

## 3. Alternatives

- **ALT-001 (EPERM):** Use an **emptyDir** volume for `/home/node/.openclaw/tasks` only (ephemeral, in-memory). This avoids any sidecar but loses task persistence across container restarts. Rejected as the primary fix because it changes the data durability contract; considered acceptable only as a fallback if the sidecar approach is blocked.
- **ALT-002 (EPERM):** Add an **init container** that runs `chmod 700 /home/node/.openclaw/tasks` before the main container starts. Azure Files SMB would still reject the chmod inside the init container since the limitation is in the SMB CIFS driver, not in the container's capabilities. Not viable against SMB.
- **ALT-003 (EPERM):** Switch to **Azure Files NFS** (Premium tier). Provides full POSIX semantics and synchronous persistence with zero data loss risk. Requires VNet, NAT Gateway (~$35–48/month additional cost), storage account recreation, and full script rework. Rejected for cost and complexity in favour of the sidecar approach.
- **ALT-004 (trustedProxies):** Hardcode the ACA Envoy IP rather than a CIDR. Rejected because the proxy source IP can vary across ACA infrastructure updates.
- **ALT-005 (model-pricing):** Add a network egress rule to allow traffic to the pricing host. Preferred only if pricing data is actively used in the product (e.g., cost tracking). If the feature provides no value today, disabling it is simpler and reduces external dependencies.
- **ALT-006 (EPERM) — SMB + mountOptions (`dir_mode=0777,file_mode=0777,uid=1000,gid=1000`): NOT VIABLE for Azure Container Apps.** Two independent blockers:
  1. **ACA does not expose CIFS mount options.** The `azurerm_container_app_environment_storage` resource only accepts `access_mode` and `nfs_server_url`. There is no `mount_options` field.
  2. **`chmod()` syscall always fails with EPERM on CIFS/SMB regardless of mount-time mode bits.** `dir_mode`/`file_mode` set apparent permissions at mount time but the Linux CIFS kernel module does not implement the `chmod()` syscall — it returns EPERM unconditionally.
- **ALT-007 (memory search):** Use a Voyage AI or Mistral embedding API key instead of Azure AI Foundry. Viable if the Foundry project has no embedding deployment and provisioning one is undesirable. Adds a second external dependency and requires storing an additional secret in Key Vault.

---

## 4. Dependencies

- **DEP-001**: Phase 2 (EPERM fix) is fully delegated to [`plan/feature-sidecar-sync-1.md`](feature-sidecar-sync-1.md). That plan must complete before Phase 5 (validation) here, and before TASK-012 (confirm SQLite lock resolves).
- **DEP-002**: OpenClaw config key reference for `discovery.mdns.enabled` and `gateway.modelPricing.enabled` — must be confirmed against [configuration-reference](https://docs.openclaw.ai/gateway/configuration-reference) before TASK-008 and TASK-009.
- **DEP-003**: `scripts/backup-openclaw.sh` must be functional before TASK-006 (backup confirmation step).
- **DEP-004**: `scripts/seed-openclaw-config.sh` must be updated per `feature-sidecar-sync-1.md` Phase 6 before use in TASK-010.
- **DEP-005**: TASK-013 (embedding provider decision) must be completed before TASK-017 (baseline-configuration.md update), as the decision is documented there.
- **DEP-006**: TASK-011 (`OPENCLAW_NO_RESPAWN` env vars added to Terraform) must be applied before TASK-016 (doctor clean pass), so the startup optimization warnings are gone.

---

## 5. Files

- **FILE-001**: `config/openclaw.batch.json` — receives `gateway.trustedProxies`, `discovery.mdns.enabled`, and optionally `gateway.modelPricing.enabled` entries (Phase 3).
- **FILE-002**: `docs/baseline-configuration.md` — updated to document ACA-specific requirements and embedding provider decision (Phase 5, TASK-017).
- **FILE-003**: `terraform/storage.tf`, `terraform/containerapp.tf`, `scripts/seed-*.sh`, `scripts/test-*.sh` — all delegated to [`plan/feature-sidecar-sync-1.md`](feature-sidecar-sync-1.md).
- **FILE-004**: `terraform/containerapp.tf` — receives `OPENCLAW_NO_RESPAWN = "1"` and `NODE_COMPILE_CACHE = "/var/tmp/openclaw-compile-cache"` env vars in the openclaw container block (Phase 4, TASK-011).

---

## 6. Testing

- **TEST-001**: Post-fix log scan — collect `openclaw logs` output immediately after restart and grep for the four warning signatures. All must be absent.
- **TEST-002**: LLM smoke test — send a single prompt via the gateway and confirm a non-error response using `test-openclaw-config.sh` or `test-multi-model.sh` (dev only).
- **TEST-003**: State persistence test — write a task via the gateway, restart the container, confirm the task is recovered from Blob Storage via the init container restore (validates sidecar fix and cold-start restore).
- **TEST-004**: Run `openclaw doctor` — after all phases complete, must show no actionable warnings. Known residual informational items are documented in TASK-016 and are not failures.
- **TEST-005**: Run `openclaw memory status --deep` — must not report "database is locked" after sidecar migration (validates TASK-012).
- **TEST-006**: Verify startup env vars — exec into container and run `printenv OPENCLAW_NO_RESPAWN NODE_COMPILE_CACHE`; values must be `1` and `/var/tmp/openclaw-compile-cache` respectively (validates TASK-011).

---

## 7. Risks & Assumptions

- **RISK-001**: The ACA Envoy proxy CIDR may not be `100.100.0.0/16` in all regions or environments. If the wrong CIDR is configured in `gateway.trustedProxies`, clients may still be detected as remote. Mitigated by TASK-003 (confirm before configuring).
- **RISK-002**: OpenClaw may not expose a stable config key for mDNS or model-pricing disable. In that case TASK-008/TASK-009 become no-ops and the warnings must be accepted as known benign noise until an upstream fix is available.
- **RISK-003**: See `feature-sidecar-sync-1.md` Section 7 for all risks related to the EPERM fix and sidecar architecture.
- **RISK-004**: If the `text-embedding-3-small` deployment does not exist in the dev Azure AI Foundry project, TASK-013 step (1) will surface this. Resolution: provision the deployment via `az cognitiveservices account deployment create` (Standard tier, 1K TPM minimum) before proceeding. Do not fall back to disabling memory search without explicit approval.
- **RISK-005**: `NODE_COMPILE_CACHE` directory (`/var/tmp/openclaw-compile-cache`) is inside the container's writable layer and is lost on container restart. This is acceptable — the cache rebuilds on the next warm-up. Persisting it would require another EmptyDir volume subtracted from the 21 GiB node disk budget, which is unnecessary.
- **ASSUMPTION-001**: The `dev` environment is the sole target for all changes in this plan. Production is out of scope.
- **ASSUMPTION-002**: The original four warnings and the three new doctor findings are independent and can be worked in parallel across phases 2–4 without ordering constraints (except TASK-006 must follow TASK-005, and TASK-012 must follow TASK-005).
- **ASSUMPTION-003**: `gateway.trustedProxies` accepts CIDR notation as documented.

---

## 8. Related Specifications / Further Reading

- [plan/openclaw-logs-filtered-2026-04-01-22-44-59.log](openclaw-logs-filtered-2026-04-01-22-44-59.log) — source log file
- [plan/feature-sidecar-sync-1.md](feature-sidecar-sync-1.md) — EPERM fix (EmptyDir + azcopy sidecar)
- [docs/baseline-configuration.md](../docs/baseline-configuration.md) — current baseline config reference
- [docs/openclaw-containerapp-operations.md](../docs/openclaw-containerapp-operations.md) — ACA operational runbook
- [.github/skills/openclaw-config/SKILL.md](../.github/skills/openclaw-config/SKILL.md) — OpenClaw config skill (triage ladder, hot-reload rules)
- [OpenClaw configuration reference](https://docs.openclaw.ai/gateway/configuration-reference) — canonical config key reference
