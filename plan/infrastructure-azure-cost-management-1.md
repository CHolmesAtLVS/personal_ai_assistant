---
goal: Implement Azure Cost Management budgets and alerting for OpenClaw
plan_type: standalone
version: 1.0
date_created: 2026-03-26
last_updated: 2026-03-26
owner: Platform Engineering
status: 'Planned'
tags: [infrastructure, terraform, azure, cost-management, budgets, alerting]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

This plan provisions Azure Cost Management resources for the OpenClaw deployment. It introduces a per-environment monthly budget scoped to the OpenClaw resource group, an Azure Monitor Action Group for email notification delivery, and four budget alert thresholds (50%, 80%, 100%, and 110% Forecasted overage). All resources are managed declaratively via Terraform using direct `azurerm_*` resources, as no Azure Verified Module (AVM) exists for consumption budgets at this time.

## 1. Requirements & Constraints

- **REQ-001**: Create a resource-group-scoped `azurerm_consumption_budget_resource_group` for each environment (dev, prod) with a configurable monthly `amount` in USD.
- **REQ-002**: Notify via email at 50% (Informational), 80% (Warning), and 100% (Actual) of the monthly budget threshold.
- **REQ-003**: Notify via email at 110% of the monthly budget threshold as a Forecasted overage alert.
- **REQ-004**: Create an `azurerm_monitor_action_group` to route budget notifications to a configurable email address.
- **REQ-005**: Add `monthly_budget_amount` and `budget_alert_email` variables to `terraform/variables.tf`.
- **REQ-006**: Add `budget_name` and `action_group_name` locals to `terraform/locals.tf`.
- **SEC-001**: Mark `budget_alert_email` as `sensitive = true`. Terraform's `sensitive` flag suppresses the value in `terraform plan` output, `terraform output`, and provider logs. The email address must never appear in any committed file — including source code, `.tfvars` files, `.tfvars.example` files, `backend.*.hcl` files, documentation, workflow files, or comments. No default value is permitted.
- **SEC-002**: Do not embed subscription IDs, resource group names, or tenant identifiers in plan or Terraform comments.
- **SEC-003**: Do not create any `.tfvars` or example file that contains or implies the `budget_alert_email` value. The sole authoritative store for this value is the GitHub Environment Secret `BUDGET_ALERT_EMAIL`. This secret is injected into Terraform via the `TF_VAR_budget_alert_email` environment variable configured in the GitHub Actions workflow; `-var-file` and `.tfvars`-based injection are not permitted.
- **CON-001**: Budget scope is the per-environment OpenClaw resource group (`${local.name_prefix}-rg`); subscription-wide budgets are out of scope.
- **CON-002**: No AVM module for `azurerm_consumption_budget_resource_group` exists; use the raw `azurerm` resource directly per ARCHITECTURE.md guidance.
- **CON-003**: The `cost_center` tag variable already exists in `terraform/variables.tf` and is applied via `local.common_tags`; no changes to tagging are required.
- **GUD-001**: New file `terraform/costs.tf` applies `tags = local.common_tags` to the Action Group resource. The Budget resource does not support tags directly.
- **GUD-002**: `monthly_budget_amount` must default to a safe, conservative value (25 USD) appropriate for a single-user personal deployment.
- **PAT-001**: All new cost management resources are isolated in `terraform/costs.tf`.

## 2. Implementation Steps

### Implementation Phase 1

- **GOAL-001**: Introduce Terraform variable and naming inputs required by cost management resources.

| Task     | Description                                                                                                                                                                                                   | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | Append `monthly_budget_amount` variable to `terraform/variables.tf`: type `number`, description `"Monthly USD budget cap for the OpenClaw resource group."`, default `25`, validation `> 0`.                 |           |      |
| TASK-002 | Append `budget_alert_email` variable to `terraform/variables.tf`: type `string`, description `"Email address for budget alert notifications. Must be injected via GitHub Secret; do not set a default or supply via a committed .tfvars file."`, `sensitive = true`, no default. The `sensitive = true` flag causes Terraform to redact the value in plan output, apply output, and `terraform output` calls. |           |      |
| TASK-003 | Append `budget_name` local (`"${local.name_prefix}-budget"`) and `action_group_name` local (`"${local.name_prefix}-ag-cost"`) to the resource name locals block in `terraform/locals.tf`.                    |           |      |

