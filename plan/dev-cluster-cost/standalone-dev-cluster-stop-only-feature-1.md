---
goal: Remove automatic morning start for dev AKS cluster; stop-only schedule with manual start
plan_type: standalone
version: "1.0"
date_created: 2026-04-28
owner: Craig Holmes
status: 'Planned'
tags: [feature, cost, infrastructure, automation, dev]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

The dev AKS cluster currently auto-stops nightly and auto-starts each weekday morning. As a cost-saving measure, the auto-start schedule is being removed. The cluster will stay stopped indefinitely and must be started manually before any dev work. The stop runbook and schedule are retained unchanged. The start runbook is retained for convenient manual use (via Azure Portal or CLI) but is no longer linked to a schedule.

This plan covers the Terraform change, updated documentation, and a troubleshooting reference for working against a cluster that is stopped most of the time.

## 1. Requirements & Constraints

- **REQ-001**: The nightly stop schedule (`nightly_stop`, `stop_link`) must remain active and unchanged.
- **REQ-002**: The start runbook (`start_dev_cluster`) must be retained for manual triggering.
- **REQ-003**: The `morning_start` schedule resource and `start_link` job-schedule link must be removed from Terraform and from the Azure Automation Account.
- **REQ-004**: The `start-dev-cluster.ps1` script file is retained on disk — it is still used by the runbook.
- **REQ-005**: `readme.md` must be updated to reflect the new default state (cluster stopped; manual start required) and document how to start the cluster via CLI and Portal.
- **CON-001**: The `azurerm_automation_schedule.morning_start` resource and `azurerm_automation_job_schedule.start_link` block span `terraform/automation.tf` lines 106–143 approximately. Removing them is a clean Terraform change with no cascading dependencies.
- **CON-002**: Terraform `destroy` of `azurerm_automation_job_schedule` resources can be flaky in the AzureRM provider — confirm the state entry is removed cleanly after `terraform apply`.
- **GUD-001**: Target the dev environment only. Do not execute any commands against prod resources.
- **GUD-002**: Run `terraform plan` before `terraform apply` and confirm only the two resources (`azurerm_automation_schedule.morning_start[0]` and `azurerm_automation_job_schedule.start_link[0]`) are being destroyed.

## 2. Implementation Steps

### Phase 1 — Terraform Changes

- GOAL-001: Remove the auto-start schedule and job-schedule link from `terraform/automation.tf`. Retain all other resources unchanged.

| Task     | Description                                                                                                                                                                                                                                                                                                                  | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | In `terraform/automation.tf`, delete the entire `azurerm_automation_schedule.morning_start` resource block (the block starting at `resource "azurerm_automation_schedule" "morning_start"` through its closing `}`).                                                                                                         |           |      |
| TASK-002 | In `terraform/automation.tf`, delete the entire `azurerm_automation_job_schedule.start_link` resource block (the block starting at `resource "azurerm_automation_job_schedule" "start_link"` through its closing `}`). The `stop_link` job-schedule block must remain.                                                       |           |      |
| TASK-003 | Confirm no other resource in `terraform/` references `azurerm_automation_schedule.morning_start` or `azurerm_automation_job_schedule.start_link`. Run: `grep -r "morning_start\|start_link" terraform/` — expect zero results.                                                                                               |           |      |
| TASK-004 | Open a PR targeting `dev` with only the TASK-001 and TASK-002 changes. No other files should be modified in this PR.                                                                                                                                                                                                         |           |      |
| TASK-005 | After CI runs `terraform plan` on the PR, confirm the plan shows exactly two destroys: `azurerm_automation_schedule.morning_start[0]` and `azurerm_automation_job_schedule.start_link[0]`. No other changes.                                                                                                                 |           |      |
| TASK-006 | Merge the PR. CI applies `terraform apply` against dev. After apply, verify in the Azure Portal → Automation Account → Schedules that `*-morning-start` no longer exists, and under the start runbook's Schedules tab that no schedule is linked.                                                                            |           |      |

