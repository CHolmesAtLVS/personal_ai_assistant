---
goal: Fix dev AKS cluster nightly shutdown — wrong schedule time and orphaned morning_start race condition
plan_type: standalone
version: "1.0"
date_created: 2026-04-28
owner: Craig Holmes
status: 'Planned'
tags: [bug, cost, infrastructure, automation, dev]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

The dev AKS cluster (`paa-dev-aks`) did not stop overnight on 2026-04-27/28 and is currently running when it should be stopped. Root cause analysis via the AKS Activity Log identified two compounding defects:

1. **Wrong nightly stop time**: `azurerm_automation_schedule.nightly_stop` fires at **11:18 AM MDT** (17:18 UTC) instead of at night. The `start_time` was set to `plantimestamp() + 24h` when the resource was first created in Terraform, and `lifecycle { ignore_changes = [start_time] }` prevents any correction.

2. **Orphaned `morning_start` schedule**: An Azure Automation Schedule and job-schedule link named `*-morning-start` exists in Azure but is no longer in Terraform. It fires at the same bad time as `nightly_stop`, causing a concurrent stop+start race. The stop fails; the start succeeds. The cluster runs all day and never stops overnight.

This plan fixes both defects and verifies the cluster stops reliably.

**Related plan**: [standalone-dev-cluster-stop-only-feature-1.md](standalone-dev-cluster-stop-only-feature-1.md) — originally written to remove the morning_start Terraform resources. Those resources are already absent from `automation.tf`; the cleanup is now an Azure-side orphan removal (Phase 2 below). That plan is superseded by this one.

## 1. Requirements & Constraints

- **REQ-001**: The `nightly_stop` schedule must fire at **10:00 PM Mountain time** (04:00 UTC) every night.
- **REQ-002**: No morning auto-start schedule may exist in Azure or Terraform after this fix.
- **REQ-003**: The `stop_dev_cluster` runbook and `stop_link` job-schedule must remain active and unchanged.
- **REQ-004**: The `start_dev_cluster` runbook must be retained for manual use.
- **REQ-005**: The dev cluster must be stopped immediately (before any code change) to stop accruing cost.
- **REQ-006**: Validation must distinguish between the two clusters' expected behaviours: dev has **stop-only** automation (no automated start); prod has **no automation at all** and is manually stopped and started by the operator.
- **REQ-007**: When a PR is opened, synchronized, or reopened targeting `dev`, the CI workflow must automatically start `paa-dev-aks` if it is stopped before running any Terraform or kubectl steps. This ensures CI is never blocked by a stopped cluster without requiring manual intervention.
- **CON-001**: `lifecycle { ignore_changes = [start_time] }` must be removed so Terraform can reconcile the correct time. The static `start_time` value replaces the dynamic `plantimestamp()` expression, eliminating perpetual drift.
- **CON-002**: The orphaned `morning_start` schedule must be deleted directly from Azure (it is not in Terraform state). Use `az automation schedule delete` targeting the dev environment only.
- **GUD-001**: All `az` commands target dev resources only (`paa-dev-rg`). Do not run against prod.
- **GUD-002**: Run `terraform plan` before `terraform apply` and confirm only `azurerm_automation_schedule.nightly_stop[0]` is replaced (destroy + create). No other resources should change.
- **SEC-001**: No secrets or subscription IDs in source code or plan files.

## 2. Implementation Steps

### Phase 1 — Immediate Remediation (No Code Change)

- GOAL-001: Stop the dev cluster manually to halt cost accumulation. This is a pre-condition for all other phases.

| Task     | Description                                                                                                                                                                                     | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | Stop the dev cluster via CLI: `az aks stop --resource-group paa-dev-rg --name paa-dev-aks`. Confirm power state is `Stopped` with: `az aks show --resource-group paa-dev-rg --name paa-dev-aks --query powerState.code -o tsv` |           |      |

### Phase 2 — Azure Cleanup (Orphaned Schedules)

