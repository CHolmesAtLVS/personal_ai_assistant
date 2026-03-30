---
goal: Implement cron-based Container App scaling to minimize costs within the Azure Container Apps free tier
plan_type: standalone
version: 1.0
date_created: 2026-03-30
last_updated: 2026-03-30
owner: Platform Engineering
status: 'Planned'
tags: [feature, infrastructure, terraform, azure-container-apps, scaling, cost]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

The OpenClaw Container App currently uses a static allocation of 2 vCPU / 4 GiB with `min_replicas = 0`. Because traffic is personal/single-user, the container is only needed during active working hours. Adding a cron-based scaling rule would allow the replica count to drop to 0 outside those windows, reducing vCPU-second and GiB-second consumption and potentially keeping the deployment within the Azure Container Apps Consumption plan free tier.

**All implementation details must be investigated before work begins.** This plan documents the intent, constraints, and investigation tasks. No implementation tasks should be actioned until the investigation phase is complete and findings have been recorded back into this document.

## 1. Requirements & Constraints

- **REQ-001**: Scaling must be implemented declaratively in Terraform; no ad-hoc `az containerapp update` changes.
- **REQ-002**: The primary goal is to minimize vCPU-second and GiB-second consumption to stay within the Azure Container Apps Consumption plan free tier if feasible at the 2 vCPU / 4 GiB resource allocation. Free-tier limits and current consumption must be investigated before sizing the schedule.
- **REQ-003**: Ingress, IP restrictions, KV secret injection, and health probe configuration must not be altered by this change.
- **REQ-004**: The scaling schedule must be configurable via a Terraform variable so it can be adjusted without code changes.
- **CON-001**: The AVM module `Azure/avm-res-app-containerapp/azurerm ~> 0.3` is the authoritative Terraform source. Cron scaler support in this module version must be verified before implementation — the module may expose scaling rules differently from the raw `azurerm_container_app` resource.
- **CON-002**: Azure Container Apps cron scaling uses KEDA. The exact Terraform HCL schema for a cron scale rule under the AVM module is unknown and must be investigated.
- **CON-003**: At 2 vCPU / 4 GiB, the free-tier math must account for whether the free grant is per-subscription or per-resource, and whether the grant resets monthly. These details must be confirmed before assuming free-tier eligibility.
- **CON-004**: A cron scaler that scales to 0 means the container cold-starts on first request. Cold-start latency at 2 vCPU / 4 GiB must be assessed and deemed acceptable for a personal-use assistant.
- **GUD-001**: Changes must be validated in the dev environment (`paa-dev-app`) before applying to prod.
- **PAT-001**: Follow the AVM Terraform patterns already established in the codebase; do not mix raw `azurerm_container_app` resource blocks with the AVM module.

## 2. Implementation Steps

### Implementation Phase 1 — Investigation

- GOAL-001: Gather all facts required to make implementation decisions. No code changes in this phase — only research and recorded findings.

| Task     | Description                                                                                                                                                                                                                                                                                                   | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | Confirm the Azure Container Apps Consumption plan free-tier grant: vCPU-seconds/month and GiB-seconds/month limits, whether the grant is per-subscription or per-resource, and whether previously consumed resources (the prod app during the incident) counted against the current billing period.             |           |      |
| TASK-002 | Calculate whether 2 vCPU / 4 GiB running only during a defined active window (e.g., 08:00–22:00 local time, 14 hours/day) stays within the monthly free grant. Document the math and the conclusion in this plan.                                                                                             |           |      |
| TASK-003 | Review the AVM module `Azure/avm-res-app-containerapp/azurerm ~> 0.3` source and changelog to confirm whether cron scale rules are exposed as a first-class input. Identify the exact variable name and schema. If not exposed, determine whether upgrading the module to a later minor version unlocks the feature. |           |      |
| TASK-004 | Review the KEDA cron scaler specification to understand the required fields: `timezone`, `start`, `end`, `desiredReplicas`, and any Azure-specific constraints on the cron expression format or UTC-offset handling.                                                                                            |           |      |
| TASK-005 | Determine the cold-start latency for the container at 2 vCPU / 4 GiB: pull the image size, estimate Node.js startup time based on observed logs from the incident, and confirm whether the latency is acceptable for personal use. Record findings here.                                                       |           |      |
| TASK-006 | Confirm that `min_replicas = 0` (already set in `terraform/containerapp.tf`) is compatible with a cron scaler that drives replica count to 0 outside the active window. Verify there are no conflicts with the existing health probe configuration (`/healthz`, `/readyz` at port 18789).                      |           |      |

### Implementation Phase 2 — Terraform changes

- GOAL-002: Implement the cron scaling rule in Terraform once all investigation findings from Phase 1 are recorded and the approach is confirmed viable.