### Phase 2 — Documentation Updates

- GOAL-002: Update `readme.md` to reflect the stop-only schedule and document how to start the cluster manually.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                       | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-007 | In `readme.md`, update the **Dev Environment Schedule** section. Replace the existing schedule table and surrounding text with: the cluster now stops automatically each night but does **not** start automatically — it must be started manually before dev work. Retain the existing `az aks start / stop / show` command block and the Portal runbook note.      |           |      |
| TASK-008 | In `readme.md`, add a **Troubleshooting: Cluster Stopped** subsection (see Phase 3 for content) immediately below the manual start/stop commands. This ensures the troubleshooting steps are co-located with the operational guidance rather than in a separate document.                                                                                          |           |      |
| TASK-009 | In `docs/openclaw-aca-operations.md` (AKS Operations section), add a brief callout at the top of the AKS section noting the cluster is stopped by default and linking to the startup steps in `readme.md`.                                                                                                                                                        |           |      |

### Phase 3 — Troubleshooting Reference (Cluster-Stopped Runbook)

- GOAL-003: Provide a numbered, end-to-end procedure for recovering from a stopped cluster state. This content is written into `readme.md` per TASK-008.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-010 | Draft the **Troubleshooting: Cluster Stopped** content to be inserted into `readme.md`. The content must cover the following steps in order:<br><br>**Step 1 — Check cluster power state**<br>`az aks show --resource-group <dev-rg> --name <dev-cluster> --query powerState.code`<br>Expected output: `"Stopped"`. If `"Running"` — cluster is already up, skip to Step 3.<br><br>**Step 2 — Start the cluster**<br>Option A (CLI):<br>`az aks start --resource-group <dev-rg> --name <dev-cluster>`<br>This command blocks until the cluster is Running (~3–5 min). Re-run the `az aks show` query from Step 1 to confirm `"Running"`.<br>Option B (Portal): Azure Portal → Automation Account → Runbooks → `*-start-cluster` → Start → OK.<br><br>**Step 3 — Refresh kubeconfig**<br>After a cluster stop/start cycle, the kubeconfig token may be stale:<br>`az aks get-credentials --resource-group <dev-rg> --name <dev-cluster> --overwrite-existing`<br><br>**Step 4 — Wait for system pods**<br>AKS system pods (CoreDNS, kube-proxy, CSI driver, cert-manager, ArgoCD) may take ~2–3 minutes to become Ready after the nodes are up:<br>`kubectl get pods -A --field-selector=status.phase!=Running`<br>Re-run until output is empty (all pods Running).<br><br>**Step 5 — Check ArgoCD sync state**<br>A stop/start cycle does not trigger ArgoCD sync automatically:<br>`kubectl get applications -n argocd`<br>If any application shows `OutOfSync`, trigger a sync:<br>`kubectl -n argocd patch application <app-name> --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'`<br>Or use the ArgoCD UI via port-forward: `kubectl port-forward svc/argocd-server -n argocd 8080:80`<br><br>**Step 6 — Verify OpenClaw pods**<br>`kubectl get pods -A -l app.kubernetes.io/name=openclaw`<br>All pods should show `Running 1/1`. If a pod is in `CrashLoopBackOff` or `Pending`, check:<br>`kubectl describe pod -n openclaw-<inst> <pod-name>`<br>Common cause: CSI secret sync delay. Wait 60 s and check again. If still failing:<br>`kubectl rollout restart deployment/openclaw -n openclaw-<inst>`<br><br>**Step 7 — Reconnect local CLI**<br>`source <(./scripts/openclaw-connect.sh dev --export)`<br>`openclaw status --all`<br>`openclaw doctor` | |      |

## 3. Alternatives

- **ALT-001**: Keep the morning start but change its time or days — rejected; the goal is maximum cost reduction, so no automatic start.
- **ALT-002**: Disable the `morning_start` schedule (set `enabled = false`) instead of deleting it — not natively supported by the `azurerm_automation_schedule` resource; deleting is the correct approach.
- **ALT-003**: Delete the start runbook entirely and rely solely on `az aks start` CLI — rejected per user requirement; the runbook is retained for Portal-based manual starts.

