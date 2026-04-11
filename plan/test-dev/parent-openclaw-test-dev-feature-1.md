---
goal: Test All OpenClaw Changes in Dev Before Production
plan_type: parent
version: 2.0
date_created: 2026-04-11
last_updated: 2026-04-11
owner: platform
status: 'Planned'
tags: [feature, testing, ci, workflow, gitops, argocd]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

Guarantee that every change — workload manifests, Helm values, Terraform infrastructure, and OpenClaw config — is deployed to and validated in dev before it can reach production. The root cause of the current gap is that both ArgoCD applications use `targetRevision: HEAD`, which resolves to the default branch (`main`). Changes on a PR branch are never deployed to dev; by the time any test runs against the dev cluster, it is already running the last-merged `main`. The solution is a three-part initiative: introduce a `dev` long-lived branch as the dev integration target (SUB-001), split and retarget CI workflows so all PR-based work flows through `dev` first (SUB-002), and add a post-deployment integration test workflow that gates merges to `main` (SUB-003).

## 1. Requirements & Constraints

- **REQ-001**: All changes to `workloads/`, `terraform/`, `argocd/`, and `config/` must pass dev deployment and integration tests before any change can be merged to `main`.
- **REQ-002**: ArgoCD dev must deploy exactly the code under review — not last-merged `main`.
- **REQ-003**: The production deployment path (push to `main`) must remain unchanged in behavior.
- **REQ-004**: Workflow triggers must be deterministic: PR to `dev` drives dev CI; merge to `main` drives prod.
- **REQ-005**: Branch protection rules must enforce the PR→`dev`→`main` flow; direct pushes to `main` must remain restricted to the prod promote path.
- **SEC-001**: Workflow must only ever exercise dev resources for dev CI. Prod resources must not be accessible during any dev CI job.
- **SEC-002**: Azure credentials must be consumed exclusively from GitHub Actions secrets — never hard-coded.
- **CON-001**: ArgoCD is internal-only (not exposed via Gateway). Sync-wait logic must use `kubectl` — no external ArgoCD URL.
- **CON-002**: The `workflow_run` event does not expose the PR's base branch (`base_ref`). To cleanly distinguish dev vs prod bootstrap triggers, the Terraform workflow must be split into separate `terraform-dev.yml` and updated `terraform-infra.yml` (prod-only). Each workflow has a distinct `name:` so `workflow_run` targets are unambiguous.
- **GUD-001**: Follow existing workflow conventions: `permissions: contents: read`, SP auth pattern, resource names from `TF_VAR_PROJECT` var.
- **GUD-002**: Keep branch model simple: one `dev` branch, one `main` branch. No per-feature ArgoCD apps.

## 2. Subplans

| ID      | Subplan File                                                                  | Goal                                                          | Status  |
| ------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------- | ------- |
| SUB-001 | [sub-001-dev-branch-argocd-feature-1.md](sub-001-dev-branch-argocd-feature-1.md) | Introduce `dev` branch; fix ArgoCD dev `targetRevision`   | Planned |
| SUB-002 | [sub-002-workflow-triggers-feature-1.md](sub-002-workflow-triggers-feature-1.md) | Split CI workflows so dev path targets `dev` branch       | Planned |
| SUB-003 | [sub-003-test-workflow-feature-1.md](sub-003-test-workflow-feature-1.md)         | Post-deployment OpenClaw integration test workflow        | Planned |

## 3. Alternatives

- **ALT-001**: Per-PR ArgoCD preview apps using ApplicationSet with a PR generator. Rejected: requires the ArgoCD API server to be reachable from CI (it is internal-only), and adds significant complexity for a two-environment setup.
- **ALT-002**: Have CI bypass ArgoCD for dev by running `helm upgrade` directly from the PR branch during bootstrap, then let ArgoCD correct to `main` afterward. Rejected: ArgoCD would immediately revert the CI-deployed revision, making tests race against the sync loop.
- **ALT-003**: Keep a single `main` branch but change ArgoCD dev to sync a specific SHA provided by CI. Rejected: requires ArgoCD API access from CI runners (internal-only) and is fragile under concurrent PRs.
- **ALT-004**: Keep the current branch model and test against `main` only (accept that workload changes aren't tested until after merge). Rejected: this is the status quo that allows regressions in workload manifests to reach production untested.

## 4. Dependencies

- **DEP-001**: GitHub repository branch protection settings — `dev` branch must be created and protected; `main` must only accept PRs from `dev` (or feature branches via `dev`).
- **DEP-002**: All existing workflow secrets (`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, etc.) are already present in both `dev` and `prod` GitHub Actions environments.

## 5. Execution Order

- **ORD-001**: SUB-001 must complete before SUB-002 begins. The `dev` branch must exist before workflow triggers are changed to target it; otherwise CI breaks immediately.
- **ORD-002**: SUB-002 must complete before SUB-003 begins. The test workflow triggers on the new `Terraform Dev` workflow name defined in SUB-002; it will not fire correctly until that workflow exists.

## 6. Risks & Assumptions

- **RISK-001**: Any open PRs targeting `main` at the time SUB-001/SUB-002 are deployed will have the wrong base branch and must be retargeted to `dev` or closed. Coordinate timing with the team.
- **RISK-002**: If ArgoCD on the dev cluster has already synced `main` content, changing `targetRevision` to `dev` will cause an immediate re-sync of the `dev` branch on next ArgoCD poll. Ensure `dev` branch is created from current `main` (no divergence) to avoid unexpected workload changes.
- **ASSUMPTION-001**: The `dev` branch is created from `main` at the time of SUB-001 execution, so initial state is identical to production.
- **ASSUMPTION-002**: The team adopts the PR-to-`dev`-first workflow going forward. This plan does not enforce it automatically without branch protection rules (REQ-005).

## 7. Related Specifications / Further Reading

- [ArgoCD dev app definition](../argocd/apps/dev-openclaw.yaml)
- [ArgoCD prod app definition](../argocd/apps/prod-openclaw.yaml)
- [Terraform Infrastructure workflow](../.github/workflows/terraform-infra.yml)
- [AKS Bootstrap workflow](../.github/workflows/aks-bootstrap.yml)