| Task     | Description                                                                                                                                                                                                                                 | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-007 | Add a `openclaw_scaling_cron_schedule` (or equivalent) Terraform variable to `terraform/variables.tf` with a default value covering the desired active window. Include timezone, start cron, end cron, and desired replica count as sub-fields or a JSON string, based on what the AVM module accepts. |           |      |
| TASK-008 | In `terraform/containerapp.tf`, add the cron scale rule block to the AVM module call using the schema confirmed in TASK-003. Wire it to the variable defined in TASK-007.                                                                   |           |      |
| TASK-009 | Run `terraform fmt` and `terraform validate` locally with the dev backend to confirm no syntax errors. Apply to the dev environment (`paa-dev-app`) and observe scaling behaviour over at least one cron boundary.                          |           |      |
| TASK-010 | After successful dev validation, apply to prod. Confirm via `az containerapp revision list` that the new revision is `Running / Healthy` and that replica count drops to 0 at the scheduled time.                                           |           |      |

### Implementation Phase 3 — Documentation

- GOAL-003: Update operational documentation to reflect the new scaling behaviour.

| Task     | Description                                                                                                                                                                                                                | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-011 | In `docs/openclaw-containerapp-operations.md`, add a section describing the cron scaling schedule, how to update it, and what to expect during scale-to-zero (cold-start latency, health probe timing).                   |           |      |
| TASK-012 | In `readme.md`, update the Container App configuration summary to note the active/inactive windows and link to the ops runbook section.                                                                                    |           |      |

## 3. Alternatives

- **ALT-001**: HTTP-based autoscaling (scale to 0 on no inbound requests, scale up on first request). Rejected as primary approach — HTTP scaling in Azure Container Apps introduces a request-buffering mechanism whose behaviour with OpenClaw's WebSocket/long-lived connections is unknown. Cron-based scaling is more predictable for a personal-use pattern.
- **ALT-002**: Reduce resource allocation below 2 vCPU / 4 GiB to increase the proportion of time within the free tier. Not pursued here — resource sizing was set to address a confirmed OOM crash. See [plan/feature-openclaw-startup-1.md](feature-openclaw-startup-1.md) RISK-002 for monitoring guidance.
- **ALT-003**: Scale to a single replica at a micro size (e.g., 0.25 vCPU) outside business hours rather than scaling to 0. Would avoid cold-start but does not achieve zero consumption during the off-window. Defer to investigation findings in TASK-001–TASK-005.

## 4. Dependencies

- **DEP-001**: Phase 1 investigation must be fully completed and findings recorded before any Phase 2 tasks begin.
- **DEP-002**: AVM module version must be confirmed as supporting cron scale rules, or a module upgrade path identified (TASK-003). If an upgrade is required, follow the AVM upgrade patterns in the codebase.
- **DEP-003**: Dev environment (`paa-dev-app`) must be available for validation in TASK-009. If dev has been torn down, re-provision it via `terraform workspace select dev && terraform apply` before testing.

## 5. Files

- **FILE-001**: `terraform/containerapp.tf` — add cron scale rule block to the AVM module call.
- **FILE-002**: `terraform/variables.tf` — add `openclaw_scaling_cron_schedule` variable (or equivalent).
- **FILE-003**: `docs/openclaw-containerapp-operations.md` — add cron scaling section.
- **FILE-004**: `readme.md` — update Container App configuration summary.

## 6. Testing

- **TEST-001**: In the dev environment, confirm that `az containerapp revision list` shows 0 replicas outside the configured cron window.
- **TEST-002**: In the dev environment, confirm that replica count rises to the configured desired value at the cron start time.
- **TEST-003**: Confirm the OpenClaw gateway is reachable (HTTP 200 on `/healthz`) within an acceptable time (to be defined after TASK-005 cold-start investigation) after scale-up.
- **TEST-004**: After prod apply, monitor Azure Cost Management for vCPU-second and GiB-second consumption over a full billing period and confirm alignment with the free-tier calculation from TASK-002.

## 7. Risks & Assumptions

- **RISK-001**: The AVM module version in use (`~> 0.3`) may not expose cron scale rules. A module upgrade may introduce breaking changes to the Container App resource. Mitigation: confirm in TASK-003, test in dev before prod.
- **RISK-002**: At 2 vCPU / 4 GiB, even with cron scaling, the monthly consumption during active hours may exceed the free-tier grant. Mitigation: complete TASK-001–TASK-002 before committing to the approach. If the free tier cannot be achieved at this resource size, document the expected monthly cost instead.
- **RISK-003**: Cold-start time at 2 vCPU / 4 GiB may be perceptible for a single user. If the OpenClaw image is large or Node.js startup is slow, the first request after scale-up may time out. Mitigation: investigate in TASK-005; consider a readiness grace period adjustment if needed.
- **ASSUMPTION-001**: Usage is sufficiently predictable (single user, working-hours pattern) that a fixed cron schedule is more appropriate than reactive HTTP scaling.
- **ASSUMPTION-002**: The Azure Container Apps Consumption plan free tier applies to this subscription and has not been consumed by other workloads in the same billing period.

## 8. Related Specifications / Further Reading

- [plan/feature-openclaw-startup-1.md](feature-openclaw-startup-1.md) — resource sizing rationale
- [terraform/containerapp.tf](../terraform/containerapp.tf)
- [docs/openclaw-containerapp-operations.md](../docs/openclaw-containerapp-operations.md)
- [Azure Container Apps KEDA scale rules documentation](https://learn.microsoft.com/en-us/azure/container-apps/scale-app)