- GOAL-002: Remove the orphaned `morning_start` schedule and its job-schedule link from Azure. These are not in Terraform state, so they must be deleted directly via the Azure CLI targeting dev.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                         | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-002 | Identify the Automation Account name for dev: `az automation account list --resource-group paa-dev-rg --query "[].name" -o tsv`. Expected value matches the pattern `paa-dev-auto`. Confirm before proceeding.                                                                                                                                                                                                                                      |           |      |
| TASK-003 | List all schedules in the dev Automation Account to confirm the orphan exists: `az automation schedule list --resource-group paa-dev-rg --automation-account-name <account-name> --query "[].name" -o tsv`. Look for a schedule named `*-morning-start` or similar. If no such schedule is found, skip TASK-004 and TASK-005.                                                                                                                        |           |      |
| TASK-004 | If `morning_start` schedule is found: first remove the job-schedule link. List job-schedules with: `az automation job-schedule list --resource-group paa-dev-rg --automation-account-name <account-name> -o json`. Identify the job-schedule ID linked to the morning-start schedule. Delete it: `az automation job-schedule delete --resource-group paa-dev-rg --automation-account-name <account-name> --job-schedule-id <id> --yes`.             |           |      |
| TASK-005 | Delete the orphaned schedule: `az automation schedule delete --resource-group paa-dev-rg --automation-account-name <account-name> --name <morning-start-schedule-name> --yes`. Confirm it is gone by re-running the list command from TASK-003.                                                                                                                                                                                                      |           |      |

### Phase 3a — CI Workflow Change (Auto-Start Dev on PR)

- GOAL-003a: Create a reusable shell script `scripts/start-dev-cluster.sh` that starts `paa-dev-aks` if it is not already running, then update `.github/workflows/terraform-dev.yml` to call it. The script is idempotent, exits 0 immediately if the cluster is already `Running`, and polls for up to **10 minutes** before failing. It can be called locally before dev work as well as from CI.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-006 | Create `scripts/start-dev-cluster.sh` with the following exact content and `chmod +x` it. The script must be committed to the repo.<br><br>```bash<br>#!/usr/bin/env bash<br># start-dev-cluster.sh — Start paa-dev-aks if it is not already Running.<br># Safe to run locally or from CI. Exits 0 immediately if already Running.<br># Waits up to 10 minutes for the cluster to reach Running state.<br>#<br># Prerequisites: az login (or managed identity in CI), correct subscription set.<br># Usage: ./scripts/start-dev-cluster.sh<br><br>set -euo pipefail<br><br>RG="paa-dev-rg"<br>CLUSTER="paa-dev-aks"<br>TIMEOUT=600   # 10 minutes<br>INTERVAL=30<br><br>echo "Checking power state of ${CLUSTER}..."<br>POWER=$(az aks show --resource-group "${RG}" --name "${CLUSTER}" --query powerState.code -o tsv)<br><br>if [[ "${POWER}" == "Running" ]]; then<br>  echo "${CLUSTER} is already Running — no action needed."<br>  exit 0<br>fi<br><br>echo "${CLUSTER} is ${POWER} — starting..."<br>az aks start --resource-group "${RG}" --name "${CLUSTER}" --no-wait<br><br>ELAPSED=0<br>while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do<br>  STATE=$(az aks show --resource-group "${RG}" --name "${CLUSTER}" --query powerState.code -o tsv)<br>  if [[ "${STATE}" == "Running" ]]; then<br>    echo "${CLUSTER} is Running (waited ${ELAPSED}s)."<br>    exit 0<br>  fi<br>  echo "  State: ${STATE} — waiting ${INTERVAL}s (${ELAPSED}/${TIMEOUT}s elapsed)..."<br>  sleep ${INTERVAL}<br>  ELAPSED=$(( ELAPSED + INTERVAL ))<br>done<br><br>echo "ERROR: ${CLUSTER} did not reach Running state within ${TIMEOUT}s." >&2<br>exit 1<br>``` |           |      |
| TASK-007 | In `.github/workflows/terraform-dev.yml`, add a new step named `Start dev AKS cluster` immediately after the `Azure Login (Service Principal)` step and before `Bootstrap Terraform Backend`. Step content:<br>`run: ./scripts/start-dev-cluster.sh`<br>`shell: bash`<br>No inline az commands — delegate entirely to the script. |           |      |
| TASK-008 | Include both TASK-006 and TASK-007 in the same PR as the Terraform `automation.tf` change (TASK-010 below). All three changes are logically related and must ship together.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |           |      |

