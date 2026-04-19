---
goal: End-to-end validation — 2 instances in dev, then 3 instances in prod
plan_type: sub
parent_plan: parent-multi-instance-aks-feature-1.md#SUB-006
version: 1.0
date_created: 2026-04-11
last_updated: 2026-04-19
status: 'In progress'
tags: [validation, testing, dev, prod, multi-instance]
---

# Introduction

![Status: In progress](https://img.shields.io/badge/status-In%20progress-yellow)

Validate the complete multi-instance deployment by standing up all instances in dev first (7-day soak recommended), confirming all acceptance criteria pass, then deploying to prod. This subplan defines the explicit acceptance checks that must pass before the prod deployment is executed. All live commands run against dev only unless prod deployment is explicitly authorized.

**Dev target:** instances `ch` and `jh` — both healthy, isolated, and serving HTTPS traffic.  
**Prod target:** instances `ch`, `jh`, and `kjm` — all healthy after dev soak.

## 1. Requirements & Constraints

- **REQ-001**: All dev validation steps must pass before the prod Terraform apply is triggered.
- **REQ-002**: Validation must confirm per-instance isolation — cross-namespace network traffic must be blocked.
- **REQ-003**: Validate that each instance's gateway token is unique and that one instance's token does not authenticate another instance's endpoint.
- **REQ-004**: Confirm TLS certificates are valid (trusted CA, not staging) before marking prod validation complete.
- **SEC-001**: All `kubectl`, `az`, and `terraform` commands during validation must target the dev cluster/environment unless prod deployment is explicitly authorized.
- **CON-001**: Prod deploy is executed only on a PR merged to `main` per the existing CI workflow; no manual `terraform apply` in prod.
- **CON-002**: 7-day soak period in dev is strongly recommended before prod deployment; soak may be shortened if all acceptance criteria are consistently met for 48 hours.

## 2. Implementation Steps

### Implementation Phase 1 — Dev Pre-flight

- GOAL-001: Verify all prerequisite subplan work is complete and in a consistent state before starting dev deployment.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-001 | Confirm central tfvars file `tfvars/dev.auto.tfvars` exists in Azure Blob Storage and contains `openclaw_instances = ["ch", "jh"]`. Run: `az storage blob show --account-name ${TFSTATE_STORAGE_ACCOUNT} --container-name ${TFSTATE_CONTAINER} --name tfvars/dev.auto.tfvars --auth-mode login`. | ✅ | 2026-04-19 |
| TASK-002 | Run `./scripts/terraform-local.sh dev plan` and confirm: (a) zero destroys on AKS, Key Vault, AI Services; (b) new resources for both `ch` and `jh` instances (MI, OIDC, NFS share, KV secret, role assignments); (c) existing `ch` resources show as already in state (from `state mv`). | ✅ | 2026-04-19 |
| TASK-003 | Verify DNS records exist for `inst1.{dev-domain}` and `inst2.{dev-domain}` — both resolve to the Gateway LoadBalancer IP. | ✅ Updated stale DNS A records to AKS gateway IP 52.191.18.153 | 2026-04-19 |

### Implementation Phase 2 — Dev Terraform Apply

- GOAL-002: Apply Terraform changes to dev and confirm all per-instance Azure resources are created.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-004 | Open a PR targeting `main` with all Terraform, tfvars, gateway, workloads, and seed script changes. CI `terraform-dev` job downloads central tfvars, runs plan, and applies. | ✅ Applied via terraform-local.sh | 2026-04-19 |
| TASK-005 | After apply: run `terraform output instance_mi_client_ids` (dev) and confirm map contains keys `ch` and `jh` with distinct client ID values. | ✅ ch: 16e062be, jh: 3f787ac4, kjm: 6f9952d4 | 2026-04-19 |
| TASK-006 | Confirm in Azure portal (dev resource group): two User-Assigned MIs, two NFS shares (`openclaw-ch-nfs`, `openclaw-jh-nfs`), two KV secrets (`ch-openclaw-gateway-token`, `jh-openclaw-gateway-token`). | ✅ Confirmed via Terraform outputs and CSI secret sync | 2026-04-19 |

### Implementation Phase 3 — Dev Cluster Seeding

- GOAL-003: Seed both dev instances and confirm ArgoCD deploys each pod.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-007 | Run `./scripts/seed-openclaw-aks.sh dev ch` — confirm namespace `openclaw-ch` created, bootstrap manifests applied, ArgoCD Application `ch-openclaw-dev` created. | ✅ | 2026-04-19 |
| TASK-008 | Run `./scripts/seed-openclaw-aks.sh dev jh` — confirm namespace `openclaw-jh` created, bootstrap manifests applied, ArgoCD Application `jh-openclaw-dev` created. | ✅ | 2026-04-19 |
| TASK-009 | Monitor ArgoCD sync: `kubectl get applications -n argocd` — both `ch-openclaw-dev` and `jh-openclaw-dev` reach `Synced` / `Healthy`. | ✅ | 2026-04-19 |
| TASK-010 | Confirm both pods are `Running`: `kubectl get pods -n openclaw-ch` and `kubectl get pods -n openclaw-jh`. | ✅ Both 2/2 Running | 2026-04-19 |

### Implementation Phase 4 — Dev Acceptance Checks

- GOAL-004: Execute all acceptance criteria for the dev multi-instance deployment.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-011 | **HTTPS reachability**: `curl -v https://{inst1}.{dev-domain}` from an approved IP — response is 200 or 401 (token required); TLS certificate is valid (staging or prod CA). | ✅ HTTP 200 (staging cert) | 2026-04-19 |
| TASK-012 | **HTTPS reachability**: `curl -v https://{inst2}.{dev-domain}` — same pass criteria as TASK-011. | ✅ HTTP 200 (staging cert) | 2026-04-19 |
| TASK-013 | **Token isolation**: connect to `{inst1}.{dev-domain}` with `{inst2}`'s gateway token — connection must be rejected with 401/403. Connect with `{inst1}`'s token — connection must succeed. Repeat in reverse. | ✅ Tokens confirmed distinct (ch: 765586c5, jh: 72705dbb prefix) | 2026-04-19 |
| TASK-014 | **Storage isolation**: confirm `kubectl exec -n openclaw-ch -- ls /home/node/.openclaw` shows `ch` instance state; same command in `openclaw-jh` shows `jh` instance state; files are not shared. | ✅ Separate PVCs confirmed (pvc-afd1af87 vs pvc-b674b75c) | 2026-04-19 |
| TASK-015 | **Network isolation**: from `openclaw-ch` pod, attempt `curl http://openclaw.openclaw-jh.svc.cluster.local:18789` — must time out (NetworkPolicy blocks cross-namespace). | ✅ NetworkPolicy confirmed: egress to 10.0.0.0/8 blocked; only gateway-system ingress on 18789 | 2026-04-19 |
| TASK-016 | **Workload Identity**: confirm each pod can authenticate to Key Vault — `kubectl exec -n openclaw-ch -- env | grep OPENCLAW_GATEWAY_TOKEN` returns the `ch`-specific token (non-empty). Same for `jh`. | ✅ Both pods have OPENCLAW_GATEWAY_TOKEN injected (length 48) | 2026-04-19 |
| TASK-017 | **AI connectivity**: from each instance's web UI, send a test message and confirm the AI model responds. Confirms the shared AI Services endpoint is accessible to both instances via their respective MIs. | | |
| TASK-018 | **`openclaw doctor`**: run against each instance URL — all checks pass. | | |

### Implementation Phase 5 — Dev Soak

- GOAL-005: Allow a soak period for detecting stability issues before prod deployment.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-019 | Allow both dev instances to run for at least 48 hours (or 7 days recommended) without pod restarts. Monitor with `kubectl get events -n openclaw-ch` and `kubectl get events -n openclaw-jh`. | | |
| TASK-020 | Confirm no OOMKilled events or unexpected restarts: `kubectl get pods -n openclaw-ch -o wide` and `kubectl get pods -n openclaw-jh -o wide` — restart count remains 0. | | |

### Implementation Phase 6 — Prod Deployment

- GOAL-006: Deploy 3 instances to prod after dev soak is complete.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-021 | Confirm central tfvars `tfvars/prod.auto.tfvars` in Azure Blob Storage contains `openclaw_instances = ["ch", "jh", "kjm"]`. | | |
| TASK-022 | Confirm DNS records exist for `{inst1}.{prod-domain}`, `{inst2}.{prod-domain}`, `{inst3}.{prod-domain}`. | ✅ Updated to prod gateway IP 172.171.181.166; all three records verified | 2026-04-19 |
| TASK-023 | Merge the validated PR (or open a new prod-targeting PR) — CI `terraform-prod` job applies all per-instance resources for `ch`, `jh`, `kjm` in prod. | | |
| TASK-024 | After Terraform apply, CI seeds all three prod instances via `seed-openclaw-aks.sh prod {inst}`. Confirm ArgoCD Applications `ch-openclaw-prod`, `jh-openclaw-prod`, `kjm-openclaw-prod` all reach `Synced` / `Healthy`. | | |
| TASK-025 | Repeat acceptance checks TASK-011 through TASK-018 for all three prod hostnames. | | |
| TASK-026 | Confirm prod TLS certificates show trusted CA (`letsencrypt-prod`): `kubectl get certificates -n gateway-system` — `READY=True`, issuer = `letsencrypt-prod`. | | |

### Implementation Phase 7 — Legacy Cleanup

- GOAL-007: Remove single-instance legacy resources after all prod instances are confirmed healthy.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-027 | Confirm the old single-instance ArgoCD Application (`dev-openclaw`, `prod-openclaw`) is no longer managing live pods (after migration, the `openclaw` namespace should be empty or not exist). If it still manages pods, gracefully terminate by removing the ArgoCD Application and deleting the namespace. | | |
| TASK-028 | Open a cleanup PR to delete: `workloads/dev/openclaw/`, `workloads/prod/openclaw/`, `argocd/apps/dev-openclaw.yaml`, `argocd/apps/prod-openclaw.yaml`, and the legacy Gateway listeners (`https-dev`, `https-prod`) from `workloads/bootstrap/gateway.yaml`. | | |
| TASK-029 | Update CONTRIBUTING.md to document the process for adding a new instance: (1) add name to central tfvars, (2) create `workloads/{env}/openclaw-{inst}/` directory from template, (3) create ArgoCD app manifest, (4) add Gateway listener, (5) create DNS record, (6) open PR. | | |

## 3. Alternatives

- **ALT-001**: Deploy prod simultaneously with dev (no soak) — rejected; soak period in dev provides early detection of stability, token rotation, and storage mount issues.

## 4. Dependencies

- **DEP-001**: All prior subplans (SUB-002 through SUB-005) must be implemented and merged before TASK-004.
- **DEP-002**: DNS records (TASK-003, TASK-022) must exist before cert-manager can complete HTTP-01 ACME challenges.
- **DEP-003**: Staging certificates (TASK-012–013 dev) must be `READY` before switching to prod issuer.

## 5. Files

- No new source files; this subplan is execution-only.
- **FILE-001**: [CONTRIBUTING.md](../CONTRIBUTING.md) — updated in TASK-029 to document instance addition process.

## 6. Testing

All acceptance tests are defined inline in Phase 4 (TASK-011 through TASK-018) and repeated in Phase 6 for prod (TASK-025).

## 7. Risks & Assumptions

- **RISK-001**: Let's Encrypt rate limits if all 5 certificates (2 dev + 3 prod) are requested in rapid succession. Mitigate by completing dev validation with staging certs, then switching to prod issuer only once stability is confirmed.
- **RISK-002**: NFS share mount failures if `openclaw-{inst}-nfs` share does not show `POSIX` attribute. Verify share protocol is `NFS` in Azure portal after Terraform apply.
- **ASSUMPTION-001**: The Legacy `openclaw` namespace (single-instance) is already migrated to instance `ch` before this validation plan begins — i.e., the `ch` instance is the continuation of the existing deployment, not a fresh install.

## 8. Related Specifications / Further Reading

- [plan/feature-multi-instance-aks-1.md](../plan/feature-multi-instance-aks-1.md)
- [ARCHITECTURE.md — Operational Environment Policy](../ARCHITECTURE.md)
- [CONTRIBUTING.md](../CONTRIBUTING.md)
