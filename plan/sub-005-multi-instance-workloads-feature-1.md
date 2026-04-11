---
goal: Per-instance workloads directory, Helm values, ArgoCD apps, and bootstrap manifests
plan_type: sub
parent_plan: parent-multi-instance-aks-feature-1.md#SUB-005
version: 1.0
date_created: 2026-04-11
last_updated: 2026-04-11
status: 'Planned'
tags: [kubernetes, argocd, helm, gitops, multi-instance]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

Create per-instance workload directories and ArgoCD Application manifests for each OpenClaw instance in each environment. The existing single-instance `workloads/{env}/openclaw/` structure is cloned into `workloads/{env}/openclaw-{inst}/` with instance-specific values. Bootstrap manifests (`serviceaccount.yaml`, `secretproviderclass.yaml`, `configmap.yaml`) are updated to reference per-instance resource names. `scripts/seed-openclaw-aks.sh` is extended to accept an instance parameter and iterate over all instances.

**Dev instances:** `ch`, `jh`  
**Prod instances:** `ch`, `jh`, `kjm`

## 1. Requirements & Constraints

- **REQ-001**: Each instance's workload lives in `workloads/{env}/openclaw-{inst}/` — independent Chart.yaml, values.yaml, bootstrap/ directory, and crds/ directory.
- **REQ-002**: Each instance's `serviceaccount.yaml` uses `${OPENCLAW_MI_CLIENT_ID}` sourced from the per-instance MI (Terraform output `instance_mi_client_ids[inst]`).
- **REQ-003**: Each instance's `secretproviderclass.yaml` syncs `{inst}-openclaw-gateway-token` (not the old shared name) and `azure-ai-api-key` from the shared Key Vault.
- **REQ-004**: Each instance's `configmap.yaml` sets `APP_FQDN` to `{inst}-paa-dev.acmeadventure.ca` (dev) or `{inst}-paa.acmeadventure.ca` (prod).
- **REQ-005**: Each instance's Helm `values.yaml` references the instance-specific NFS share name (`openclaw-{inst}-nfs`) in the PV configuration.
- **REQ-006**: Each ArgoCD Application manifest (`argocd/apps/{env}-openclaw-{inst}.yaml`) tracks `workloads/{env}/openclaw-{inst}/` with `configMode: merge` and appropriate `ignoreDifferences` for the ConfigMap.
- **REQ-007**: `scripts/seed-openclaw-aks.sh` must accept an instance name as a second parameter and apply the correct `workloads/{env}/openclaw-{inst}/bootstrap/` directory. It must also support iterating over all instances in the environment.
- **SEC-001**: NetworkPolicy in each instance namespace: ingress from `gateway-system` namespace only on port 18789; no egress to other `openclaw-*` namespaces; allow egress to internet.
- **CON-001**: Pod resource requests: `cpu: 100m`, `memory: 256Mi`; limits: `cpu: 500m`, `memory: 512Mi`. Set in Helm values per instance.
- **CON-002**: All `${VAR}` placeholders in bootstrap manifests are preserved as-is in Git; `envsubst` is applied only at seed time by `seed-openclaw-aks.sh`.

## 2. Implementation Steps

### Implementation Phase 1 — Dev Instance Directories

- GOAL-001: Create `workloads/dev/openclaw-ch/` and `workloads/dev/openclaw-jh/` with all required files.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-001 | Create `workloads/dev/openclaw-ch/Chart.yaml` — copy from `workloads/dev/openclaw/Chart.yaml`; update `name: openclaw-ch`. | | |
| TASK-002 | Create `workloads/dev/openclaw-ch/values.yaml` — copy from `workloads/dev/openclaw/values.yaml`; update `openclawVersion` as needed; update the PV share name to `openclaw-ch-nfs`; update `APP_FQDN` to `ch-paa-dev.acmeadventure.ca`. Set `resources.requests: {cpu: 100m, memory: 256Mi}` and `resources.limits: {cpu: 500m, memory: 512Mi}`. | | |
| TASK-003 | Create `workloads/dev/openclaw-ch/bootstrap/serviceaccount.yaml` — copy from existing; keep `${OPENCLAW_MI_CLIENT_ID}` placeholder (CI will substitute the `ch` instance MI client ID). Namespace: `openclaw-ch`. | | |
| TASK-004 | Create `workloads/dev/openclaw-ch/bootstrap/secretproviderclass.yaml` — copy from existing; update `objectName: ${INST}-openclaw-gateway-token` where `${INST}` is substituted to `ch` at seed time. Namespace: `openclaw-ch`. | | |
| TASK-005 | Create `workloads/dev/openclaw-ch/bootstrap/configmap.yaml` — copy from existing; set `AZURE_OPENAI_ENDPOINT: "${AZURE_OPENAI_ENDPOINT}"` (shared endpoint) and `APP_FQDN: "ch-paa-dev.acmeadventure.ca"` (hard-coded, not substituted). Namespace: `openclaw-ch`. | | |
| TASK-006 | Create `workloads/dev/openclaw-ch/crds/pv.yaml` — copy from existing; update NFS share name to `openclaw-ch-nfs`; update PV name to `openclaw-ch-nfs-pv`. | | |
| TASK-007 | Repeat TASK-001 through TASK-006 for instance `jh`: `workloads/dev/openclaw-jh/`, NFS share `openclaw-jh-nfs`, namespace `openclaw-jh`, FQDN `jh-paa-dev.acmeadventure.ca`. | | |