### Implementation Phase 2

- **GOAL-002**: Provision the Action Group and Budget resources in a dedicated Terraform file.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-004 | Create `terraform/costs.tf`. Add `azurerm_monitor_action_group` named `cost_alerts` with: `name = local.action_group_name`, `resource_group_name = module.resource_group.name`, `short_name = "cost-alerts"`, one `email_receiver` block using `name = "budget-notify"` and `email_address = var.budget_alert_email`, and `tags = local.common_tags`. Depends on `module.resource_group`.                                                                                                                                                        |           |      |
| TASK-005 | In `terraform/costs.tf`, add `azurerm_consumption_budget_resource_group` named `openclaw` with: `name = local.budget_name`, `resource_group_id = module.resource_group.resource_id`, `amount = var.monthly_budget_amount`, `time_grain = "Monthly"`, a `time_period` block with `start_date` set to a fixed first-day-of-month UTC timestamp (e.g. `"2026-04-01T00:00:00Z"`), and a `lifecycle` block with `ignore_changes = [time_period]` to prevent drift on re-apply (see RISK-001). Depends on `module.resource_group`.                              |           |      |
| TASK-006 | In the `azurerm_consumption_budget_resource_group` resource, add four `notification` blocks: (1) `operator = "GreaterThan"`, `threshold = 50`, `threshold_type = "Actual"`, `contact_groups = [azurerm_monitor_action_group.cost_alerts.id]`; (2) same with `threshold = 80`; (3) same with `threshold = 100`; (4) `operator = "GreaterThan"`, `threshold = 110`, `threshold_type = "Forecasted"`, `contact_groups = [azurerm_monitor_action_group.cost_alerts.id]`. |           |      |

### Implementation Phase 3

- **GOAL-003**: Propagate the new sensitive variable through CI/CD and validate the plan.

| Task     | Description                                                                                                                                                                                  | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-007 | Add `budget_alert_email` as a GitHub Secret named `BUDGET_ALERT_EMAIL` to both the `dev` and `prod` GitHub Environments via the GitHub UI or `gh secret set`. The secret must never be echoed, printed, or interpolated into a log line in the workflow. Confirm GitHub automatically masks the value in all workflow run logs. Do not store the value in any repository file, including `.env`, `.tfvars`, or documentation. |           |      |
| TASK-008 | Add `TF_VAR_budget_alert_email: ${{ secrets.BUDGET_ALERT_EMAIL }}` and `TF_VAR_monthly_budget_amount: ${{ vars.TF_VAR_MONTHLY_BUDGET_AMOUNT \|\| '25' }}` to the `env` block of both `dev` and `prod` jobs in the GitHub Actions workflow. Add `TF_VAR_MONTHLY_BUDGET_AMOUNT` as a GitHub Environment variable (non-secret) per environment. |           |      |
| TASK-009 | Run `terraform fmt` on `terraform/costs.tf`, `terraform/variables.tf`, and `terraform/locals.tf`. Run `terraform validate`. Confirm no errors.                                              |           |      |
| TASK-010 | Run `terraform plan` (dev environment). Confirm the plan shows exactly: one `azurerm_monitor_action_group` (create) and one `azurerm_consumption_budget_resource_group` (create). No other resource changes. |           |      |

## 3. Alternatives

- **ALT-001**: Subscription-level budget via `azurerm_consumption_budget_subscription`; rejected because the deployment is scoped to a resource group and a resource-group budget provides tighter, per-environment isolation.
- **ALT-002**: Azure Policy cost governance (e.g., Defender for Cloud cost recommendations); rejected as out of scope for a single-user personal deployment.
- **ALT-003**: Hard-code `start_date` to a static value (e.g., `"2026-04-01T00:00:00Z"`); noted as a lower-drift alternative to `timestamp()` — preferred if the deployment date is known. See RISK-001.
- **ALT-004**: Use an AVM pattern module (e.g., `Azure/avm-ptn-alz-*`); rejected because ALZ patterns are enterprise-scale and over-engineered for this workload.

