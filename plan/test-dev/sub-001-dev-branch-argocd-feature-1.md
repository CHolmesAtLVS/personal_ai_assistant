---
goal: Introduce `dev` long-lived branch and fix ArgoCD dev targetRevision
plan_type: sub
parent_plan: parent-openclaw-test-dev-feature-1.md#SUB-001
version: 1.0
date_created: 2026-04-11
owner: platform
status: 'Planned'
tags: [feature, gitops, argocd, branch-model]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

Create a `dev` long-lived integration branch, change `argocd/apps/dev-openclaw.yaml` to track `dev` instead of `HEAD`, configure GitHub branch protection and a Ruleset so that only `dev` → `main` PRs are permitted on `main`, and update `CONTRIBUTING.md` and `.github/copilot-instructions.md` to document the new branch model.

## 1. Requirements & Constraints

- **REQ-001**: The `dev` branch must be created from the current tip of `main` so initial state is identical (zero-diff deploy to dev cluster on first sync).
- **REQ-002**: `argocd/apps/dev-openclaw.yaml` must set `targetRevision: dev` so ArgoCD dev tracks the `dev` branch.
- **REQ-003**: `argocd/apps/prod-openclaw.yaml` must remain `targetRevision: HEAD` (i.e., `main`) — no change.
- **REQ-004**: GitHub `main` branch must have a Ruleset (or branch protection rule) requiring: (a) PRs before merging, (b) source branch restricted to `dev`, and (c) the `OpenClaw Test Dev` required status check to pass (added in SUB-003).
- **REQ-005**: `CONTRIBUTING.md` must be updated to document the new `dev` → `main` branch model and the PR flow.
- **REQ-006**: `.github/copilot-instructions.md` must be updated with a comment noting the branch model so AI agents generate correct branch targets.
- **CON-001**: The GitHub Ruleset source-branch restriction is configured via **GitHub repository Rulesets** (Settings → Rules → Rulesets), not classic branch protection rules. Classic branch protection cannot restrict which branches can open a PR to `main`.
- **CON-002**: The `OpenClaw Test Dev` required status check (REQ-004c) does not exist until SUB-003 is merged. Add the Ruleset in two steps: create it without the status check requirement now, add the check after SUB-003 merges.
- **SEC-001**: No secrets or deployment-identifying identifiers must appear in branch names, commit messages, or documentation.

## 2. Implementation Steps

### Implementation Phase 1 — Create the `dev` branch

- GOAL-001: Create `dev` from `main` with zero divergence and push to origin.

| Task     | Description                                                                                                                                                                               | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | Run `git checkout main && git pull origin main && git checkout -b dev && git push origin dev` to create the `dev` branch from the current `main` tip.                                    |           |      |
| TASK-002 | Verify on GitHub (branch list) that `dev` appears and its latest commit SHA matches `main`.                                                                                              |           |      |

### Implementation Phase 2 — Update ArgoCD dev application

- GOAL-002: Make ArgoCD dev track the `dev` branch instead of `HEAD` (`main`).

| Task     | Description                                                                                                                                                                                                                 | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-003 | In `argocd/apps/dev-openclaw.yaml`, change `targetRevision: HEAD` to `targetRevision: dev`. No other fields change.                                                                                                        |           |      |
| TASK-004 | Commit the change on the `dev` branch (not `main`) so it is picked up by ArgoCD dev on its next sync cycle. Do not merge to `main` until SUB-002 and SUB-003 are complete and CI is ready.                                |           |      |

### Implementation Phase 3 — GitHub branch protection and Ruleset

- GOAL-003: Configure GitHub so only `dev` → `main` PRs are accepted and direct pushes to `main` are blocked.

| Task     | Description                                                                                                                                                                                                                                                                                                                                             | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-005 | In GitHub repository Settings → Rules → Rulesets, create a new Ruleset targeting branch `main` with: `Require a pull request before merging` (dismiss stale approvals optional); `Restrict source branches` pattern `dev`; `Block force pushes`. Leave required status checks empty for now — added in TASK after SUB-003 merges (see TASK-006).      |           |      |
| TASK-006 | After SUB-003 merges and the `OpenClaw Test Dev` workflow has run at least once (so GitHub registers the check name), return to the Ruleset and add `Require status checks to pass` with check name `test-dev` (the job name from `openclaw-test-dev.yml`).                                                                                             |           |      |
| TASK-007 | Verify the existing classic branch protection rule on `main` (if any) does not conflict with the new Ruleset. If a classic rule exists, confirm it also requires PRs and has no direct-push allowance. Rulesets take precedence over classic rules for the same branch; retain both or remove the classic rule if it duplicates the Ruleset.           |           |      |

### Implementation Phase 4 — Update documentation

- GOAL-004: Update `CONTRIBUTING.md` and `.github/copilot-instructions.md` to document the new branch model.

