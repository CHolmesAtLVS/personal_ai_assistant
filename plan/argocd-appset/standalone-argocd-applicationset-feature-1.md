---
goal: Replace per-instance ArgoCD Application manifests with a single ApplicationSet using MatrixGenerator
plan_type: standalone
version: 1.0
date_created: 2026-04-12
status: 'Planned'
tags: [feature, gitops, argocd, simplification]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

Currently `argocd/apps/` contains one `Application` manifest per environment/instance combination (`dev-openclaw-ch.yaml`, `dev-openclaw-jh.yaml`, `prod-openclaw-ch.yaml`, `prod-openclaw-jh.yaml`, `prod-openclaw-kjm.yaml`). Each file is identical except for three fields: `metadata.name`, `source.path`, and `destination.namespace`. Adding a new instance requires creating a new file. This plan replaces all five manifests with a single `ApplicationSet` that uses a `MatrixGenerator` to produce each `Application` from a list of env/instance pairs.

## 1. Requirements & Constraints

- **REQ-001**: All five existing `Application` resources must be reproduced exactly — same name pattern (`{inst}-openclaw-{env}`), path pattern (`workloads/{env}/openclaw-{inst}`), namespace pattern (`openclaw-{inst}`), syncPolicy, and `ignoreDifferences` — so ArgoCD adopts them without re-creating managed resources.
- **REQ-002**: Adding a new instance (e.g. `az` in prod) must require only adding one element to the generator list in the `ApplicationSet`, with no new files.
- **REQ-003**: The deprecated single-instance Application manifests (`dev-openclaw.yaml`, `prod-openclaw.yaml`) must remain until their namespaces are confirmed decommissioned; they are outside scope of this plan.
- **REQ-004**: The `ApplicationSet` must be applied to the `argocd` namespace with `argocd` as the configured `AppProject`.
- **SEC-001**: `repoURL` must continue to reference the GitHub repo. No credentials embedded in the manifest.
- **CON-001**: ArgoCD chart version `9.4.17` is pinned (see `workloads/bootstrap/README.md`). `applicationset-controller` ships as part of ArgoCD since v2.3; no additional Helm installs required.
- **CON-002**: `targetRevision` must be a per-row generator parameter — dev instance rows use `targetRevision: dev` (required by the test-dev branch model; see `plan/test-dev/parent-openclaw-test-dev-feature-1.md`), prod instance rows use `targetRevision: HEAD` (default branch). The template references `{{targetRevision}}`; it must not be hardcoded.
- **GUD-001**: The five existing `Application` manifests must be deleted in the same commit that applies the `ApplicationSet`, or ArgoCD will have duplicate apps that conflict.
- **GUD-002**: Validate the rollout in dev first. `argocd app list` output must show `ch-openclaw-dev` and `jh-openclaw-dev` Synced/Healthy before touching prod entries.

## 2. Implementation Steps

### Implementation Phase 1 — Author the ApplicationSet manifest

