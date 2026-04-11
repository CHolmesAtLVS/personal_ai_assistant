---
goal: Split CI workflows so dev path targets the `dev` branch
plan_type: sub
parent_plan: parent-openclaw-test-dev-feature-1.md#SUB-002
version: 1.0
date_created: 2026-04-11
owner: platform
status: 'Planned'
tags: [feature, ci, workflow, gitops]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

Retarget existing CI workflows so that the dev deployment chain fires on PRs to `dev` and the prod deployment chain fires on push to `main`. Currently both paths live in single workflow files using `pull_request` (targeting `main`) and `push` (to `main`). After SUB-001 introduces the `dev` branch, the Terraform dev job must be split into a dedicated `terraform-dev.yml` triggered by `pull_request` to `dev`, and `terraform-infra.yml` must be left as prod-only triggered by `push` to `main`. The AKS bootstrap workflow similarly needs separate `workflow_run` triggers referencing each workflow by its distinct name. This unambiguous naming is required because the `workflow_run` event does not expose `base_ref`, making it impossible to distinguish dev-vs-prod bootstrap triggers without distinct parent workflow names.

## 1. Requirements & Constraints

- **REQ-001**: A new `terraform-dev.yml` workflow (`name: Terraform Dev`) must trigger on `pull_request` targeting `dev` branch, paths `terraform/**`, `scripts/bootstrap-tfstate.sh`, `.github/workflows/terraform-dev.yml`.
- **REQ-002**: The existing `terraform-infra.yml` workflow (`name: Terraform Infrastructure`) must be updated to trigger only on `push` to `main` (prod path) and `workflow_dispatch`. Remove the `pull_request` trigger entirely.
- **REQ-003**: `aks-bootstrap.yml` `bootstrap-dev` job must change its `workflow_run` trigger from `Terraform Infrastructure` to `Terraform Dev`. The `bootstrap-prod` job continues to reference `Terraform Infrastructure`.
- **REQ-004**: `terraform-dev.yml` must include `workflow_dispatch` with `dev` as the only option, for manual re-runs.
- **REQ-005**: The dev Terraform job in `terraform-dev.yml` must be functionally identical to the current `terraform-dev` job in `terraform-infra.yml` — same steps, env vars, and `environment: dev` setting.
- **CON-001**: Do not change the prod Terraform job (`terraform-prod` in `terraform-infra.yml`) — only remove the `pull_request` trigger from the file's `on:` block.
- **CON-002**: After this change, the `Terraform Infrastructure` workflow name must not change — `aks-bootstrap.yml` `bootstrap-prod` and any other downstream `workflow_run` consumers depend on it.
- **GUD-001**: Preserve all existing env vars, secrets references, and step logic verbatim when copying the dev Terraform job to the new file.

## 2. Implementation Steps

### Implementation Phase 1 — Create `terraform-dev.yml`

- GOAL-001: Create a new workflow file that runs Terraform plan+apply against dev on every PR to `dev`.

| Task     | Description                                                                                                                                                                                                                                                                                                                               | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | Create `.github/workflows/terraform-dev.yml` with `name: Terraform Dev`. Set `on.pull_request` to trigger on types `[opened, synchronize, reopened]` targeting branch `dev`, paths `terraform/**`, `scripts/bootstrap-tfstate.sh`, `.github/workflows/terraform-dev.yml`. Add `on.workflow_dispatch` with `environment` input defaulting to `dev` (single option). Set `permissions: contents: read`. |           |      |
| TASK-002 | Add job `terraform-dev` to `terraform-dev.yml`. Copy the entire `terraform-dev` job body verbatim from the current `terraform-infra.yml` — same `env` block, same steps (Checkout, Setup Terraform, Azure Login, Bootstrap Backend, Download tfvars, Fmt, Init, Validate, Plan, Upload Artifact, Apply), same `environment: dev` and `runs-on: ubuntu-latest`. |           |      |

### Implementation Phase 2 — Update `terraform-infra.yml` (prod-only)

- GOAL-002: Remove the `pull_request` trigger from `terraform-infra.yml` so it only fires on push to `main`.

| Task     | Description                                                                                                                                                                                                                                                                                       | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-003 | In `terraform-infra.yml`, remove the entire `pull_request:` block from the `on:` section (types, branches, paths). Leave `push` (to `main`) and `workflow_dispatch` triggers intact. Update the header comment to reflect that this workflow is now prod-only: `push to main: plan + apply to prod. workflow_dispatch: manual prod apply.` |           |      |
| TASK-004 | In `terraform-infra.yml`, remove the `terraform-dev` job and its `if:` condition entirely. The file should contain only the `terraform-prod` job (triggered by `push` to `main`) and any shared steps.                                                                                          |           |      |