### Phase 3b — Terraform Fix (Correct Nightly Stop Time)

- GOAL-003b: Replace the dynamic `start_time` expression in `nightly_stop` with a static 10:00 PM Mountain time value and remove `lifecycle { ignore_changes = [start_time] }`. This forces Terraform to destroy and recreate the schedule with the correct time on the next apply.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-009 | In `terraform/automation.tf`, replace the `azurerm_automation_schedule.nightly_stop` resource block content. Make two changes: (1) replace `start_time = timeadd(plantimestamp(), "24h")` with `start_time = "2026-05-01T22:00:00-06:00"` (10 PM MDT — UTC-6; Azure handles DST via the `timezone = "America/Denver"` field), and (2) delete the entire `lifecycle { ignore_changes = [start_time] }` block. Update the comment on the `start_time` line to: `# Fixed 10 PM Mountain time; timezone field handles DST.` |           |      |
| TASK-010 | Verify no other file in `terraform/` references `morning_start` or `start_link`. Run: `grep -r "morning_start\|start_link" terraform/` — expect zero results.                                                                                                                                                                                                                                                                                                                                            |           |      |
| TASK-011 | Open a PR targeting `dev` containing the `scripts/start-dev-cluster.sh` addition (TASK-006), the `.github/workflows/terraform-dev.yml` change (TASK-007), and the `terraform/automation.tf` change (TASK-009). No other files should be modified in this PR.                                                                                                                                                                                                                                              |           |      |
| TASK-012 | After CI runs `terraform plan` on the PR, confirm the plan shows exactly **one replacement**: `azurerm_automation_schedule.nightly_stop[0]` (destroy + create). The `azurerm_automation_job_schedule.stop_link[0]` will also be replaced automatically because it has a `depends_on`-like relationship with the schedule. Confirm no other resources are affected. If `stop_link` does not auto-replace, it may need a `terraform taint` — check CI plan output carefully.                                 |           |      |
| TASK-013 | Merge the PR. CI applies `terraform apply` against dev. After apply, verify in the Azure Portal → Automation Account → Schedules that `*-nightly-stop` shows a next occurrence at 10:00 PM Mountain time.                                                                                                                                                                                                                                                                                                |           |      |

### Phase 4a — Dev Validation (Shutdown Only)

- GOAL-004: Confirm `paa-dev-aks` stops on schedule the following night and that **no automated start** follows. Dev should be left stopped indefinitely; a `start/action` from the Automation Account caller is a regression.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                      | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-014 | The morning after the fix is applied, query the dev cluster Activity Log over the past 12 hours and confirm a `Microsoft.ContainerService/managedClusters/stop/action` event with status `Succeeded` appears at approximately 04:00 UTC (10 PM MDT). Command: `az monitor activity-log list --resource-group paa-dev-rg --resource-type Microsoft.ContainerService/managedClusters --resource-id <aks-resource-id> --start-time <yesterday-10pm-utc> --query "[].{ts:eventTimestamp,op:operationName.value,status:status.value,caller:claims.appid}" -o table` |           |      |
| TASK-015 | Confirm dev cluster power state is `Stopped` (not `Running`): `az aks show --resource-group paa-dev-rg --name paa-dev-aks --query powerState.code -o tsv`. Expected output: `Stopped`.                                                                                                                                                                                                                                          |           |      |
| TASK-016 | Confirm **no** `start/action` event appears in the same 12-hour Activity Log window from any Automation Account caller. A `start/action` in this window means an orphaned schedule is still present and must be hunted down (re-run Phase 2 discovery steps).                                                                                                                                                                     |           |      |

### Phase 4b — Prod Validation (Stop + Start Cycle)

