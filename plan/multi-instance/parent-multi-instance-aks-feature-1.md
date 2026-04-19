---
goal: Multi-Instance OpenClaw on AKS — parent coordination plan
plan_type: parent
version: 1.1
date_created: 2026-04-11
status: 'In progress'
tags: [feature, architecture, aks, multi-instance, terraform, gitops]
---

# Introduction

![Status: In progress](https://img.shields.io/badge/status-In%20progress-yellow)

This initiative extends the OpenClaw AKS deployment to support **multiple isolated instances** on a shared cluster. Each instance serves a named individual (`ch`, `jh`, `kjm`) in their own Kubernetes namespace with dedicated persistent storage, managed identity, gateway token, and ingress hostname. All instances share the AKS cluster, AI Services endpoint, Key Vault container, and Log Analytics workspace to keep infrastructure costs proportional to active usage.

**Validation targets:**
- Dev: 2 instances — `ch`, `jh` → `ch.{dev-domain}`, `jh.{dev-domain}`
- Prod: 3 instances — `ch`, `jh`, `kjm` → `ch.{prod-domain}`, `jh.{prod-domain}`, `kjm.{prod-domain}`

**Supporting change:** Non-sensitive Terraform inputs move from GitHub Secrets/Variables to a central `.auto.tfvars` file stored in Azure Blob Storage alongside the Terraform state, significantly reducing the GitHub Secrets surface.

## 1. Requirements & Constraints

- **REQ-001**: Each instance must be isolated at the namespace, storage, identity, and secret levels; one instance pod cannot reach another instance's secrets or data.
- **REQ-002**: DNS pattern: `{instance}.{dev-domain}` (dev), `{instance}.{prod-domain}` (prod). Instance names are 2–3 lowercase letters.
- **REQ-003**: The authoritative instance list per environment lives in the central tfvars file in Azure Blob Storage. Adding an instance = one-line change + Terraform apply.
- **REQ-004**: AKS resource efficiency — all instances share one 2-node cluster; pod resource requests must be sized to fit safely on `Standard_B2s` nodes.
- **REQ-005**: GitHub Secrets must be reduced to credentials and true secrets only (≤ 11 entries per environment).
- **REQ-006**: `scripts/terraform-local.sh` must download the central tfvars file before running Terraform locally.
- **SEC-001**: No secret material in source control, Helm values, or pod environment at rest.
- **SEC-002**: Workload Identity (OIDC) required for all instance pods; no static credentials in pods.
- **SEC-003**: NetworkPolicy must block all cross-namespace pod traffic between `openclaw-*` namespaces.
- **CON-001**: AKS cluster remains `Standard_B2s` × 2 (free tier); no node changes in this initiative unless validation reveals insufficient headroom.
- **CON-002**: Single Key Vault per environment; per-instance secrets use `{inst}-` prefix.
- **CON-003**: Single AI Services endpoint per environment shared by all instances.
- **GUD-001**: Validate end-to-end with 2 instances in dev before applying prod (3 instances).

## 2. Subplans

| ID      | Subplan File | Goal | Status |
| ------- | ------------ | ---- | ------ |
| SUB-001 | [sub-001-multi-instance-docs-feature-1.md](sub-001-multi-instance-docs-feature-1.md) | Update PRODUCT.md and ARCHITECTURE.md | Completed |
| SUB-002 | [sub-002-multi-instance-tfvars-feature-1.md](sub-002-multi-instance-tfvars-feature-1.md) | Central tfvars in Blob Storage; reduce GitHub Secrets; update CI and terraform-local.sh | Complete |
| SUB-003 | [sub-003-multi-instance-terraform-feature-1.md](sub-003-multi-instance-terraform-feature-1.md) | Terraform per-instance resources via `for_each`; `openclaw_instances` variable | Complete |
| SUB-004 | [sub-004-multi-instance-gateway-feature-1.md](sub-004-multi-instance-gateway-feature-1.md) | Gateway per-instance HTTPS listeners, HTTPRoutes, TLS certificates | Completed |
| SUB-005 | [sub-005-multi-instance-workloads-feature-1.md](sub-005-multi-instance-workloads-feature-1.md) | Per-instance workloads directory, Helm values, ArgoCD apps, bootstrap manifests | Complete |
| SUB-006 | [sub-006-multi-instance-validation-feature-1.md](sub-006-multi-instance-validation-feature-1.md) | End-to-end validation: 2 instances in dev, 3 instances in prod | In progress |

## 3. Alternatives

- **ALT-001**: Wildcard DNS + wildcard TLS cert — avoids adding a Gateway listener per instance but requires DNS-01 ACME challenge. Rejected: adds external DNS provider dependency; HTTP-01 per hostname is simpler and already proven.
- **ALT-002**: One Managed Identity shared across all instances with multiple OIDC federation subjects — simpler Terraform but breaks per-instance blast radius isolation. Rejected: REQ-001 requires full identity isolation.
- **ALT-003**: One Key Vault per instance — maximum isolation but quadruples Key Vault cost and Terraform complexity. Rejected: prefix-namespaced secrets in a shared vault achieve the required isolation at lower cost.
- **ALT-004**: Keep all Terraform inputs in GitHub Secrets/Variables — simpler CI but exposes non-secret config as environment-level secrets, does not scale as instance list grows. Rejected: REQ-005 requires significant reduction.

## 4. Dependencies

- **DEP-001**: AKS cluster is online and ArgoCD is installed (prerequisite — already in place).
- **DEP-002**: Terraform state backend storage account exists and is accessible (prerequisite — already in place).
- **DEP-003**: SUB-002 (central tfvars) must be bootstrapped before SUB-003 (Terraform apply) in CI.
- **DEP-004**: SUB-003 (Terraform) must complete before SUB-005 (workloads seeding) — per-instance MI client IDs and NFS share names come from Terraform outputs.
- **DEP-005**: SUB-004 (Gateway) must be applied before SUB-006 (validation) — HTTPS listeners must exist for cert-manager to issue certificates.

## 5. Execution Order

- **ORD-001**: SUB-001 (docs) is complete; may proceed immediately.
- **ORD-002**: SUB-002 (tfvars) must complete before SUB-003 (Terraform) and before CI workflow is updated.
- **ORD-003**: SUB-003 (Terraform) and SUB-004 (Gateway) and SUB-005 (Workloads) may be developed in parallel but must be applied in order: Terraform → Gateway → Workloads.
- **ORD-004**: SUB-006 (validation) runs last, after all prior subplans are applied to dev.

## 6. Risks & Assumptions

- **RISK-001**: Migrating from single-instance to `for_each` in Terraform will require a `terraform state mv` for the existing single-instance resources to avoid destroy/recreate of the live AKS cluster, Key Vault, and NFS share.
- **RISK-002**: Gateway listener count growth (5 listeners for 3-instance prod) is within NGINX Gateway Fabric limits but should be confirmed during validation.
- **RISK-003**: Let's Encrypt rate limits — issuing 5 certificates simultaneously may hit staging/prod rate limits; stagger certificate requests if needed.
- **ASSUMPTION-001**: The existing `ch` instance uses the current single-instance resources. The Terraform `state mv` plan in SUB-003 addresses continuity for this instance.
- **ASSUMPTION-002**: `Standard_B2s` nodes have sufficient headroom for 3 prod instances at `100m CPU / 256Mi memory` requests each (total: ~300m CPU, ~768Mi memory across the pod set; well within 4 vCPU / 8 GB cluster capacity).

## 7. Related Specifications / Further Reading

- [ARCHITECTURE.md](../ARCHITECTURE.md)
- [PRODUCT.md](../PRODUCT.md)
- [plan/feature-multi-instance-docs-1.md](../plan/feature-multi-instance-docs-1.md)
- [plan/feature-multi-instance-tfvars-1.md](../plan/feature-multi-instance-tfvars-1.md)
- [plan/feature-multi-instance-terraform-1.md](../plan/feature-multi-instance-terraform-1.md)
- [plan/feature-multi-instance-gateway-1.md](../plan/feature-multi-instance-gateway-1.md)
- [plan/feature-multi-instance-workloads-1.md](../plan/feature-multi-instance-workloads-1.md)
- [plan/feature-multi-instance-validation-1.md](../plan/feature-multi-instance-validation-1.md)
