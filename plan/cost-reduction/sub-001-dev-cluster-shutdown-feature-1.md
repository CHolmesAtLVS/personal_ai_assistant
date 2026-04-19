---
goal: Stop the dev AKS cluster nightly and restart each morning using Azure Automation
plan_type: sub
parent_plan: parent-cost-reduction-feature-1.md#SUB-001
version: 1.0
date_created: 2026-04-13
owner: CHolmesAtLVS
status: 'Completed'
tags: [cost, aks, automation, scheduling, dev]
---

# Introduction

![Status: Completed](https://img.shields.io/badge/status-Completed-brightgreen)

Creates an Azure Automation Account (dev environment only) with a System Assigned Managed Identity, two PowerShell runbooks (stop and start), and two schedules. The stop schedule fires nightly at 02:00 Mountain Time (America/Denver); the start schedule fires at 07:00 Mountain Time Monday–Friday. RBAC restricts the Automation Account identity to the minimum permissions needed to stop and start the AKS cluster. All Terraform resources are gated on `var.environment == "dev"` so `prod` is never affected.

The dev desktop Windows VM is no longer managed by Terraform (state removed). Its nightly shutdown must be configured manually via Windows Task Scheduler to align with the 02:00 Mountain Time cluster stop.

## 1. Requirements & Constraints

- **REQ-001**: Use Azure Automation Account with System Assigned Managed Identity. No embedded credentials.
- **REQ-002**: Stop runbook executes at 02:00 Mountain Time (timezone: `America/Denver`) every day. Start runbook executes at 07:00 Mountain Time Monday–Friday only (weekends left down). Using the IANA timezone ID allows Azure Automation to honour DST transitions automatically; no manual UTC offset recalculation is required seasonally.
- **REQ-003**: RBAC grant must use a custom role limited to `Microsoft.ContainerService/managedClusters/stop/action` and `Microsoft.ContainerService/managedClusters/start/action`, scoped to the AKS resource only.
- **REQ-004**: All resources conditioned on `var.environment == "dev"` using Terraform `count = var.environment == "dev" ? 1 : 0`.
- **REQ-005**: Automation Account uses `Basic` SKU. No Hybrid Worker required.
- **REQ-006**: PowerShell runbook uses `Az.Aks` module and authenticates via `Connect-AzAccount -Identity`.
- **SEC-001**: Role assignment scoped to the specific AKS cluster resource ID, not the resource group.
- **CON-001**: Azure Automation free tier includes 500 job minutes/month; this schedule generates ~60 jobs/month — within free quota. No additional Automation cost expected.
- **CON-002**: AKS cluster stop/start is not instantaneous. The runbook should not be treated as a hard SLA action.
- **GUD-001**: Terraform resource naming must follow `${local.name_prefix}-*` convention.
- **REQ-007**: The dev desktop Windows VM shutdown must be configured as a Windows Task Scheduler task on the VM itself (manual one-time setup) set to `02:00` Mountain Time daily, since the VM is no longer managed by Terraform.
- **GUD-002**: All Terraform resources must carry `local.common_tags`.

## 2. Implementation Steps

### Implementation Phase 1 — Terraform: Custom Role and Automation Account

- GOAL-001: Define a custom RBAC role for AKS stop/start and create the Automation Account with Managed Identity.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                    | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-001 | Create `terraform/automation.tf`. Add `azurerm_automation_account` resource named `"dev_cluster_scheduler"` with `name = "${local.name_prefix}-auto"`, `location = var.location`, `resource_group_name = module.resource_group.name`, `sku_name = "Basic"`, `identity { type = "SystemAssigned" }`, `tags = local.common_tags`, and `count = var.environment == "dev" ? 1 : 0`. | ✅ | 2026-04-13 |
| TASK-002 | In `terraform/automation.tf`, add `azurerm_role_definition` resource named `"aks_stop_start"` with `count = var.environment == "dev" ? 1 : 0`. Set `name = "${local.name_prefix}-aks-stop-start"`, `scope = module.aks.resource_id`, and `permissions { actions = ["Microsoft.ContainerService/managedClusters/stop/action", "Microsoft.ContainerService/managedClusters/start/action", "Microsoft.ContainerService/managedClusters/read"] }`.  | ✅ | 2026-04-13 |
| TASK-003 | In `terraform/automation.tf`, add `azurerm_role_assignment` resource named `"automation_aks_stop_start"` with `count = var.environment == "dev" ? 1 : 0`. Set `scope = module.aks.resource_id`, `role_definition_id = azurerm_role_definition.aks_stop_start[0].role_definition_resource_id`, `principal_id = azurerm_automation_account.dev_cluster_scheduler[0].identity[0].principal_id`. Add `depends_on = [azurerm_automation_account.dev_cluster_scheduler]`. | ✅ | 2026-04-13 |

### Implementation Phase 2 — PowerShell Runbooks

- GOAL-002: Create the stop and start PowerShell runbook source files and register them as Automation runbooks in Terraform.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-004 | Create `scripts/automation/stop-dev-cluster.ps1`. Content: `Connect-AzAccount -Identity; $rg = Get-AutomationVariable -Name 'AKS_RESOURCE_GROUP'; $name = Get-AutomationVariable -Name 'AKS_CLUSTER_NAME'; Write-Output "Stopping AKS cluster $name in $rg"; Stop-AzAksCluster -ResourceGroupName $rg -Name $name -Force`. Values are read from Automation Account variables via `Get-AutomationVariable` (Automation variables are **not** auto-injected as `$env:` environment variables). | ✅ Note: `-Force` removed — not supported in installed Az.Aks module version | 2026-04-19 |
| TASK-005 | Create `scripts/automation/start-dev-cluster.ps1`. Content: `Connect-AzAccount -Identity; $rg = Get-AutomationVariable -Name 'AKS_RESOURCE_GROUP'; $name = Get-AutomationVariable -Name 'AKS_CLUSTER_NAME'; Write-Output "Starting AKS cluster $name in $rg"; Start-AzAksCluster -ResourceGroupName $rg -Name $name`. Values are read via `Get-AutomationVariable` (not `$env:`). | ✅ | 2026-04-13 |
| TASK-006 | In `terraform/automation.tf`, add two `azurerm_automation_variable_string` resources (both with `count = var.environment == "dev" ? 1 : 0`): `"aks_rg"` with `name = "AKS_RESOURCE_GROUP"` and `value = module.resource_group.name`; `"aks_cluster_name"` with `name = "AKS_CLUSTER_NAME"` and `value = module.aks.resource.name`. Set `automation_account_name = azurerm_automation_account.dev_cluster_scheduler[0].name` and `resource_group_name = module.resource_group.name` on both.                             | ✅ | 2026-04-13 |
| TASK-007 | In `terraform/automation.tf`, add `azurerm_automation_runbook` resource named `"stop_dev_cluster"` with `count = var.environment == "dev" ? 1 : 0`. Set `name = "${local.name_prefix}-stop-cluster"`, `automation_account_name = azurerm_automation_account.dev_cluster_scheduler[0].name`, `resource_group_name = module.resource_group.name`, `location = var.location`, `runbook_type = "PowerShell"`, `log_verbose = false`, `log_progress = false`, `content = file("${path.module}/../scripts/automation/stop-dev-cluster.ps1")`, `tags = local.common_tags`. | ✅ | 2026-04-13 |
| TASK-008 | In `terraform/automation.tf`, add `azurerm_automation_runbook` resource named `"start_dev_cluster"` with identical structure to TASK-007, using name `"${local.name_prefix}-start-cluster"` and `content = file("${path.module}/../scripts/automation/start-dev-cluster.ps1")`. | ✅ | 2026-04-13 |

### Implementation Phase 3 — Schedules and Job Schedule Links

- GOAL-003: Create nightly stop and weekday morning start schedules and link them to their respective runbooks.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                        | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-009 | In `terraform/automation.tf`, add `azurerm_automation_schedule` resource named `"nightly_stop"` with `count = var.environment == "dev" ? 1 : 0`. Set `name = "${local.name_prefix}-nightly-stop"`, `automation_account_name = azurerm_automation_account.dev_cluster_scheduler[0].name`, `resource_group_name = module.resource_group.name`, `frequency = "Day"`, `interval = 1`, `timezone = "America/Denver"`, `start_time = "2026-04-15T02:00:00-06:00"` (use the next calendar day's 02:00 Mountain Time at time of apply; the offset is `-06:00` during MDT or `-07:00` during MST). | ✅ | 2026-04-13 |
| TASK-010 | In `terraform/automation.tf`, add `azurerm_automation_schedule` resource named `"morning_start"` with `count = var.environment == "dev" ? 1 : 0`. Set `frequency = "Week"`, `interval = 1`, `timezone = "America/Denver"`, `start_time = "2026-04-15T07:00:00-06:00"`, `week_days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]`.                                                                                               | ✅ | 2026-04-13 |
| TASK-011 | In `terraform/automation.tf`, add `azurerm_automation_job_schedule` resource named `"stop_link"` with `count = var.environment == "dev" ? 1 : 0`. Set `automation_account_name`, `resource_group_name`, `runbook_name = azurerm_automation_runbook.stop_dev_cluster[0].name`, `schedule_name = azurerm_automation_schedule.nightly_stop[0].name`.                                                                                   | ✅ | 2026-04-13 |
| TASK-012 | In `terraform/automation.tf`, add `azurerm_automation_job_schedule` resource named `"start_link"` with `count = var.environment == "dev" ? 1 : 0`. Set `runbook_name = azurerm_automation_runbook.start_dev_cluster[0].name`, `schedule_name = azurerm_automation_schedule.morning_start[0].name`.                                                                                                                                 | ✅ | 2026-04-13 |

### Implementation Phase 4 — Validation and Documentation

- GOAL-004: Verify schedules are registered and document the schedule in the repository README.

| Task     | Description                                                                                                                                                                                                                         | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-013 | Run `terraform plan -var-file=dev.tfvars` targeting the dev environment and verify the plan creates the Automation Account, custom role, role assignment, 2 runbooks, 2 schedules, and 2 job schedule links with no errors.          | ✅ | 2026-04-13 |
| TASK-014 | After `terraform apply`, manually trigger the stop runbook from the Azure Portal for the dev Automation Account and confirm the AKS cluster reaches `Stopped` state within 5 minutes.                                               | ✅ Cluster reached `Stopped/Succeeded` | 2026-04-19 |
| TASK-015 | Manually trigger the start runbook and confirm AKS cluster returns to `Running` state and all ArgoCD-managed workloads reconcile successfully.                                                                                       | ✅ Cluster returned to `Running/Succeeded`; ch-openclaw-dev and jh-openclaw-dev both Synced/Healthy | 2026-04-19 |
| TASK-016 | Add a note to `readme.md` under a "Dev Environment Schedule" section documenting that the dev cluster stops at 02:00 Mountain Time (America/Denver) daily and restarts at 07:00 Mountain Time Monday–Friday. Include instructions for manually triggering start/stop via the Azure Portal or az CLI (`az aks start` / `az aks stop`). | ✅ Already present in readme.md | 2026-04-19 |
| TASK-017 | On the dev desktop Windows VM, create a Windows Task Scheduler task (one-time manual step — not Terraform-managed): Action = `shutdown /s /t 60 /c "Nightly scheduled shutdown"`, Trigger = Daily at 02:00, run whether user is logged on or not. Document this step in `readme.md` alongside the cluster schedule note added in TASK-016. Note: the VM is not in Terraform state (`terraform/windowsvm.tf` is a tombstone comment) so this cannot be automated via Terraform. | ✅ Documented in readme.md (manual operator step) | 2026-04-19 |

## 3. Alternatives

- **ALT-001**: Use a GitHub Actions scheduled workflow (`cron`) to run `az aks stop/start`. Rejected — introduces a dependency on GitHub Actions availability for infrastructure operations; Automation Account is self-contained in Azure.
- **ALT-002**: Use AKS node pool auto-scaling to scale to 0 at night. Rejected — scaling to 0 does not fully deallocate VMs; cluster stop/deallocate achieves full compute cost elimination.
- **ALT-003**: Stop only the workload node pool, leaving the system pool running. Rejected — AKS cluster-level stop deallocates all nodes and is the correct mechanism; stopping individual pools does not eliminate all VM costs.

## 4. Dependencies

- **DEP-001**: `module.aks` must expose `resource_id` and `resource.name` outputs — verified in existing `terraform/aks.tf`.
- **DEP-002**: `module.resource_group` must expose `.name` and `.resource_id` — verified in existing `terraform/main.tf`.
- **DEP-003**: PowerShell `Az.Aks` cmdlets (`Stop-AzAksCluster`, `Start-AzAksCluster`) must be available in the Automation Account runtime environment. Automation Account PowerShell 7.2 runtime includes `Az.Aks` by default; no module import step is required.

## 5. Files

- **FILE-001**: `terraform/automation.tf` — new file containing all Automation Account, role, runbook, schedule, and job schedule resources.
- **FILE-002**: `scripts/automation/stop-dev-cluster.ps1` — PowerShell runbook source for cluster stop.
- **FILE-003**: `scripts/automation/start-dev-cluster.ps1` — PowerShell runbook source for cluster start.
- **FILE-004**: `readme.md` — updated to document the dev cluster schedule and dev desktop manual shutdown instructions.

## 6. Testing

- **TEST-001**: `terraform plan` produces expected resource additions with zero errors and zero destructive changes to existing resources.
- **TEST-002**: Manual trigger of stop runbook results in AKS cluster status transitioning to `Stopped` (verify with `az aks show --query powerState.code`).
- **TEST-003**: Manual trigger of start runbook results in AKS cluster status transitioning to `Running` and all pods reaching `Running` state.
- **TEST-004**: After one full scheduled cycle (next day), confirm Azure Automation job history shows successful stop and start job executions with no errors.
- **TEST-005**: Confirm no Automation Account or runbook resources are created in the `prod` environment by running `terraform plan -var-file=prod.tfvars` and verifying resource count is zero for automation-related resources.

## 7. Risks & Assumptions

- **RISK-001**: If the cluster is stopped at 02:00 Mountain Time while a developer is mid-session, their work is not lost (persistent volumes are preserved) but the session is interrupted. Mitigation: document the schedule prominently; provide `az aks start` instructions.
- **RISK-004**: The dev desktop Windows VM shutdown is a manual Task Scheduler configuration. If the VM is reimaged or the task is lost, the shutdown will no longer occur and must be reconfigured manually. Mitigation: document the setup steps in `readme.md`.
- **RISK-005**: A Windows shutdown via Task Scheduler will forcibly close open applications at 02:00 if the user is logged in. Mitigation: the 60-second countdown (`/t 60`) gives a brief warning; developers should save work before 02:00.
- **RISK-002**: The `start_time` seed value for the Automation Schedule is a static string. If Terraform is not applied before that time, the schedule start_time will be in the past and Terraform may reject it. Mitigation: update to a future date when applying or use a `time_offset` data source for a dynamic value.
- **RISK-003**: ArgoCD and cert-manager pods will not reconcile until the cluster is restarted. If any config drift occurs overnight, it will be resolved at 07:00 Mountain Time on weekdays.
- **ASSUMPTION-001**: Weekends are non-working days for all users of the dev environment; the cluster may remain stopped Sat/Sun.
- **ASSUMPTION-002**: Azure Automation Account Basic SKU free job minutes (500/month) are not exceeded by ~60 jobs/month.
- **ASSUMPTION-003**: `module.aks` references the AKS resource such that `module.aks.resource_id` resolves to the full ARM resource ID.

## 8. Related Specifications / Further Reading

- [parent-cost-reduction-feature-1.md](parent-cost-reduction-feature-1.md) — parent initiative
- [../../terraform/aks.tf](../../terraform/aks.tf) — AKS cluster Terraform definition
- [Azure AKS stop/start cluster](https://learn.microsoft.com/en-us/azure/aks/start-stop-cluster)
- [azurerm_automation_account Terraform resource](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/automation_account)
- [azurerm_automation_runbook Terraform resource](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/automation_runbook)
