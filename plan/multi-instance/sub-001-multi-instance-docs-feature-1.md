---
goal: Update PRODUCT.md and ARCHITECTURE.md for multi-instance AKS model
plan_type: sub
parent_plan: parent-multi-instance-aks-feature-1.md#SUB-001
version: 1.0
date_created: 2026-04-11
last_updated: 2026-04-11
status: 'Completed'
tags: [docs, architecture, multi-instance]
---

# Introduction

![Status: Completed](https://img.shields.io/badge/status-Completed-brightgreen)

Update the two primary project documentation files to reflect the multi-instance AKS deployment model. Both files were updated as the first step of the parent initiative to ensure all subsequent implementation work is grounded in accurate documentation.

## 1. Requirements & Constraints

- **REQ-001**: PRODUCT.md must describe the multi-instance model, DNS naming convention, and per-instance user isolation.
- **REQ-002**: ARCHITECTURE.md must document per-instance vs. shared resources, central tfvars, reduced GitHub Secrets, and the updated deployment flow.
- **CON-001**: Do not expose Azure tenant, subscription, or DNS identifiers in documentation.
- **GUD-001**: Keep documentation aligned with the actual implementation design before any code is written.

## 2. Implementation Steps

### Implementation Phase 1

- GOAL-001: Update PRODUCT.md to reflect multi-instance product model.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-001 | Replace single "Primary User and Access Model" section with "Multi-Instance Model" section covering DNS naming pattern, per-instance isolation, and access constraints | ✅ | 2026-04-11 |
| TASK-002 | Update Layer 2 baseline table — per-instance gateway tokens, shared AI endpoint | ✅ | 2026-04-11 |
| TASK-003 | Rewrite Product Workflow to reference per-instance URLs and instance list management | ✅ | 2026-04-11 |
| TASK-004 | Update Roadmap — replace ACA decommission (complete) with multi-instance initiative | ✅ | 2026-04-11 |

### Implementation Phase 2

- GOAL-002: Update ARCHITECTURE.md to reflect multi-instance technical architecture.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-005 | Rewrite System Overview to describe shared cluster + isolated instances model | ✅ | 2026-04-11 |
| TASK-006 | Update Terraform Delivery Path — central tfvars download step, reduced GitHub Secrets table, per-instance seeding | ✅ | 2026-04-11 |
| TASK-007 | Rewrite Azure Runtime Platform — split into "Shared Infrastructure" and "Per-Instance Resources" with full isolation table | ✅ | 2026-04-11 |
| TASK-008 | Add Central Terraform Variables File section with blob path, format, and local script behavior | ✅ | 2026-04-11 |
| TASK-009 | Update Resource Group Topology section — remove single MI reference, add per-instance MI × N | ✅ | 2026-04-11 |
| TASK-010 | Update Resource Inventory table — mark per-instance resources with × N notation | ✅ | 2026-04-11 |
| TASK-011 | Update Terraform Outputs table — add `instance_mi_client_ids`, `instance_nfs_share_names`, `kv_name`; remove old single-instance outputs | ✅ | 2026-04-11 |
| TASK-012 | Rewrite End-to-End Deployment Flow — central tfvars download, per-instance Terraform apply, per-instance seeding | ✅ | 2026-04-11 |
| TASK-013 | Update Trust Boundaries — add cross-instance isolation statement | ✅ | 2026-04-11 |
| TASK-014 | Update Assumptions and Constraints — multi-instance DNS, shared AI endpoint, B2s capacity note | ✅ | 2026-04-11 |
| TASK-015 | Update Planned Evolution — per-instance backup, per-instance alerts | ✅ | 2026-04-11 |

## 3. Alternatives

- **ALT-001**: Update docs after implementation — rejected; accurate documentation before implementation reduces design drift.

## 4. Dependencies

- **DEP-001**: None — purely documentation changes.

## 5. Files

- **FILE-001**: [PRODUCT.md](../PRODUCT.md) — product description, multi-instance model, DNS naming
- **FILE-002**: [ARCHITECTURE.md](../ARCHITECTURE.md) — technical architecture, per-instance resources, central tfvars, GitHub Secrets

## 6. Testing

- **TEST-001**: Review PRODUCT.md and ARCHITECTURE.md for internal consistency — instance names, DNS patterns, and resource counts must match across both files and the parent plan.

## 7. Risks & Assumptions

- **ASSUMPTION-001**: Instance names `ch`, `jh` in dev; `ch`, `jh`, `kjm` in prod are confirmed and fixed for the validation phase.

## 8. Related Specifications / Further Reading

- [plan/feature-multi-instance-aks-1.md](../plan/feature-multi-instance-aks-1.md)
