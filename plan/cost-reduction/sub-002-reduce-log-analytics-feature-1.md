---
goal: Reduce Log Analytics costs by trimming AKS diagnostic log categories, disabling Container Insights, and lowering workspace retention
plan_type: sub
parent_plan: parent-cost-reduction-feature-1.md#SUB-002
version: 1.0
date_created: 2026-04-13
owner: CHolmesAtLVS
status: 'Planned'
tags: [cost, logging, aks, log-analytics, diagnostics]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

AKS diagnostic settings currently ship five log categories to Log Analytics, including `kube-audit` and `kube-audit-admin` — the two highest-volume categories by far. This subplan removes those two categories from the AKS diagnostic settings block, disables the OMS Agent (Container Insights) add-on entirely to eliminate its ingestion volume, and retains the Log Analytics workspace at 30 days (the minimum enforced by the `avm-res-operationalinsights-workspace ~> 0.4` module). A daily ingestion cap (`daily_quota_gb`) is not yet implemented; it is tracked as a TODO in `logging.tf` pending a module version upgrade.

These changes apply to both `dev` and `prod` Terraform configurations, since Log Analytics costs accumulate in both environments.

## 1. Requirements & Constraints

- **REQ-001**: Remove `kube-audit` and `kube-audit-admin` from the AKS `diagnostic_settings.log_categories` list in `terraform/aks.tf`.
- **REQ-002**: Retain `kube-apiserver`, `kube-controller-manager`, and `kube-scheduler` log categories to preserve minimum operational observability.
- **REQ-003**: Disable the OMS Agent (`addon_profile_oms_agent`) on the AKS cluster to eliminate Container Insights ingestion entirely.
- **REQ-004**: Retain `log_analytics_workspace_retention_in_days` at `30` days in `terraform/logging.tf` — this is the minimum enforced by the AVM module `~> 0.4`. A lower value causes Terraform to fail at plan time.
- **REQ-005**: Track addition of a daily ingestion cap (`daily_quota_gb = 0.5`) as a follow-up TODO; blocked on upgrading `avm-res-operationalinsights-workspace` to a version that exposes this variable.
- **REQ-006**: All changes must be delivered via Terraform; no manual portal changes.
- **CON-001**: The `avm-res-operationalinsights-workspace ~> 0.4` module enforces a `retention_in_days` range of 30–730 days. Setting a value below 30 causes a Terraform plan error. The retention cannot be reduced below 30 days without a module upgrade.
- **CON-002**: Removing `kube-audit` and `kube-audit-admin` eliminates user and admin API server audit trails from Log Analytics. Security audit coverage for the cluster is reduced. This is a deliberate cost trade-off; document it explicitly.
- **CON-003**: Disabling the OMS Agent removes all Container Insights node/pod-level metrics and log streams from Log Analytics. Basic pod-level visibility via `kubectl` and ArgoCD remains available; Log Analytics metrics will no longer be available.
- **CON-004**: The `AllMetrics` metric category in the AKS diagnostic settings is also removed (TASK-002) as it is redundant once Container Insights is disabled.
- **GUD-001**: The `avm-res-operationalinsights-workspace` module must support `daily_quota_gb`; verify via the module's variable schema before applying.
- **GUD-002**: If `daily_quota_gb` is not exposed by the AVM module version in use, fall back to a `azurerm_monitor_diagnostic_setting` resource-level limit or accept the omission with a tracked follow-up.

## 2. Implementation Steps

### Implementation Phase 1 — Remove High-Volume AKS Log Categories