- GOAL-001: Create `argocd/apps/openclaw-appset.yaml` containing the `ApplicationSet` with a `MatrixGenerator` that generates one `Application` per env/instance pair.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-001 | Create `argocd/apps/openclaw-appset.yaml`. Use `apiVersion: argoproj.io/v1alpha1`, `kind: ApplicationSet`, `metadata.name: openclaw`, `metadata.namespace: argocd`. Add a `spec.generators` entry using a single flat `list` generator (ALT-002) with explicit `{env, inst, targetRevision}` rows: `[{env: dev, inst: ch, targetRevision: dev}, {env: dev, inst: jh, targetRevision: dev}, {env: prod, inst: ch, targetRevision: HEAD}, {env: prod, inst: jh, targetRevision: HEAD}, {env: prod, inst: kjm, targetRevision: HEAD}]`. Dev rows carry `targetRevision: dev` to satisfy the test-dev branch model. | | |
| TASK-002 | Verify the five generator rows match exactly: `{env: dev, inst: ch, targetRevision: dev}`, `{env: dev, inst: jh, targetRevision: dev}`, `{env: prod, inst: ch, targetRevision: HEAD}`, `{env: prod, inst: jh, targetRevision: HEAD}`, `{env: prod, inst: kjm, targetRevision: HEAD}`. The flat list is the complete and authoritative set — no cross-product filtering is needed. | | |
| TASK-003 | Author `spec.template` block: `metadata.name: "{{inst}}-openclaw-{{env}}"`, `spec.source.path: "workloads/{{env}}/openclaw-{{inst}}"`, `spec.source.targetRevision: "{{targetRevision}}"`, `spec.destination.namespace: "openclaw-{{inst}}"`. `targetRevision` is parameterized from the generator row — do NOT hardcode it. All other fields (`repoURL`, `releaseName`, `valueFiles`, `syncPolicy`, `syncOptions`, `ignoreDifferences`) are copied verbatim from the existing Application manifests into the template. | | |
| TASK-004 | Dry-run validate: `kubectl apply --dry-run=server -f argocd/apps/openclaw-appset.yaml` against the dev cluster. Confirm ArgoCD expands to exactly the expected 5 `Application` resources with `kubectl get applications -n argocd`. | | |

### Implementation Phase 2 — Cutover and cleanup

- GOAL-002: Apply the `ApplicationSet`, confirm ArgoCD reconciles without disruption, then delete the 5 per-instance `Application` YAML files.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-005 | Delete the existing `Application` objects from the cluster before applying the `ApplicationSet`: `kubectl delete application -n argocd ch-openclaw-dev jh-openclaw-dev ch-openclaw-prod jh-openclaw-prod kjm-openclaw-prod`. ArgoCD will stop managing the workloads momentarily; pods and namespaces are unaffected. Then apply: `kubectl apply -f argocd/apps/openclaw-appset.yaml`. | | |
| TASK-006 | Run `argocd app list` and confirm `ch-openclaw-dev` and `jh-openclaw-dev` show `Synced` and `Healthy`. Check ArgoCD UI or events for any errors on the generated Applications. | | |
| TASK-007 | Delete the five per-instance `Application` YAML files: `dev-openclaw-ch.yaml`, `dev-openclaw-jh.yaml`, `prod-openclaw-ch.yaml`, `prod-openclaw-jh.yaml`, `prod-openclaw-kjm.yaml`. The `ApplicationSet` controller now owns these Application resources — the individual YAML files are no longer needed (and if left, would conflict on re-apply). | | |
| TASK-008 | Update `argocd/apps/README.md` to document the new structure: single `ApplicationSet` file, how to add an instance (edit the generator list), and that the deprecated `dev-openclaw.yaml` / `prod-openclaw.yaml` remain until legacy namespace decommission. | | |
| TASK-009 | Commit all changes (`openclaw-appset.yaml` added, 5 files deleted, README updated) and push. Confirm CI/ArgoCD sync remains healthy for all five instances post-push. | | |

## 3. Alternatives

- **ALT-001 (MatrixGenerator — cross-product)**: Use a true `matrix` of `[{env: dev}, {env: prod}]` × `[{inst: ch}, {inst: jh}, {inst: kjm}]`. This produces 6 combinations (dev×kjm is invalid) — requires an additional `ignoreApplications` filter or a dummy path guard, making it less clean.
- **ALT-002 (flat ListGenerator — chosen approach)**: Use a single `list` generator with explicit `{env, inst}` pairs: `[{env:dev,inst:ch}, {env:dev,inst:jh}, {env:prod,inst:ch}, {env:prod,inst:jh}, {env:prod,inst:kjm}]`. This is the simplest, most explicit approach — no cross-product risk, adding an instance is one line. Slight verbosity is acceptable given the env/inst pairing is not symmetric.
- **ALT-003 (Git generator)**: Use ArgoCD's `git` generator to discover workload directories automatically (scan `workloads/*/openclaw-*`). Would auto-discover new instances without editing the `ApplicationSet`. Rejected because it couples ArgoCD sync to directory naming conventions at scan time, making behavior less explicit and harder to audit.

