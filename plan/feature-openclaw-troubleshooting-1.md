---
goal: Improve OpenClaw Container App troubleshooting tooling and documentation
plan_type: standalone
version: 1.0
date_created: 2026-03-30
last_updated: 2026-03-30
owner: Platform Engineering
status: 'Complete'
tags: [feature, operations, troubleshooting, tooling, scripts, runbook]
---

# Introduction

![Status: Complete](https://img.shields.io/badge/status-Complete-brightgreen)

During the prod incident of 2026-03-30, diagnosing the OpenClaw Container App startup failure required assembling a wide set of ad-hoc Azure CLI commands, MCP tool calls, and Docker inspection steps. Several gaps slowed diagnosis: the Log Analytics workspace was blocked by a Network Security Perimeter (NSP) preventing direct query from outside Azure; the `dump-resource-inventory.sh` script had two bugs that prevented it running; no single command surfaced the container's stdout quickly; and the real-time system event stream (Container App controller events) was not documented or scripted.

This plan adds a `diagnose-containerapp.sh` script, documents the full troubleshooting toolkit, and patches the ops runbook with a structured diagnostic procedure — so that future incidents can be triaged in minutes rather than hours.

## 1. Requirements & Constraints

- **REQ-001**: Provide a single runnable script (`scripts/diagnose-containerapp.sh`) that any operator can run after `az login` to capture a full diagnostic snapshot of the Container App's health state.
- **REQ-002**: The diagnostic script must not require Terraform state or `.tfvars` files; it must derive all resource names from required positional arguments (`env`, e.g. `dev` or `prod`).
- **REQ-003**: All diagnostic output must be written to a time-stamped file in `scripts/` that is git-ignored, never committed.
- **REQ-004**: Document the full troubleshooting toolkit used during the incident in `docs/openclaw-containerapp-operations.md` as a new section, including commands, their purpose, and known limitations.
- **REQ-005**: The real-time Container App system event log stream must be captured as a named, documented command in both the runbook and the diagnostic script.
- **SEC-001**: The diagnostic script must not print storage account keys, gateway tokens, or any secret values to stdout/stderr. Storage key retrieval is acceptable only for downloading the config file; the downloaded file must be deleted before the script exits.
- **CON-001**: Log Analytics queries via `az monitor log-analytics query` are blocked by the prod NSP. The diagnostic script must use direct Azure CLI methods (`az containerapp logs show`, `az rest` diagnostics API, `az containerapp revision show`) instead.
- **CON-002**: Troubleshooting should always target dev or staging, not production. The runbook section must state this explicitly.
- **GUD-001**: Keep the diagnostic script simple and linear — no complex error handling. It is a diagnostic aid, not a production tool.

## 2. Implementation Steps

### Implementation Phase 1 — Fix existing script bugs

- GOAL-001: Ensure `dump-resource-inventory.sh` is reliable before building on top of it.

| Task     | Description                                                                                                                                                                                                                           | Completed | Date       |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---------- |
| TASK-001 | Confirm `scripts/dump-resource-inventory.sh` has both fixes from the 2026-03-30 incident committed: (1) `project` KQL column alias renamed to `project_tag`; (2) `managed_by` tag backslash escaped for KQL via `${VAR//\\/\\\\}`. | ✅         | 2026-03-30 |

### Implementation Phase 2 — Diagnostic script

- GOAL-002: Create `scripts/diagnose-containerapp.sh` — a single command that produces a complete diagnostic snapshot.

| Task     | Description                                                                                                                                                                                                                                                                                                                       | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-002 | Create `scripts/diagnose-containerapp.sh` with the following structure: accept a required `env` argument (`dev` or `prod`); derive resource names from the pattern `paa-${env}-app`, `paa-${env}-rg`, `paa${env}ocstate`, `paa-${env}-kv`; write all output to `scripts/diag-${env}-$(date -u +%Y%m%dT%H%M%SZ).txt`; exit 0 always (capture errors inline). | ✅         | 2026-03-30 |
| TASK-003 | Implement section **A — Revision list** in the script: run `az containerapp revision list` and capture name, state, health, replicas, traffic, created time.                                                                                                                                                                      | ✅         | 2026-03-30 |
| TASK-004 | Implement section **B — Active revision detail** in the script: for the revision with `trafficWeight=100`, run `az containerapp revision show` and print `runningState`, `healthState`, `runningStateDetails`, image, and env vars (redact any `secretRef` values).                                                                | ✅         | 2026-03-30 |
| TASK-005 | Implement section **C — Recent console logs** in the script: identify the current replica via `az containerapp replica list`; run `az containerapp logs show --tail 100 --follow false` and append to output. If no replica is found, note that the container is at 0 replicas and log retrieval is unavailable.                   | ✅         | 2026-03-30 |
| TASK-006 | Implement section **D — System event stream (last 50 events)** in the script: run `az containerapp logs show --type system --tail 50 --follow false`. This is the stream that surfaced the `PortMismatch` event in the incident. If unavailable pipe through a "no system logs available" note.                                   | ✅         | 2026-03-30 |
| TASK-007 | Implement section **E — Diagnostics API: container exit events** in the script: call the Container Apps REST diagnostics endpoint `detectors/containerappscontainerexitevents` via `az rest --method GET` and extract the exit code summary rows.                                                                                   | ✅         | 2026-03-30 |
| TASK-008 | Implement section **F — Diagnostics API: storage mount failures** in the script: call `detectors/containerappsstoragemountfailures` via `az rest --method GET` and print the status row.                                                                                                                                          | ✅         | 2026-03-30 |
| TASK-009 | Implement section **G — Azure Files config inspection** in the script: download `openclaw.json` from the Azure Files share using `az storage file download` with the account key; print the config with the `auth.token` value redacted (`"token": "<redacted>"`); delete the local copy before the script exits.                  | ✅         | 2026-03-30 |
| TASK-010 | Implement section **H — Identity role assignments** in the script: resolve the Managed Identity principal ID via `az identity show`; run `az role assignment list --assignee-object-id` and print role/scope pairs.                                                                                                                | ✅         | 2026-03-30 |
| TASK-011 | Add `scripts/diag-*.txt` to `.gitignore` (or confirm it is already covered by an existing glob pattern).                                                                                                                                                                                                                         | ✅         | 2026-03-30 |

### Implementation Phase 3 — Runbook troubleshooting section

- GOAL-003: Document the full troubleshooting toolkit in `docs/openclaw-containerapp-operations.md` so future on-call engineers know what commands to run and in what order.

| Task     | Description                                                                                                                                                                                                                             | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-012 | Add a new **Section 6: Troubleshooting** to `docs/openclaw-containerapp-operations.md` with the following subsections: 6.1 Quick start; 6.2 Step-by-step diagnostic procedure; 6.3 Tool reference; 6.4 Known limitations.              | ✅         | 2026-03-30 |
| TASK-013 | In **Section 6.1 Quick start**, document the single command `bash scripts/diagnose-containerapp.sh <env>` and where to find its output file.                                                                                            | ✅         | 2026-03-30 |
| TASK-014 | In **Section 6.2 Step-by-step diagnostic procedure**, list the ordered steps used during the 2026-03-30 incident with the exact commands: revision list → revision detail + `runningStateDetails` → replica console log → system event stream → diagnostics API → config file inspection → image schema inspection (Docker). | ✅         | 2026-03-30 |
| TASK-015 | In **Section 6.3 Tool reference**, create a table documenting every diagnostic tool and command used in the incident. See the full tool list in Section 8 of this plan.                                                                 | ✅         | 2026-03-30 |
| TASK-016 | In **Section 6.4 Known limitations**, document: (a) Log Analytics is blocked by the NSP — use direct CLI methods instead; (b) `az containerapp logs show` returns no output when replicas=0; (c) `az containerapp exec` is unreliable against crashing containers; (d) Container Apps diagnostic detectors API returns time-windowed data and may be empty for very recent events. | ✅         | 2026-03-30 |
| TASK-017 | Add a **Section 6.5 Real-time system event stream** to the runbook documenting the command to stream Container App controller events: `az containerapp logs show --name <app> --resource-group <rg> --type system --tail 50 --follow false`. Include a sample event showing the `PortMismatch` pattern so operators recognise it. | ✅         | 2026-03-30 |
| TASK-018 | Add a **Section 6.6 Image schema inspection** to the runbook documenting the Docker-based technique: `docker run --rm <image> sh -c "grep -r '<search-term>' dist/ 2>/dev/null | grep -v '.map' | head -20"` — used to discover valid `gateway.mode` values (`"local"`, `"remote"`) directly from the bundled JS without needing source or docs. | ✅         | 2026-03-30 |

## 3. Alternatives

- **ALT-001**: Use Azure Monitor / App Insights for structured logging from the container. Rejected for this plan scope — that is a separate instrumentation concern tracked in a future plan. The tooling here covers triage of startup and infrastructure failures that occur before the app is running.
- **ALT-002**: Whitelist the dev container's IP in the Log Analytics NSP to enable `az monitor log-analytics query`. This is a valid future improvement but out of scope here; the diagnostic script routes around the NSP by using direct Container Apps CLI methods which do not go through the Log Analytics API.
- **ALT-003**: Use the Azure Portal Diagnose and Solve blade directly. Rejected as the sole troubleshooting method — it requires browser access and produces non-reproducible output. The CLI-based approach in this plan is automatable and auditable.

## 4. Dependencies

- **DEP-001**: `az containerapp logs show` requires the `containerapp` extension (already available in the dev container).
- **DEP-002**: `az rest` used for the diagnostics API requires an active `az login` session with `Microsoft.App/containerApps/detectors/read` permission — covered by the existing contributor role.
- **DEP-003**: `docker` CLI must be available for the image schema inspection technique. It is pre-installed in the dev container.

## 5. Files

- **FILE-001**: `scripts/diagnose-containerapp.sh` — new diagnostic script (created in Phase 2).
- **FILE-002**: `docs/openclaw-containerapp-operations.md` — new Section 6 Troubleshooting (Phase 3).
- **FILE-003**: `scripts/dump-resource-inventory.sh` — already fixed (TASK-001 verification only).
- **FILE-004**: `.gitignore` — add `scripts/diag-*.txt` pattern if not already covered.

## 6. Testing

- **TEST-001**: Run `bash scripts/diagnose-containerapp.sh dev` after `az login`; confirm it exits 0, writes a `scripts/diag-dev-*.txt` output file, and the file contains non-empty content for sections A, D, G, and H.
- **TEST-002**: Confirm the output file does not contain the gateway `auth.token` value (redacted).
- **TEST-003**: Confirm `scripts/diag-*.txt` is not tracked by `git status`.
- **TEST-004**: Run `bash scripts/dump-resource-inventory.sh` and confirm exit 0 with ≥27 resources.

## 7. Risks & Assumptions

- **RISK-001**: `az containerapp logs show --type system` may not be available in all Azure CLI versions or regions. If it fails, section D of the diagnostic script should degrade gracefully with a "not available" note.
- **RISK-002**: The Container Apps diagnostics API (`az rest` detector endpoints) is undocumented/internal. It may change without notice. The diagnostic script should treat a non-200 response as informational only and continue.
- **ASSUMPTION-001**: The dev container environment (`ghcr.io/openclaw/openclaw:2026.2.26`) is accessible from the dev container for `docker run` image inspection. This was confirmed during the incident.
- **ASSUMPTION-002**: The resource naming convention `paa-${env}-*` is stable. If the `project` variable changes, the diagnostic script will need updating.

## 8. Related Specifications / Further Reading

The following tools were used during the 2026-03-30 incident. All are relevant references for the runbook Section 6.3 tool table:

| Tool / Command | Purpose | Limitation |
|---|---|---|
| `bash scripts/dump-resource-inventory.sh` | Discover all resource names by tag | Had two bugs (KQL reserved keyword, backslash escaping); fixed in this incident |
| `az containerapp revision list -o table` | See all revisions with health/traffic/replica counts | First stop for any startup failure |
| `az containerapp revision show --query "properties.runningStateDetails"` | Get the human-readable failure reason (e.g. `"1/1 Container crashing: openclaw"`) | Only available on active revisions |
| `az containerapp replica list` | Get replica name needed for per-replica log retrieval | Returns empty when replicas=0 (crashed container) |
| `az containerapp logs show --revision <rev> --replica <name> --follow false` | Pull container stdout/stderr (the actual crash output) | Requires a running replica; unavailable at replicas=0 |
| `az containerapp logs show --type system --tail 50` | Stream Container App controller events — **surfaced the `PortMismatch` error** | May be unavailable / empty for very recent events |
| `az rest --method GET .../detectors/containerappscontainerexitevents` | Get exit code summary, backoff-restart counts, and last error type across all revisions in a time window | Undocumented API; results are time-windowed |
| `az rest --method GET .../detectors/containerappsstoragemountfailures` | Confirm whether Azure Files mount failures contributed to the crash | Undocumented API; was clean in this incident |
| `az containerapp env storage show` | Verify the Azure Files share binding exists and is configured correctly | — |
| `az storage file list / download` | Inspect the `openclaw.json` config on the persistent Azure Files share | Requires storage account key; delete local copy after use |
| `docker inspect <image>` | Reveal `Entrypoint`, `Cmd`, and env vars baked into the image | Requires docker CLI and image pull access |
| `docker run --rm <image> sh -c "grep -r ..."` | Search bundled JS source in the container for valid config schema values | Used to discover `gateway.mode` valid values (`"local"`, `"remote"`) |
| `az monitor log-analytics query` | Full KQL queries against Container App console logs | **Blocked by prod NSP** — not usable from outside Azure in this environment |
| `mcp_azure_mcp_ser_monitor / monitor_activitylog_list` | Activity log for deployment history and provisioning failures | No container-level detail; useful for Terraform apply failures |
| `az role assignment list --assignee-object-id` | Confirm Managed Identity has required roles (KV Secrets User, AcrPull, AI User) | — |

[docs/openclaw-containerapp-operations.md](../docs/openclaw-containerapp-operations.md)
[plan/feature-openclaw-startup-1.md](feature-openclaw-startup-1.md)
[ARCHITECTURE.md](../ARCHITECTURE.md)