- GOAL-005: Confirm `paa-prod-aks` follows its expected manual stop+start pattern. Prod has **no automation** — it is stopped and started manually by the operator. Validation checks that both a stop and a subsequent start are visible in the Activity Log within the same business day, and that no orphaned or unexpected schedule is firing against prod.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                          | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-017 | Query the prod cluster Activity Log over the past 36 hours and confirm a `stop/action Succeeded` event is present: `az monitor activity-log list --resource-group paa-prod-rg --resource-type Microsoft.ContainerService/managedClusters --resource-id <prod-aks-resource-id> --start-time <36h-ago> --query "[?contains(operationName.value,'stop') || contains(operationName.value,'start')].{ts:eventTimestamp,op:operationName.value,status:status.value,caller:caller}" -o table`. Expected: one `stop/action Succeeded` and one `start/action Succeeded` within the same business day. |           |      |
| TASK-018 | Confirm the stop and start callers on prod are a **human or Service Principal** identity (e.g. `craig.holmes.32@gmail.com` or the GitHub Actions SP GUID) — not an Automation Account managed identity. Prod has no Automation Account; any Automation Account caller on prod would indicate a misrouted or unintended schedule.                                                                                                                       |           |      |
| TASK-019 | Confirm no Azure Automation Account exists in `paa-prod-rg`: `az automation account list --resource-group paa-prod-rg -o tsv`. Expected: empty output. If an account is found, flag for review — `automation.tf` gates all automation resources on `var.environment == "dev"` and no account should exist in prod.                                                                                                                                   |           |      |

## 3. Alternatives

- **ALT-001**: Keep `lifecycle { ignore_changes = [start_time] }` and `terraform taint` the schedule to force recreation with the corrected static time, then add `ignore_changes` back in a follow-up PR. Rejected: two PRs for one fix adds complexity; removing `ignore_changes` and using a static string eliminates all future drift with no downside.
- **ALT-002**: Use `az automation schedule update` to change the start time in Azure without a Terraform change. Rejected: this creates drift between Terraform state and Azure reality; on next `terraform plan` the drift would appear as a diff.
- **ALT-003**: Delete the entire `nightly_stop` schedule and `stop_link` from Terraform, then re-add them with the correct time. Equivalent to ALT-001 but with more boilerplate; the targeted resource change in TASK-008 is simpler.
- **ALT-004**: Add an Azure Automation schedule that starts the dev cluster when a new GitHub Actions run is detected (event-driven). Rejected: no native Azure Automation trigger for GitHub events; the CI workflow step (Phase 3a) is simpler and directly coupled to the PR lifecycle.
- **ALT-005**: Use a separate GitHub Actions workflow triggered on `pull_request` that only starts the cluster, then waits. Rejected: adds workflow coordination overhead; an inline step in `terraform-dev.yml` before Terraform Init is sufficient and keeps the logic co-located.

## 4. Dependencies

- **DEP-001**: `terraform/automation.tf` — `azurerm_automation_schedule.nightly_stop` resource block.
- **DEP-002**: Azure Automation Account `paa-dev-auto` — dev environment only; orphaned `morning_start` schedule and job-schedule link must be deleted before the Terraform apply in Phase 3b to avoid confusion about which schedule is authoritative.
- **DEP-003**: Terraform remote state for the dev environment — must be accessible before applying.
- **DEP-004**: `.github/workflows/terraform-dev.yml` — the `Start dev AKS cluster if stopped` step must run before any Terraform or kubectl step so that CI never operates against a stopped cluster.

## 5. Files

- **FILE-001**: `terraform/automation.tf` — modify `azurerm_automation_schedule.nightly_stop` block only (TASK-009).
- **FILE-002**: `scripts/start-dev-cluster.sh` — new script; idempotent AKS start with 10-minute polling timeout (TASK-006).
- **FILE-003**: `.github/workflows/terraform-dev.yml` — add `Start dev AKS cluster` step that calls `./scripts/start-dev-cluster.sh` after Azure Login (TASK-007).

## 6. Testing