## 4. Dependencies

- **DEP-001**: ArgoCD `9.4.17` must be installed and the `applicationset-controller` running in the `argocd` namespace. Verify: `kubectl get deploy -n argocd argocd-applicationset-controller`.
- **DEP-002**: `workloads/{env}/openclaw-{inst}/` directories must exist for all five instances before the `ApplicationSet` is applied — they do as of PR #32.
- **DEP-003**: PR #32 (`feat/multi-openclaw`) must be merged before this plan executes in prod — per-instance workload directories only exist on that branch.
- **DEP-004**: This plan must complete before `plan/test-dev/sub-001-dev-branch-argocd-feature-1.md` (test-dev SUB-001) executes TASK-003. That task targets the `targetRevision` values in the generator list this plan introduces. If this plan has not yet been applied, test-dev SUB-001 must instead edit the per-instance `Application` YAML files directly.

## 5. Files

- **FILE-001**: `argocd/apps/openclaw-appset.yaml` — new `ApplicationSet` manifest (created)
- **FILE-002**: `argocd/apps/dev-openclaw-ch.yaml` — deleted
- **FILE-003**: `argocd/apps/dev-openclaw-jh.yaml` — deleted
- **FILE-004**: `argocd/apps/prod-openclaw-ch.yaml` — deleted
- **FILE-005**: `argocd/apps/prod-openclaw-jh.yaml` — deleted
- **FILE-006**: `argocd/apps/prod-openclaw-kjm.yaml` — deleted
- **FILE-007**: `argocd/apps/README.md` — updated

## 6. Testing

- **TEST-001**: `kubectl apply --dry-run=server -f argocd/apps/openclaw-appset.yaml` returns no errors.
- **TEST-002**: After apply, `kubectl get applications -n argocd` lists exactly: `ch-openclaw-dev`, `jh-openclaw-dev`, `ch-openclaw-prod`, `jh-openclaw-prod`, `kjm-openclaw-prod` (plus legacy deprecated apps).
- **TEST-003**: All five generated Applications show `Synced` and `Healthy` in `argocd app list` within 2 minutes of apply.
- **TEST-004**: No pod restarts observed across `openclaw-ch`, `openclaw-jh`, `openclaw-kjm` namespaces during cutover.
- **TEST-005**: After deleting the 5 per-instance YAML files and pushing, ArgoCD continues to manage all five Applications (they are now owned exclusively by the `ApplicationSet` controller).

## 7. Risks & Assumptions

- **RISK-001**: ~~ArgoCD ApplicationSet ownership adoption~~ — confirmed non-issue. OpenClaw can be deleted and recreated; existing Application objects are deleted from the cluster before the `ApplicationSet` is applied (TASK-005).
- **RISK-002**: Matrix generator syntax varies between ArgoCD versions. The flat `ListGenerator` (ALT-002) avoids this risk entirely.
- **ASSUMPTION-001**: `applicationset-controller` is enabled in the ArgoCD Helm install. ArgoCD `9.4.17` ships it by default; no values override disables it.
- **ASSUMPTION-002**: The `argocd` AppProject `default` permits source paths `workloads/**` — consistent with the existing Application manifests which already use this project.

## 8. Related Specifications / Further Reading

- [../../plan/multi-instance/parent-multi-instance-aks-feature-1.md](../../plan/multi-instance/parent-multi-instance-aks-feature-1.md) — parent plan that introduced per-instance app manifests
- [../../plan/test-dev/parent-openclaw-test-dev-feature-1.md](../../plan/test-dev/parent-openclaw-test-dev-feature-1.md) — test-dev plan requiring dev instances to track the `dev` branch; its SUB-001 depends on this plan completing first
- [ArgoCD ApplicationSet — List Generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-List/)
- [ArgoCD ApplicationSet — Matrix Generator](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Matrix/)