- GOAL-001: Eliminate `kube-audit`, `kube-audit-admin`, and `AllMetrics` from AKS diagnostic settings to reduce the largest single source of Log Analytics ingestion.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                     | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | Open `terraform/aks.tf`. In the `diagnostic_settings` block under `module "aks"`, locate the `log_categories` list: `["kube-apiserver", "kube-controller-manager", "kube-scheduler", "kube-audit", "kube-audit-admin"]`. Remove `"kube-audit"` and `"kube-audit-admin"` from the list. The resulting list must be `["kube-apiserver", "kube-controller-manager", "kube-scheduler"]`. |           |      |
| TASK-002 | In the same `diagnostic_settings` block in `terraform/aks.tf`, change `metric_categories = ["AllMetrics"]` to `metric_categories = []`. The `AllMetrics` stream is redundant now that Container Insights is being disabled entirely (TASK-003). |           |      |

### Implementation Phase 2 — Disable OMS Agent (Container Insights)

- GOAL-002: Remove the Container Insights add-on from the AKS cluster to eliminate its Log Analytics ingestion volume entirely.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                           | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-003 | Open `terraform/aks.tf`. Locate the `addon_profile_oms_agent` block: `addon_profile_oms_agent = { enabled = true, config = { log_analytics_workspace_resource_id = module.logging.resource_id } }`. Change `enabled` to `false` and remove the `config` nested block entirely. The resulting block must be: `addon_profile_oms_agent = { enabled = false }`. |           |      |

### Implementation Phase 3 — Reduce Log Analytics Workspace Retention and Add Cap

- GOAL-003: Reduce the Log Analytics workspace retention period to the minimum and apply a daily ingestion cap.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                           | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-004 | Open `terraform/logging.tf`. Change `log_analytics_workspace_retention_in_days = 30` to `log_analytics_workspace_retention_in_days = 7`.                                                                                                                                                                                                                                                             |           |      |
| TASK-005 | In `terraform/logging.tf`, check the `Azure/avm-res-operationalinsights-workspace/azurerm` module version `~> 0.4` for a `daily_quota_gb` or `workspace_daily_quota_gb` input variable. If present, add `daily_quota_gb = 0.5` (500 MB/day cap) to the `module "logging"` block. If not present, add a comment `# TODO: upgrade avm-res-operationalinsights-workspace to expose daily_quota_gb` and track as a follow-up. |           |      |

### Implementation Phase 4 — Validation

- GOAL-004: Confirm changes reduce Log Analytics ingestion without breaking deployments.

| Task     | Description                                                                                                                                                                                                                                                                                 | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-006 | Run `terraform plan -var-file=dev.tfvars` and confirm: (a) diagnostic settings show removal of `kube-audit` and `kube-audit-admin`, (b) OMS Agent `enabled` transitions to `false`, (c) `log_analytics_workspace_retention_in_days` changes from 30 to 7, (d) no destructive changes to the AKS cluster or node pools.                     |           |      |
| TASK-007 | Run `terraform plan -var-file=prod.tfvars` (read-only plan, do not apply during a troubleshooting session) and confirm the same changes are reflected for the prod environment without unexpected side effects.                                                                               |           |      |
| TASK-008 | After `terraform apply` on dev, open the Log Analytics workspace in Azure Portal → Logs → query `AzureDiagnostics \| where Category in ("kube-audit", "kube-audit-admin")` with a time range of 1 hour. Confirm zero rows are returned after the diagnostic setting update has taken effect. |           |      |
| TASK-009 | Confirm ArgoCD reconciliation loop is still healthy after the apply by running `kubectl get applications -n argocd` and verifying all applications show `Synced`/`Healthy`. Node/pod metrics will no longer appear in Log Analytics; this is expected and acceptable. |           |      |

## 3. Alternatives

- **ALT-001**: Disable `AllMetrics` from AKS diagnostic settings (implemented in TASK-002). This removes the redundant metrics stream routed to Log Analytics. Once Container Insights is disabled (TASK-003), this category serves no purpose.
- **ALT-002**: ~~Disable the OMS Agent (`addon_profile_oms_agent`) entirely~~ — **promoted to TASK-003 and now in scope**.
- **ALT-003**: Migrate the Log Analytics workspace to a Commitment Tier. Rejected — current ingestion volume after TASK-001 is expected to fall below 1 GB/day, which does not justify a commitment tier.
- **ALT-004**: Use Azure Monitor Data Collection Rules (DCR) to filter log streams at ingestion time rather than disabling categories entirely. More surgical but adds configuration complexity; out of scope for this plan.