### Implementation Phase 2 — Prod Instance Directories

- GOAL-002: Create `workloads/prod/openclaw-ch/`, `openclaw-jh/`, `openclaw-kjm/`.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-008 | Create `workloads/prod/openclaw-ch/` — copy from `workloads/prod/openclaw/`; update for instance `ch`, NFS share `openclaw-ch-nfs`, namespace `openclaw-ch`, FQDN `ch-paa.acmeadventure.ca`. | | |
| TASK-009 | Create `workloads/prod/openclaw-jh/` — same pattern for instance `jh`, FQDN `jh-paa.acmeadventure.ca`. | | |
| TASK-010 | Create `workloads/prod/openclaw-kjm/` — same pattern for instance `kjm`, FQDN `kjm-paa.acmeadventure.ca`. | | |

### Implementation Phase 3 — ArgoCD Application Manifests

- GOAL-003: Create per-instance ArgoCD Application manifests in `argocd/apps/`.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-011 | Create `argocd/apps/dev-openclaw-ch.yaml` — copy from `argocd/apps/dev-openclaw.yaml`; update `metadata.name: ch-openclaw-dev`, `spec.source.path: workloads/dev/openclaw-ch`, `spec.destination.namespace: openclaw-ch`. Retain `syncPolicy`, `ignoreDifferences` (ConfigMap `openclaw-config`). | | |
| TASK-012 | Create `argocd/apps/dev-openclaw-jh.yaml` — same pattern for `jh`, namespace `openclaw-jh`. | | |
| TASK-013 | Create `argocd/apps/prod-openclaw-ch.yaml`, `prod-openclaw-jh.yaml`, `prod-openclaw-kjm.yaml` — same pattern for prod, paths pointing to `workloads/prod/openclaw-{inst}/`. | | |
| TASK-014 | Do not delete legacy `argocd/apps/dev-openclaw.yaml` and `argocd/apps/prod-openclaw.yaml` until the single-instance `ch` pod is confirmed migrated and healthy on per-instance routes. Mark them deprecated with a comment. | | |

### Implementation Phase 4 — Update seed-openclaw-aks.sh

- GOAL-004: Update `scripts/seed-openclaw-aks.sh` to support per-instance seeding.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-015 | Update `scripts/seed-openclaw-aks.sh` to accept a second optional argument `{inst}`. When an instance is provided, seed only that instance's `workloads/{env}/openclaw-{inst}/bootstrap/` directory. When omitted, iterate over all instances in the environment (sourced from a `OPENCLAW_INSTANCES` env var, space-separated, defaulting to values from the tfvars). | | |
| TASK-016 | Update the required env vars in `seed-openclaw-aks.sh` header: add `OPENCLAW_MI_CLIENT_ID_{INST}` pattern or accept `OPENCLAW_MI_CLIENT_IDS` as a JSON map. Set `OPENCLAW_MI_CLIENT_ID` per instance from the map before calling `envsubst`. Also set `INST={inst}` for substitution in `secretproviderclass.yaml`. | | |
| TASK-017 | Update the namespace creation step: `kubectl create namespace openclaw-${INST} --dry-run=client -o yaml | kubectl apply -f -`. | | |
| TASK-018 | Update the ArgoCD application step: `kubectl apply -f argocd/apps/${ENV}-openclaw-${INST}.yaml`. | | |
| TASK-019 | Update CI workflow (`.github/workflows/aks-bootstrap.yml` or the seed step in `terraform-infra.yml`) to export `OPENCLAW_MI_CLIENT_ID_{INST}` values from Terraform outputs (`terraform output -json instance_mi_client_ids`) and call `seed-openclaw-aks.sh` for each instance. | | |

