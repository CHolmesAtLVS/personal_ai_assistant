---
goal: Fix OpenClaw container startup failures discovered during prod incident on 2026-03-30
plan_type: standalone
version: 1.1
date_created: 2026-03-30
last_updated: 2026-03-30
owner: Platform Engineering
status: 'In progress'
tags: [bug, container, terraform, openclaw, operations, runbook]
---

# Introduction

![Status: In progress](https://img.shields.io/badge/status-In%20progress-yellow)

During a production incident on 2026-03-30, the OpenClaw Container App revision `paa-prod-app--0000004` was found in `ActivationFailed / Unhealthy` state after a Terraform apply triggered by PR #16. Live diagnostics uncovered four distinct bugs — three in the ops runbook seed config template and one in the Terraform environment variable defaults — that together prevented the gateway from starting. This plan records the changes needed to make the deployment fully correct and prevent recurrence.

The operational workarounds applied during the incident (gateway config re-seeded on Azure Files, `NODE_OPTIONS` injected via `az containerapp update`) must be codified in Terraform and the runbook.

> **Active outage (2026-03-30):** Both `paa-dev-app` and `paa-prod-app` are currently failing to start. Before working through the implementation phases below, run `bash scripts/diagnose-containerapp.sh dev` to capture a full diagnostic snapshot. Always triage dev first. See **Phase 0** below for the immediate triage procedure.

> **New tooling available:** `scripts/diagnose-containerapp.sh` and the troubleshooting runbook (Section 7 of `docs/openclaw-containerapp-operations.md`) were added as part of [feature-openclaw-troubleshooting-1.md](feature-openclaw-troubleshooting-1.md). Use them as the first tool for any startup failure.

## 1. Requirements & Constraints

- **REQ-001**: All changes must land in Terraform or the ops runbook; no ad-hoc `az containerapp update` state should persist beyond the next Terraform apply.
- **REQ-002**: The fix must not alter ingress configuration, IP restrictions, or KV secret injection behaviour.
- **REQ-003**: The seed config written by the ops runbook must be validated against the OpenClaw schema before upload; the runbook must document valid values.
- **REQ-004**: `dump-resource-inventory.sh` script fixes applied during incident must be committed and not regress.
- **SEC-001**: `openclaw.json` on the Azure Files share contains the gateway `auth.token` value in plain text. Clean up temp files after any download/edit operation — as already confirmed in the runbook.
- **CON-001**: Container App resource allocation has been increased to 2 vCPU / 4 GiB (from 0.5 vCPU / 1 GiB) in `terraform/containerapp.tf` to address the Node.js OOM crash. `NODE_OPTIONS=--max-old-space-size=768` applied as a temporary operational workaround is superseded by this change and should be removed from the container env.
- **CON-002**: The `openclaw_control_ui_allowed_origins_json` Terraform variable validation requires HTTPS-prefixed entries only. An empty array `[]` passes validation but causes a gateway startup failure when `bind=lan`. The variable description must be updated to make this non-obvious constraint clear.
- **GUD-001**: Follow the two-phase bootstrap order (KV secret first, Terraform apply second, config seed third) documented in the ops runbook.
- **PAT-001**: Any env var added to the Container App template in Terraform must also be added to the relevant GitHub Environment variable tables in `readme.md` and `docs/secrets-inventory.md`.

## 2. Implementation Steps

### Implementation Phase 0 — Immediate triage (active outage)

- GOAL-000: Capture a diagnostic snapshot for dev and prod before making any changes, so the root cause is confirmed before any Terraform or config edits are applied.

| Task     | Description                                                                                                                                                                                                                                                 | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-000 | Run `bash scripts/diagnose-containerapp.sh dev` after `az login`. Review the output file `scripts/diag-dev-<timestamp>.txt`. Check sections in this order: **B** (`runningStateDetails` — human-readable failure reason), **D** (system event stream — look for `PortMismatch`, `BackOff`, or `OOMKilling`), **G** (config file — confirm `gateway.mode`, `gateway.port`=18789, `gateway.bind`, `controlUi.allowedOrigins` non-empty), **H** (role assignments — confirm `Key Vault Secrets User` present). Do **not** run against prod until dev is confirmed healthy. |

If `runningStateDetails` surfaces a known pattern, match it to the appropriate phase below:

| Symptom in snapshot | Root cause | Implementation phase to apply |
|---|---|---|
| `PortMismatch` in section D | `gateway.port` ≠ 18789, or config absent at first boot | Phase 2, Phase 3 |
| Exit code 1 / container crashing, section G shows `gateway.mode` = `"server"` | Invalid mode value | Phase 3 (TASK-007) |
| Exit code 137 / OOMKilling in section D | Container under-resourced | Phase 1 (TASK-001) |
| Section G: `controlUi.allowedOrigins` = `[]` | Empty origins with `bind=lan` | Phase 1 (TASK-003), Phase 3 (TASK-009) |
| Section H: `Key Vault Secrets User` missing | Missing managed identity role | Terraform `roleassignments.tf` — separate change |

### Implementation Phase 1 — Terraform fixes

- GOAL-001: Codify the `NODE_OPTIONS` workaround and fix the empty `OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS` default so Terraform state matches the working runtime configuration.

| Task     | Description                                                                                                                                                                                                                     | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | In `terraform/containerapp.tf`, set `cpu = 2` and `memory = "4Gi"` on the `openclaw` container (already done directly — verify no drift). Ensure `NODE_OPTIONS` injected via `az containerapp update` during the incident is **not** present in Terraform (the size increase is the correct fix; `NODE_OPTIONS` was a temporary workaround). |           |      |
| TASK-002 | In `terraform/variables.tf`, update the `description` of `openclaw_control_ui_allowed_origins_json` to warn that an empty array `[]` will cause gateway startup failure when `bind=lan`; the FQDN must be set before enabling. |           |      |
| TASK-003 | In `terraform/containerapp.tf`, update the `OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS` env var description comment to note that an empty array causes a gateway startup failure; operators must update `TF_VAR_OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS_JSON` after first apply. |           |      |
| TASK-004 | Run `terraform fmt` and `terraform validate` locally with the dev backend to confirm no syntax errors.                                                                                                                          |           |      |

### Implementation Phase 2 — Port mismatch fix

- GOAL-002: Prevent the `TargetPort 18789 does not match the listening port 80` mismatch that occurs when the container starts with `--allow-unconfigured` and no config file, causing the default gateway port (80) to differ from the Terraform ingress `targetPort` (18789).

| Task     | Description                                                                                                                                                                                                                                                                           | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-005 | In `terraform/containerapp.tf`, add `{ name = "OPENCLAW_GATEWAY_PORT", value = "18789" }` to the static env list. Verify against the OpenClaw image's env-var schema (inspect `dist/gateway-cli-*.js` for `OPENCLAW_GATEWAY_PORT` handling) to confirm the var is honoured; if not supported, document the finding and remove. |           |      |
| TASK-006 | If `OPENCLAW_GATEWAY_PORT` is not supported by the OpenClaw binary, add a note to the ops runbook (section 1.3) stating that the config file **must exist on the Azure Files share before the Container App creates its first replica**, and that a port mismatch will occur on the old revision until the next config-bearing revision starts. The system event stream (`az containerapp logs show --type system`) documented in runbook Section 7.5 is the fastest way to confirm a `PortMismatch` is occurring. |           |      |

### Implementation Phase 3 — Ops runbook seed config template

- GOAL-003: Fix and harden the `openclaw.json` seed config template in `docs/openclaw-containerapp-operations.md` so it produces a schema-valid config on first use.

| Task     | Description                                                                                                                                                                                                                                                                                             | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-007 | In `docs/openclaw-containerapp-operations.md` section 1.3, change `"mode": "server"` → `"mode": "local"` in the `openclaw.json` heredoc. Valid values discovered from the image binary are `"local"` and `"remote"`.                                                                                   |           |      |
| TASK-008 | In the same heredoc, confirm `"port": 18789` and `"bind": "lan"` are already present (they are) and that `"controlUi": { "allowedOrigins": ["${APP_FQDN}"] }` is nested correctly inside the `"gateway"` key (it is). Add an inline comment noting all four fields are required for `bind=lan` operation. |           |      |
| TASK-009 | Add a `## Schema reference` subsection (or inline note) after the heredoc listing the validated field constraints: `gateway.mode` must be `"local"` or `"remote"`; `gateway.bind=lan` requires `gateway.controlUi.allowedOrigins` to be non-empty; `gateway.port` must match Terraform ingress `targetPort`. |           |      |
| TASK-010 | In `docs/openclaw-containerapp-operations.md` section 2 (Gateway Token Rotation) and section 3 (Gateway Configuration Updates), add `"mode": "local"` to any partial JSON examples that show the gateway block to prevent the same mistake on re-seed. |           |      |

### Implementation Phase 4 — Script fix commit

- GOAL-004: Commit the `dump-resource-inventory.sh` fixes made during the incident so they are not lost.

| Task     | Description                                                                                                                                                                                                                                                                                              | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-011 | Verify `scripts/dump-resource-inventory.sh` has both fixes applied: (1) `project` column alias renamed to `project_tag` (KQL reserved keyword); (2) backslash in the `managed_by` tag value is doubled before embedding in the KQL string (`${MANAGED_BY_VALUE//\\/\\\\}`). Stage and commit if not yet committed. |           |      |

### Implementation Phase 5 — CI / variable propagation

- GOAL-005: Update documentation to reflect the correct 2 vCPU / 4 GiB resource allocation and remove any `NODE_OPTIONS` workaround references.

| Task     | Description                                                                                                                                                                                   | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-012 | In `readme.md`, update the container resource spec row (if present) to reflect 2 vCPU / 4 GiB. Remove any `NODE_OPTIONS` reference added as a workaround.                                    |           |      |
| TASK-013 | In `docs/secrets-inventory.md`, remove `NODE_OPTIONS` if it was added as a workaround entry; it is not a secret or persistent env var.                                                        |           |      |

## 3. Alternatives

- **ALT-001**: Cap the Node.js heap via `NODE_OPTIONS=--max-old-space-size=768` instead of increasing the container size. Rejected as the permanent fix — it masks the problem rather than solving it, and OpenClaw publishes no official resource requirements so an arbitrary heap cap risks instability under load. The correct fix is to provision adequate resources (2 vCPU / 4 GiB).
- **ALT-002**: Change the ingress `targetPort` from 18789 to 80 to match the unconfigured default. Rejected: port 18789 is OpenClaw's documented gateway port; matching it is the correct architecture.
- **ALT-003**: Add a Kubernetes init-container or startup script to pre-seed the config. Rejected: Azure Container Apps does not support init-containers; the pre-seed via Azure Files upload before first replica start is the correct approach.

## 4. Dependencies

- **DEP-001**: The `openclaw-gateway-token` Key Vault secret is managed by Terraform and will be created automatically on first apply. No manual pre-provisioning or enable flag is required.
- **DEP-002**: `TF_VAR_OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS_JSON` must be set to the app FQDN JSON array in the `terraform-prod` GitHub Environment before the next Terraform apply.

## 5. Files

- **FILE-001**: `terraform/containerapp.tf` — increase `cpu` to `2` and `memory` to `"4Gi"`; add `OPENCLAW_GATEWAY_PORT` env var; remove any `NODE_OPTIONS` workaround if present.
- **FILE-002**: `terraform/variables.tf` — update description of `openclaw_control_ui_allowed_origins_json`.
- **FILE-003**: `docs/openclaw-containerapp-operations.md` — fix seed config template (`gateway.mode`), add schema reference, harden partial JSON examples.
- **FILE-004**: `scripts/dump-resource-inventory.sh` — ensure KQL keyword and backslash fixes are committed.
- **FILE-005**: `readme.md` — add `NODE_OPTIONS` to the CI environment variables table.
- **FILE-006**: `docs/secrets-inventory.md` — document `NODE_OPTIONS` as a non-sensitive container env var.

## 6. Testing

- **TEST-000**: Run `bash scripts/diagnose-containerapp.sh dev` before applying any changes; confirm the output file is written and section B shows the current failure reason. Use this as the baseline.
- **TEST-001**: After Terraform apply, confirm `az containerapp show` reports `cpu=2` and `memory=4Gi` on the container spec, and that `NODE_OPTIONS` is absent from the env vars block.
- **TEST-002**: Run `bash scripts/dump-resource-inventory.sh` and confirm it exits 0 and writes a CSV with ≥27 resources.
- **TEST-003**: Re-seed `openclaw.json` using the updated runbook template against the dev environment and confirm the Container App revision reaches `Running / Healthy` state within 3 minutes.
- **TEST-004**: Run `bash scripts/diagnose-containerapp.sh dev` again after the fix cycle. Confirm section B shows `runningState: Running`, section D has no `PortMismatch` or `BackOff` events, section G shows `gateway.mode=local` with correct port and non-empty `allowedOrigins`, and section H confirms `Key Vault Secrets User` is assigned.
- **TEST-005**: Confirm `az containerapp revision list` shows no `ActivationFailed` or `Failed` revisions after a clean Terraform apply + config seed cycle.
- **TEST-006**: Confirm the Container Apps system event log (section D of the diagnostic output, or via `az containerapp logs show --type system`) for the superseded prod revision no longer emits `PortMismatch` events after the revision is deactivated.

## 7. Risks & Assumptions

- **RISK-001**: `OPENCLAW_GATEWAY_PORT` env var may not be read by the OpenClaw binary. If it is not, port mismatch on first-boot is unavoidable without an init-container workaround. The impact is limited to the time between first Terraform apply and config seed (section 1.3 of the runbook).
- **RISK-002**: OpenClaw does not publish official minimum resource requirements. 2 vCPU / 4 GiB is sized based on the observed OOM at 503 MB heap on a 1 GiB container, with headroom for future growth. Monitor memory usage metrics after the next stable revision and adjust if the gateway regularly approaches 3 GiB.
- **ASSUMPTION-001**: The prod `TF_VAR_OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS_JSON` GitHub Environment variable is currently unset or set to `[]`. It must be updated to `["https://<prod-app-fqdn>"]` before the next Terraform apply.
- **ASSUMPTION-002**: The legacy pre-mount revision (running on port 80) carries 0% traffic weight and will be superseded by the next Terraform apply. No explicit deactivation is required.

## 8. Related Specifications / Further Reading

- [docs/openclaw-containerapp-operations.md](../docs/openclaw-containerapp-operations.md) — Section 7 contains the full troubleshooting toolkit, step-by-step diagnostic procedure, tool reference table, and known limitations
- [docs/secrets-inventory.md](../docs/secrets-inventory.md)
- [ARCHITECTURE.md](../ARCHITECTURE.md)
- [plan/feature-openclaw-troubleshooting-1.md](feature-openclaw-troubleshooting-1.md) — diagnostic script and runbook section created from the 2026-03-30 incident
- [scripts/diagnose-containerapp.sh](../scripts/diagnose-containerapp.sh) — single command to capture a full startup diagnostic snapshot; run first for any startup failure
- [.github/skills/openclaw-troubleshoot/SKILL.md](../.github/skills/openclaw-troubleshoot/SKILL.md) — AI agent skill for guided troubleshooting
- [OpenClaw gateway-cli source (dist/gateway-cli-BSPSAjqx.js) — `mode` valid values: `"local"`, `"remote"`]