## 4. Dependencies

- **DEP-001**: [plan/infrastructure-azure-foundation-1.md](infrastructure-azure-foundation-1.md) complete — `module.resource_group` must exist and export `.name` and `.resource_id`.
- **DEP-002**: `local.name_prefix` and `local.common_tags` must be defined in `terraform/locals.tf`.
- **DEP-003**: GitHub Actions Terraform workflow must support per-environment variable and secret injection (established in [plan/infrastructure-terraform-workflow-auth-1.md](infrastructure-terraform-workflow-auth-1.md)).

## 5. Files

- **FILE-001**: `terraform/costs.tf` — new file; contains `azurerm_monitor_action_group` and `azurerm_consumption_budget_resource_group`.
- **FILE-002**: `terraform/variables.tf` — append `monthly_budget_amount` and `budget_alert_email` variable blocks.
- **FILE-003**: `terraform/locals.tf` — append `budget_name` and `action_group_name` to resource name locals block.
- **FILE-004**: `.github/workflows/terraform-deploy.yml` — add secret/variable injection for `budget_alert_email` and `monthly_budget_amount`.

## 6. Testing

- **TEST-001**: `terraform validate` passes with no errors after all changes.
- **TEST-002**: `terraform plan` output shows exactly two new resources (`azurerm_monitor_action_group.cost_alerts` and `azurerm_consumption_budget_resource_group.openclaw`) and zero resource changes or destroys.
- **TEST-003**: After `terraform apply` in dev, verify in the Azure portal (Cost Management → Budgets) that the budget appears under the OpenClaw resource group with correct amount and four notification rules.
- **TEST-004**: Verify in Azure portal (Monitor → Action Groups) that the action group exists with the correct email receiver.
- **TEST-005**: Confirm `budget_alert_email` value is masked in GitHub Actions workflow run logs and does not appear in `terraform plan` output.
- **TEST-006**: Run `git log --all --full-diff -S "@" -- terraform/` and `git grep -r "@" -- terraform/` against the repository. Confirm zero results containing the alert email address. Run `terraform output budget_alert_email` and confirm Terraform returns `(sensitive value)` rather than the email address.

## 7. Risks & Assumptions

- **RISK-001**: `formatdate(..., timestamp())` in `start_date` evaluates at plan time, causing drift on subsequent `terraform plan`/`apply` runs (the date advances). Mitigation: use a static ISO-8601 date string (e.g., `"2026-04-01T00:00:00Z"`) for `start_date` and use `lifecycle { ignore_changes = [time_period] }` to prevent perpetual drift after initial creation.
- **RISK-002**: Azure budget notifications can have a delivery delay of up to 12 hours after threshold breach; this is an Azure platform limitation and cannot be resolved in Terraform.
- **RISK-003**: The `azurerm_consumption_budget_resource_group` resource requires the resource group to exist before the budget is created; if the resource group apply fails, the budget apply will also fail.
- **ASSUMPTION-001**: A single personal-deployment monthly budget of 25 USD is sufficient as a default. Each environment's `MONTHLY_BUDGET_AMOUNT` GitHub Environment variable should be set explicitly post-deployment.
- **ASSUMPTION-002**: The GitHub Actions workflow file already accepts per-step `-var` injection and does not use a `.tfvars` file exclusively.
- **ASSUMPTION-003**: The Azure subscription has the `Microsoft.Consumption` resource provider registered; it is registered by default on pay-as-you-go and most EA/MCA subscriptions.

## 8. Related Specifications / Further Reading

- [plan/infrastructure-azure-foundation-1.md](infrastructure-azure-foundation-1.md)
- [plan/infrastructure-terraform-workflow-auth-1.md](infrastructure-terraform-workflow-auth-1.md)
- [ARCHITECTURE.md](../ARCHITECTURE.md)
- [Azure Consumption Budget Terraform resource](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/consumption_budget_resource_group)
- [Azure Monitor Action Group Terraform resource](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_action_group)
