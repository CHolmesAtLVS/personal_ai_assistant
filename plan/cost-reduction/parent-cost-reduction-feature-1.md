---
goal: Reduce Azure operational costs through dev cluster scheduling and Log Analytics optimization
plan_type: parent
version: 1.0
date_created: 2026-04-13
owner: CHolmesAtLVS
status: 'Planned'
tags: [cost, infrastructure, aks, logging, automation]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

Two targeted infrastructure changes to reduce ongoing Azure spend:

1. **Dev cluster nightly shutdown** — An Azure Automation Account with a PowerShell runbook stops the dev AKS cluster on a nightly schedule, eliminating compute costs during off-hours. A companion wake-up schedule restarts it each morning.
2. **Log Analytics cost reduction** — AKS diagnostic settings are trimmed to remove high-volume audit log categories, Log Analytics retention is reduced to the minimum (7 days), and a daily ingestion cap is applied to prevent unexpected spikes.

Neither change affects the `prod` environment. Each subplan is independently deployable via the existing Terraform CI/CD pipeline.

## 1. Requirements & Constraints

- **REQ-001**: Dev cluster shutdown must be performed via Azure Automation Account and PowerShell; no external schedulers.
- **REQ-002**: The Automation Account must use Managed Identity (System Assigned) for AKS interaction; no embedded credentials.
- **REQ-003**: Dev cluster stop/start automation must be scoped to the `dev` environment only; `prod` must be unaffected.
- **REQ-004**: Log Analytics changes must not eliminate all AKS observability; at minimum, API server and controller manager logs must be retained.
- **REQ-005**: All infrastructure changes must be delivered through Terraform; no manual portal changes.
- **SEC-001**: Automation Account identity must be granted least-privilege RBAC (stop/start action only, scoped to the AKS cluster resource).
- **CON-001**: AKS Free tier is in use; stop/start is supported on Free tier clusters.
- **CON-002**: Log Analytics minimum retention is 7 days; this is the floor for both changes.
- **CON-003**: Disabling the OMS Agent (Container Insights) entirely eliminates cluster-level metrics from Log Analytics; this is an acceptable trade-off for dev but must be called out explicitly.
- **GUD-001**: All new Terraform resources must follow existing `local.name_prefix` naming conventions and carry `local.common_tags`.
- **GUD-002**: Terraform changes must be environment-conditioned using `count` or variable-based guards to ensure `prod` is unaffected.

## 2. Subplans

| ID      | Subplan File                                                                                    | Goal                                                        | Status  |
| ------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------- | ------- |
| SUB-001 | [sub-001-dev-cluster-shutdown-feature-1.md](sub-001-dev-cluster-shutdown-feature-1.md)         | Nightly stop/morning start of dev AKS via Automation Runbook | Planned |
| SUB-002 | [sub-002-reduce-log-analytics-feature-1.md](sub-002-reduce-log-analytics-feature-1.md)         | Reduce AKS diagnostic log categories and LAW retention      | Planned |

## 3. Alternatives

- **ALT-001**: Use an Azure Logic App instead of Automation Account for scheduling. Rejected — Automation Account with PowerShell is a more direct fit for AKS stop/start and avoids additional connector licensing costs.
- **ALT-002**: Use Kubernetes node pool scaling (scale to 0) instead of cluster stop. Rejected — AKS stop/deallocate is the correct mechanism for full compute cost elimination; scaling to 0 still incurs control-plane and load-balancer charges.
- **ALT-003**: Disable the OMS Agent (Container Insights) entirely to eliminate the largest Log Analytics cost driver. Not chosen as the primary approach — removing specific high-volume log categories achieves most of the saving while retaining basic observability. Disabling Container Insights is documented as an optional follow-up step in SUB-002.
- **ALT-004**: Migrate Log Analytics workspace to a Commitment Tier pricing model. Rejected — current ingestion volume does not justify a commitment tier; per-GB pricing with reduced ingestion is more cost-effective at this scale.

## 4. Dependencies

- **DEP-001**: SUB-001 depends on the AKS cluster resource being fully defined in `terraform/aks.tf` — currently satisfied.
- **DEP-002**: SUB-001 requires `azurerm_role_assignment` to reference the AKS cluster resource ID, so `module.aks` must exist prior to automation resource creation.
- **DEP-003**: SUB-002 modifies `module.logging` (defined in `terraform/logging.tf`) and the `diagnostic_settings` block in `terraform/aks.tf`; no new modules required.

## 5. Execution Order

- **ORD-001**: SUB-001 and SUB-002 are fully independent and may be executed in parallel.
- **ORD-002**: Each subplan should be delivered as a separate PR targeting `dev` to keep changes reviewable in isolation.

## 6. Risks & Assumptions

- **RISK-001**: If the dev cluster is stopped while a developer is actively using it, their session will be interrupted with no warning. Mitigation: schedule stop at a low-traffic hour (e.g., 11 PM UTC); document the schedule in the repo README.
- **RISK-002**: Reducing Log Analytics retention to 7 days means historical diagnostic data older than 7 days is permanently deleted after the Terraform apply. Mitigation: accept and document this as a cost trade-off for dev.
- **RISK-003**: Removing `kube-audit` and `kube-audit-admin` log categories reduces security audit coverage for the dev cluster. Mitigation: acceptable for dev; prod diagnostic settings are unchanged.
- **ASSUMPTION-001**: The dev AKS cluster (`var.environment == "dev"`) is the only environment targeted by these changes.
- **ASSUMPTION-002**: Azure Automation Account basic SKU is sufficient; no Hybrid Worker or private endpoints are required.
- **ASSUMPTION-003**: The dev AKS node pool VMs are `Standard_B2s`; the PowerShell stop action targets the cluster, not individual nodes.

## 7. Related Specifications / Further Reading

- [../../ARCHITECTURE.md](../../ARCHITECTURE.md) — system architecture and shared infrastructure overview
- [../../terraform/aks.tf](../../terraform/aks.tf) — AKS cluster definition including OMS agent and diagnostic settings
- [../../terraform/logging.tf](../../terraform/logging.tf) — Log Analytics workspace definition
- [Azure AKS stop/start documentation](https://learn.microsoft.com/en-us/azure/aks/start-stop-cluster)
- [Azure Automation Account pricing](https://azure.microsoft.com/en-us/pricing/details/automation/)
- [Log Analytics pricing](https://azure.microsoft.com/en-us/pricing/details/monitor/)