### Implementation Phase 3 — Update `aks-bootstrap.yml`

- GOAL-003: Retarget the dev bootstrap `workflow_run` to reference `Terraform Dev` (the new workflow name).

| Task     | Description                                                                                                                                                                                                                                                                             | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-005 | In `aks-bootstrap.yml`, change the `on.workflow_run.workflows` array from `["Terraform Infrastructure"]` to `["Terraform Dev", "Terraform Infrastructure"]` so the workflow file itself handles both dev and prod bootstrap jobs. Each job already has an `if:` guard to select the correct path. |           |      |
| TASK-006 | In `aks-bootstrap.yml`, update the `bootstrap-dev` job `if:` condition: change `github.event.workflow_run.event == 'pull_request'` to also verify `github.event.workflow_run.name == 'Terraform Dev'` (full condition: `(github.event_name == 'workflow_dispatch' && inputs.environment == 'dev') \|\| (github.event_name == 'workflow_run' && github.event.workflow_run.name == 'Terraform Dev' && github.event.workflow_run.conclusion == 'success')`). This makes the guard unambiguous regardless of triggering event. |           |      |
| TASK-007 | In `aks-bootstrap.yml`, update the `bootstrap-prod` job `if:` condition analogously: add `github.event.workflow_run.name == 'Terraform Infrastructure'` to disambiguate (full condition: `(github.event_name == 'workflow_dispatch' && inputs.environment == 'prod') \|\| (github.event_name == 'workflow_run' && github.event.workflow_run.name == 'Terraform Infrastructure' && github.event.workflow_run.conclusion == 'success')`). |           |      |

## 3. Alternatives

- **ALT-001**: Keep a single `terraform-infra.yml` and add a branch filter (`branches: [dev]`) to the existing `pull_request` trigger. Rejected: the `workflow_run` event has no `base_ref` — the bootstrap workflow cannot distinguish which Terraform job triggered it without a distinct workflow name.
- **ALT-002**: Use a `workflow_call` reusable workflow for the shared Terraform steps to avoid duplication between dev and prod files. Valid approach but out of scope for this plan — introduce only if duplicate steps become a maintenance burden.

## 4. Dependencies

- **DEP-001**: SUB-001 must complete first — the `dev` branch must exist before `terraform-dev.yml` triggers can fire.
- **DEP-002**: `terraform-infra.yml` `terraform-dev` job content is the source-of-truth for TASK-002; read it carefully before copying.

## 5. Files

- **FILE-001**: `.github/workflows/terraform-dev.yml` — new file, created in TASK-001/002.
- **FILE-002**: `.github/workflows/terraform-infra.yml` — modified; `pull_request` trigger and `terraform-dev` job removed.
- **FILE-003**: `.github/workflows/aks-bootstrap.yml` — modified; `workflow_run` workflows array and both job `if:` guards updated.

## 6. Testing

- **TEST-001**: Open a PR from a feature branch to `dev` touching any file under `terraform/`. Confirm `Terraform Dev` workflow fires and completes successfully. Confirm `Terraform Infrastructure` does NOT fire.
- **TEST-002**: Merge the PR to `dev`. Confirm `Terraform Infrastructure` does NOT fire (it only fires on push to `main`).
- **TEST-003**: Open a `dev` → `main` PR and merge it. Confirm `Terraform Infrastructure` fires and runs the prod job. Confirm `Terraform Dev` does NOT fire.
- **TEST-004**: After `Terraform Dev` completes on a PR-to-`dev`, confirm `AKS Bootstrap` `bootstrap-dev` job fires. Confirm `bootstrap-prod` does not fire.

## 7. Risks & Assumptions

- **RISK-001**: If any other workflow file references `Terraform Infrastructure` via `workflow_run` and expects it to fire on PRs, those references will break. Audit all workflow files for `Terraform Infrastructure` references before merging TASK-003/004.
- **ASSUMPTION-001**: The prod Terraform job (`terraform-prod`) in `terraform-infra.yml` currently has an `if: github.event_name == 'push'` or similar guard. Verify this before TASK-004 to ensure removing the `pull_request` trigger is sufficient and no job-level guard also needs updating.

## 8. Related Specifications / Further Reading

- [Parent plan](parent-openclaw-test-dev-feature-1.md)
- [Terraform Infrastructure workflow](../.github/workflows/terraform-infra.yml)
- [AKS Bootstrap workflow](../.github/workflows/aks-bootstrap.yml)