- **TEST-001**: `terraform plan` output on the PR shows exactly the `nightly_stop` schedule replaced (and `stop_link` if cascaded). Zero other changes (TASK-012).
- **TEST-002**: Run `./scripts/start-dev-cluster.sh` locally with the cluster in `Stopped` state. Script polls and exits 0 when state reaches `Running`. Elapsed time is logged every 30 seconds (TASK-006).
- **TEST-003**: Run `./scripts/start-dev-cluster.sh` with the cluster already `Running`. Script logs `already Running` and exits 0 immediately without calling `az aks start` (TASK-006, idempotency).
- **TEST-004**: Open a PR against `dev` with the cluster `Stopped`. CI step `Start dev AKS cluster` calls the script; Terraform Plan begins only after the cluster is `Running` (TASK-007).
- **TEST-005**: Dev — next-morning Activity Log confirms `stop/action Succeeded` at ~04:00 UTC. No `start/action` from any Automation Account caller in the same window (TASK-014, TASK-016).
- **TEST-006**: Dev — `az aks show` confirms `powerState = Stopped` the morning after (TASK-015).
- **TEST-007**: Prod — Activity Log shows one `stop/action Succeeded` and one `start/action Succeeded` within the same business day, both from a human or SP caller (TASK-017, TASK-018).
- **TEST-008**: Prod — `az automation account list` returns empty for `paa-prod-rg`, confirming no automation infrastructure exists in prod (TASK-019).

## 7. Risks & Assumptions

- **RISK-001**: The `azurerm_automation_job_schedule.stop_link[0]` resource references the schedule by name. Recreating `nightly_stop` will invalidate the job-schedule link and Terraform should cascade the replacement. If CI plan shows stop_link unchanged, manually taint it: `terraform taint 'azurerm_automation_job_schedule.stop_link[0]'` before merging.
- **RISK-002**: The orphaned `morning_start` schedule in Azure may have a different exact name than `*-morning-start`. TASK-003 discovers the exact name before TASK-004/005 delete it.
- **RISK-003**: Time zone offset for `start_time`: MDT is UTC-6 (`-06:00`), MST is UTC-7 (`-07:00`). The `timezone = "America/Denver"` field tells Azure to apply DST automatically, so the offset in `start_time` only needs to be approximately correct at the time of resource creation — Azure normalizes it. Using `-06:00` (current MDT) is correct for creation in April–October.
- **RISK-004**: `az aks start --no-wait` returns immediately; the script polls `az aks show` every 30 seconds for up to 10 minutes. If the cluster reaches `Running` before the timeout, the script exits 0 and CI continues. On timeout, the script exits 1, failing the CI job with a clear error message.
- **RISK-005**: If the CI SP does not have the `Microsoft.ContainerService/managedClusters/start/action` permission on `paa-dev-aks`, the script will fail with an authorization error. The existing `azurerm_role_assignment.automation_aks_stop_start` grants this only to the Automation Account MI; the GitHub Actions SP may need a separate role assignment scoped to the dev cluster. Verify SP permissions before merging the PR.
- **ASSUMPTION-001**: The Automation Account name follows the `paa-dev-auto` or `paa-dev-<suffix>-auto` naming pattern from `local.name_prefix` in `terraform/locals.tf`.
- **ASSUMPTION-002**: The orphaned `morning_start` schedule is the cause of the concurrent start+stop race seen in the April 27 activity log. If TASK-003 finds no orphaned schedule, the concurrent actions had a different cause and the activity log should be inspected more carefully before proceeding.

## 8. Related Specifications / Further Reading

- [standalone-dev-cluster-stop-only-feature-1.md](standalone-dev-cluster-stop-only-feature-1.md) — superseded plan to remove morning_start from Terraform (resources already absent; Azure-side cleanup covered here)
- [../../terraform/automation.tf](../../terraform/automation.tf) — Terraform file modified by Phase 3b
- [../../scripts/start-dev-cluster.sh](../../scripts/start-dev-cluster.sh) — new script created by Phase 3a
- [../../.github/workflows/terraform-dev.yml](../../.github/workflows/terraform-dev.yml) — CI workflow modified by Phase 3a
- Azure Automation Schedules documentation: https://learn.microsoft.com/en-us/azure/automation/shared-resources/schedules