### Implementation Phase 5 — Legacy Cleanup

- GOAL-005: Remove the single-instance workload directory and ArgoCD application after per-instance migration is validated.

| Task | Description | Completed | Date |
| ---- | ----------- | --------- | ---- |
| TASK-020 | After validation (SUB-006 complete), delete `workloads/dev/openclaw/`, `workloads/prod/openclaw/`, `argocd/apps/dev-openclaw.yaml`, `argocd/apps/prod-openclaw.yaml` in a dedicated cleanup PR. | | |

## 3. Alternatives

- **ALT-001**: Single Helm release for all instances, parameterized by instance name — tight coupling; ArgoCD application-per-instance model is cleaner for independent rollouts.
- **ALT-002**: ArgoCD ApplicationSet with a list generator over instances — cleaner if instance count is large; adds ArgoCD ApplicationSet CRD dependency. Consider as a future enhancement once more than 5 instances are needed.

## 4. Dependencies

- **DEP-001**: SUB-003 (Terraform) — `instance_mi_client_ids` and `instance_nfs_share_names` outputs needed for bootstrap manifests.
- **DEP-002**: SUB-004 (Gateway) — HTTPRoute manifests and listener listener names must align with per-instance listener `sectionName` values.
- **DEP-003**: ArgoCD must be running and connected to the repository before Application manifests are applied.

## 5. Files

- **FILE-001**: `workloads/dev/openclaw-ch/` — complete instance directory (new)
- **FILE-002**: `workloads/dev/openclaw-jh/` — complete instance directory (new)
- **FILE-003**: `workloads/prod/openclaw-ch/` — complete instance directory (new)
- **FILE-004**: `workloads/prod/openclaw-jh/` — complete instance directory (new)
- **FILE-005**: `workloads/prod/openclaw-kjm/` — complete instance directory (new)
- **FILE-006**: `argocd/apps/dev-openclaw-ch.yaml` — ArgoCD app for ch dev (new)
- **FILE-007**: `argocd/apps/dev-openclaw-jh.yaml` — ArgoCD app for jh dev (new)
- **FILE-008**: `argocd/apps/prod-openclaw-ch.yaml`, `prod-openclaw-jh.yaml`, `prod-openclaw-kjm.yaml` — prod ArgoCD apps (new)
- **FILE-009**: [scripts/seed-openclaw-aks.sh](../scripts/seed-openclaw-aks.sh) — per-instance seeding support
- **FILE-010**: [.github/workflows/terraform-infra.yml](../.github/workflows/terraform-infra.yml) — iterate seed script over all instances

## 6. Testing

- **TEST-001**: After seeding dev `ch`: `kubectl get pods -n openclaw-ch` — pod reaches `Running` state.
- **TEST-002**: ArgoCD UI or `kubectl get applications -n argocd` — `ch-openclaw-dev` and `jh-openclaw-dev` show `Synced` / `Healthy`.
- **TEST-003**: Per-instance NetworkPolicy: `kubectl exec -n openclaw-ch -- curl http://openclaw.openclaw-jh.svc.cluster.local:18789` — must time out (cross-namespace blocked).
- **TEST-004**: `kubectl exec -n openclaw-ch -- env | grep OPENCLAW_GATEWAY_TOKEN` — shows instance-specific token (not shared with `jh`).
- **TEST-005**: Helm values `resources.requests` and `resources.limits` are reflected in `kubectl describe pod -n openclaw-ch`.

## 7. Risks & Assumptions

- **RISK-001**: The Helm chart uses a fixed release name inside the chart; confirm that deploying with a different `releaseName` (`openclaw-ch` vs `openclaw`) does not break service name references. Review chart templates before TASK-001.
- **RISK-002**: The PV/PVC naming in the chart may be hardcoded to `openclaw-nfs-pv`; NFS share rename and PV name update in TASK-006 must be consistent with what the Helm chart expects. Inspect chart templates.
- **ASSUMPTION-001**: The `serhanekicii/openclaw-helm` chart supports injecting different resource values (NFS share name, FQDN, resource requests/limits) via `values.yaml` without chart modification.

## 8. Related Specifications / Further Reading

- [plan/feature-multi-instance-aks-1.md](../plan/feature-multi-instance-aks-1.md)
- [plan/feature-multi-instance-terraform-1.md](../plan/feature-multi-instance-terraform-1.md)
- [scripts/seed-openclaw-aks.sh](../scripts/seed-openclaw-aks.sh)
- [workloads/dev/openclaw/bootstrap/](../workloads/dev/openclaw/bootstrap/)
- [argocd/apps/](../argocd/apps/)