## 4. Dependencies

- **DEP-001**: `module "aks"` in `terraform/aks.tf` uses the `Azure/avm-res-containerservice-managedcluster/azurerm` module `~> 0.5`. The `diagnostic_settings` input must support an empty or reduced `log_categories` list — verified by the module schema.
- **DEP-002**: `module "logging"` uses `Azure/avm-res-operationalinsights-workspace/azurerm` `~> 0.4`. The `daily_quota_gb` variable availability must be checked before TASK-004 is executed.

## 5. Files

- **FILE-001**: `terraform/aks.tf` — remove `kube-audit` and `kube-audit-admin` from `log_categories`; set `metric_categories = []`; disable OMS Agent (`addon_profile_oms_agent = { enabled = false }`).
- **FILE-002**: `terraform/logging.tf` — reduce retention to 7 days; add daily ingestion cap if supported by module version.

## 6. Testing

- **TEST-001**: `terraform plan` shows retention change (30 → 7), log category reduction, and OMS Agent `enabled = false` with no unintended resource replacements.
- **TEST-002**: Post-apply Log Analytics query confirms `kube-audit` and `kube-audit-admin` categories are no longer ingested.
- **TEST-003**: Post-apply Log Analytics query confirms Container Insights tables (`ContainerLog`, `KubePodInventory`, `Perf`) receive no new rows after the apply.
- **TEST-004**: ArgoCD applications remain `Synced`/`Healthy` after apply — confirms disabling the OMS Agent does not affect cluster operation.
- **TEST-005**: Azure Cost Management shows a measurable reduction in Log Analytics ingestion charges in the billing period following the apply.

## 7. Risks & Assumptions

- **RISK-001**: Removing `kube-audit` reduces the audit trail for API server access in dev. This is a deliberate trade-off; the security implication is accepted and documented. Prod security posture is unchanged (same Terraform applies but lower audit logging is also acceptable in prod if cost warrants).
- **RISK-002**: Reducing retention to 7 days immediately truncates historical log data older than 7 days. No rollback path for deleted log data. Mitigation: accept as part of the cost reduction trade-off.
- **RISK-003**: The daily ingestion cap (TASK-004) will cause Log Analytics to stop accepting data once the cap is reached. If the cap is set too low, it may suppress valid diagnostic information mid-day. Mitigation: set to 0.5 GB/day initially and adjust based on observed ingestion volume.
- **ASSUMPTION-001**: `kube-audit` and `kube-audit-admin` are the dominant contributors to Log Analytics ingestion costs for this cluster; this assumption should be verified post-apply using the Log Analytics Usage table (`_LogOperation` or `Usage | where Solution == "LogManagement"`).
- **ASSUMPTION-002**: Disabling Container Insights (OMS Agent) is acceptable for both dev and prod because `kubectl`, ArgoCD, and pod logs provide sufficient operational visibility for this workload's scale. If richer metrics are needed in future, Azure Managed Prometheus + Grafana is the preferred replacement (no Log Analytics dependency).

## 8. Related Specifications / Further Reading

- [parent-cost-reduction-feature-1.md](parent-cost-reduction-feature-1.md) — parent initiative
- [../../terraform/aks.tf](../../terraform/aks.tf) — AKS diagnostic settings (lines 82–97)
- [../../terraform/logging.tf](../../terraform/logging.tf) — Log Analytics workspace definition
- [AKS diagnostic settings reference](https://learn.microsoft.com/en-us/azure/aks/monitor-aks)
- [Log Analytics cost optimization](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/cost-logs)