## 4. Dependencies

- **DEP-001**: `terraform/automation.tf` — the two resources being removed and the remaining stop resources.
- **DEP-002**: `scripts/automation/start-dev-cluster.ps1` — retained unchanged; still referenced by the start runbook.
- **DEP-003**: Terraform remote state for the dev environment — must be accessible and up-to-date before applying.
- **DEP-004**: `readme.md` — needs content update in Phase 2.
- **DEP-005**: `docs/openclaw-aca-operations.md` — minor callout addition in Phase 2.

## 5. Files

- **FILE-001**: `terraform/automation.tf` — remove `azurerm_automation_schedule.morning_start` and `azurerm_automation_job_schedule.start_link` resource blocks.
- **FILE-002**: `scripts/automation/start-dev-cluster.ps1` — no changes; retained for manual runbook use.
- **FILE-003**: `scripts/automation/stop-dev-cluster.ps1` — no changes.
- **FILE-004**: `readme.md` — update Dev Environment Schedule section; add Troubleshooting: Cluster Stopped subsection.
- **FILE-005**: `docs/openclaw-aca-operations.md` — add stopped-by-default callout in the AKS Operations section.

## 6. Testing

- **TEST-001**: After `terraform apply`, run `az aks show --resource-group <dev-rg> --name <dev-cluster> --query powerState.code` — cluster should still be in its current power state (apply must not have started or stopped it).
- **TEST-002**: In the Azure Portal → Automation Account → Schedules, confirm `*-morning-start` schedule is gone. `*-nightly-stop` schedule must still exist.
- **TEST-003**: In the Azure Portal → Automation Account → Runbooks, confirm both `*-start-cluster` and `*-stop-cluster` runbooks still exist.
- **TEST-004**: Confirm the start runbook has no linked schedule (Portal → runbook → Schedules tab shows empty).
- **TEST-005**: Manually trigger the start runbook for a dev sanity check, confirm the cluster starts. Then manually stop it again via CLI or the stop runbook.
- **TEST-006**: Walk through the Phase 3 troubleshooting steps (TASK-010) end-to-end from a stopped cluster state to confirm all steps produce expected output and the cluster is fully operational at Step 7.

## 7. Risks & Assumptions

- **RISK-001**: Forgetting to start the cluster before a dev session. Mitigation: the `readme.md` troubleshooting section (TASK-008) and the error message from `kubectl` when the API server is unreachable makes the stopped state obvious.
- **RISK-002**: `azurerm_automation_job_schedule` destroy may leave a stale job link in Azure even after Terraform apply succeeds. Mitigation: verify in the Portal post-apply (TEST-004); if stale, delete manually via Portal and run `terraform import` or `terraform state rm` to reconcile.
- **RISK-003**: ArgoCD may attempt a sync immediately on cluster startup and fail if pods are not yet Ready, causing applications to show as degraded. Mitigation: Step 4–5 in the troubleshooting runbook explicitly waits for pods before checking ArgoCD state.
- **ASSUMPTION-001**: The dev cluster is currently stopped at the time this plan is executed, or will be stopped shortly after merge (nightly stop schedule fires daily).
- **ASSUMPTION-002**: No automated CI jobs or monitoring agents depend on the cluster being up during the morning window.

## 8. Related Specifications / Further Reading

- [terraform/automation.tf](../../terraform/automation.tf)
- [scripts/automation/start-dev-cluster.ps1](../../scripts/automation/start-dev-cluster.ps1)
- [scripts/automation/stop-dev-cluster.ps1](../../scripts/automation/stop-dev-cluster.ps1)
- [readme.md](../../readme.md)
- [docs/openclaw-aca-operations.md](../../docs/openclaw-aca-operations.md)
- [ARCHITECTURE.md](../../ARCHITECTURE.md) — Dev Environment Schedule section