| Task     | Description                                                                                                                                                                                                                                                                                                                                             | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-008 | In `CONTRIBUTING.md`, add a new **Branch Model** section (after **Scope**, before **Core Contribution Principles**) documenting: (a) `dev` is the integration branch — all PRs target `dev`; (b) `main` is the production-ready branch — only a `dev` → `main` PR may target it; (c) feature branches branch from `dev` and PR back to `dev`; (d) ArgoCD dev tracks `dev`, ArgoCD prod tracks `main`; (e) all changes must pass dev integration tests before promoting to `main`. |           |      |
| TASK-009 | In `CONTRIBUTING.md`, update the **What to Update for Typical Changes** section bullet for "Helm values changes" and "ArgoCD Application changes" to reference the `dev` branch PR flow explicitly (e.g., "open a PR to `dev`" instead of "open a PR"). Review all existing bullets for branch-model accuracy and correct any that imply PRs go directly to `main`. |           |      |
| TASK-010 | In `.github/copilot-instructions.md`, add a comment block under **Project Context** noting the branch model: `dev` is the integration branch; all generated branch targets, PR base branches, and workflow trigger examples must use `dev` as the PR target unless explicitly generating a `dev` → `main` promote PR. Example text: `- Branch model: \`dev\` is the integration branch. PRs target \`dev\`. Only \`dev\` → \`main\` promotes to production. AI agents must generate PRs targeting \`dev\` unless explicitly asked for a production promote.` |           |      |

## 3. Alternatives

- **ALT-001**: Use a GitHub Actions `check` that fails if a PR to `main` does not come from `dev`. Considered as a fallback if Rulesets are not available on the plan tier. Lower priority since Rulesets provide a first-class UI-enforced control.
- **ALT-002**: Use a per-feature ArgoCD ApplicationSet that tracks PR branches. Rejected (same reason as parent plan ALT-001).

## 4. Dependencies

- **DEP-001**: GitHub repository must support Rulesets (available on GitHub Free/Pro/Team for public repos; GitHub Team/Enterprise for private — confirm repo visibility and plan tier before TASK-005).
- **DEP-002**: SUB-002 and SUB-003 must be merged before TASK-006 (required status check name is not registered until the test workflow runs).
- **DEP-003**: The ApplicationSet plan (`plan/argocd-appset/standalone-argocd-applicationset-feature-1.md`) should complete before TASK-003 executes. If it has not, TASK-003 must target the individual per-instance `Application` YAML files instead (see TASK-003 conditional note).

## 5. Files

- **FILE-001**: `argocd/apps/openclaw-appset.yaml` — dev generator rows updated: `targetRevision` changed from `HEAD` to `dev` (when the ApplicationSet plan is applied first); OR `argocd/apps/dev-openclaw-ch.yaml` and `argocd/apps/dev-openclaw-jh.yaml` — `targetRevision` changed from `HEAD` to `dev` in each file (when the ApplicationSet plan has NOT been applied). The deprecated `argocd/apps/dev-openclaw.yaml` is not modified.
- **FILE-002**: `CONTRIBUTING.md` — new Branch Model section + updated PR flow bullets.
- **FILE-003**: `.github/copilot-instructions.md` — branch model note added under Project Context.

## 6. Testing

- **TEST-001**: After TASK-001, confirm `git log origin/dev -1` and `git log origin/main -1` show the same commit SHA.
- **TEST-002**: After TASK-003/004 merge to `dev`, open ArgoCD UI (via `kubectl port-forward -n argocd svc/argocd-server 8080:80`) and confirm `openclaw-dev` Application shows `targetRevision: dev` and transitions to `Synced`.
- **TEST-003**: After TASK-005, attempt to open a PR from a feature branch directly to `main` and confirm GitHub blocks it with a Ruleset violation.
- **TEST-004**: Open a PR from a feature branch to `dev` and confirm it is accepted.

## 7. Risks & Assumptions

- **RISK-001**: If `dev` is created while a PR to `main` is already open, that PR will be orphaned. Coordinate branch creation during a quiet window.
- **RISK-002**: ArgoCD re-sync on `dev` after TASK-003 will deploy the same content as `main` (zero-diff), but ArgoCD will show `OutOfSync` briefly as it evaluates. This is expected and harmless.
- **ASSUMPTION-001**: The repository is on a GitHub plan tier that supports Rulesets with source-branch restrictions.
- **ASSUMPTION-002**: There are no automated external processes (bots, scripts) that push directly to `main` that would break under the new Ruleset.

## 8. Related Specifications / Further Reading

- [Parent plan](parent-openclaw-test-dev-feature-1.md)
- [ArgoCD dev app definition](../argocd/apps/dev-openclaw.yaml)
- [Contributing guidelines](../CONTRIBUTING.md)
- [Copilot instructions](../.github/copilot-instructions.md)
- [GitHub Rulesets documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)
