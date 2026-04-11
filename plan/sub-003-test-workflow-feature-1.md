---
goal: Post-deployment OpenClaw integration test workflow gating dev→main
plan_type: sub
parent_plan: parent-openclaw-test-dev-feature-1.md#SUB-003
version: 1.0
date_created: 2026-04-11
owner: platform
status: 'Planned'
tags: [feature, testing, ci, workflow]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

Create `.github/workflows/openclaw-test-dev.yml` — a GitHub Actions workflow that runs the OpenClaw integration test suite against the dev cluster after every successful dev deployment. The workflow triggers via `workflow_run` on `Terraform Dev` (the new workflow from SUB-002), waits for ArgoCD to sync `openclaw-dev` and for the pod to reach `Ready`, then executes `scripts/test-multi-model.sh dev` and `scripts/test-openclaw-config.sh dev`. Its job name (`test-dev`) is registered as a required status check on the `main` branch Ruleset (added to the Ruleset in SUB-001 TASK-006 after this workflow has run once).

## 1. Requirements & Constraints

- **REQ-001**: Workflow must trigger automatically after `Terraform Dev` (`terraform-dev.yml`) completes successfully on a PR to `dev`.
- **REQ-002**: Must also support `workflow_dispatch` for manual retriggers (dev only, no inputs).
- **REQ-003**: Must wait for ArgoCD `openclaw-dev` Application to reach `Synced` status and for the `openclaw` deployment in namespace `openclaw` to reach `Ready` before running tests.
- **REQ-004**: Must run `scripts/test-multi-model.sh dev` as the primary health test.
- **REQ-005**: Must run `scripts/test-openclaw-config.sh dev` as secondary config validation.
- **REQ-006**: Must write structured output to `$GITHUB_STEP_SUMMARY` so results appear inline on the PR.
- **REQ-007**: Job must fail (exit non-zero) when any test script fails, so the PR check blocks merge.
- **SEC-001**: Workflow targets dev only. No prod resource identifiers may appear.
- **SEC-002**: Azure credentials consumed exclusively from GitHub Actions `dev` environment secrets.
- **SEC-003**: Managed Identity is the AKS runtime identity; CI authenticates via Service Principal (same pattern as `aks-bootstrap.yml`).
- **CON-001**: ArgoCD is internal-only. Sync-wait must use `kubectl` polling — no external ArgoCD URL.
- **CON-002**: `openclaw` CLI (`npm install -g openclaw`) is required for `[live]` and `[CLI only]` sections of `test-multi-model.sh`. Sections marked `[always]` run without it.
- **CON-003**: `az containerapp exec` is rate-limited (~5 sessions / 10 min). `test-openclaw-config.sh` uses 1 exec session. Add `sleep 120` before the config validation step to avoid hitting the rate limit immediately after bootstrap's seed step.
- **CON-004**: `test-multi-model.sh` reads Key Vault secrets. The CI Service Principal must have `Key Vault Secrets User` on the dev Key Vault (`${TF_VAR_PROJECT}-dev-kv`).
- **CON-005**: The `workflow_run` trigger fires on the workflow from the **default branch** (`main`). The new workflow file must be merged to `main` before it can be triggered via `workflow_run`. For the initial rollout, merge SUB-001 → SUB-002 → SUB-003 to `main` in order (permitted as an initial bootstrap sequence before the Ruleset is active), then activate the Ruleset.
- **GUD-001**: Job name must be `test-dev` — this is the name registered as a required status check in SUB-001 TASK-006.
- **GUD-002**: Follow existing workflow conventions: `permissions: contents: read`, SP auth via `az login --service-principal`, resource names from `TF_VAR_PROJECT` var.

## 2. Implementation Steps

### Implementation Phase 1 — Create the test workflow

- GOAL-001: Create `.github/workflows/openclaw-test-dev.yml` with correct trigger, auth, wait, and test steps.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                           | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | Create `.github/workflows/openclaw-test-dev.yml`. Set `name: OpenClaw Test Dev`. Set `on.workflow_run` with `workflows: ["Terraform Dev"]`, `types: [completed]`. Set `on.workflow_dispatch` with no inputs. Set `permissions: contents: read`.                                                                                                                                                                                       |           |      |
| TASK-002 | Add job `test-dev` with `runs-on: ubuntu-latest`, `environment: dev`. Add `if:` guard: `(github.event_name == 'workflow_dispatch') \|\| (github.event_name == 'workflow_run' && github.event.workflow_run.name == 'Terraform Dev' && github.event.workflow_run.conclusion == 'success')`. Add `env:` block: `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` from secrets; `TF_VAR_project: ${{ vars.TF_VAR_PROJECT }}`; `TF_VAR_environment: dev`. |           |      |
| TASK-003 | Add steps in order: (1) `Checkout` using `actions/checkout@v4`; (2) `Azure Login (Service Principal)` — same `az login --service-principal` shell block used in `aks-bootstrap.yml`; (3) `Configure kubectl` — `az aks get-credentials --resource-group ${TF_VAR_project}-dev-rg --name ${TF_VAR_project}-dev-aks --overwrite-existing`; (4) `Install openclaw CLI` — `npm install -g openclaw`; (5) `Install jq` — `sudo apt-get install -y jq`. |           |      |
| TASK-004 | Add step `Wait — ArgoCD sync + pod readiness` with the exact shell logic below (see TASK-004 detail).                                                                                                                                                                                                                                                                                                                                |           |      |
| TASK-005 | Add step `Run OpenClaw health tests`: `export CI=true && bash scripts/test-multi-model.sh dev`. Prepend `echo "## OpenClaw Dev Integration Tests — $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> $GITHUB_STEP_SUMMARY` before the script run; pipe output via `tee /tmp/health-out.txt`; append fenced block to `$GITHUB_STEP_SUMMARY` afterward.                                                                                               |           |      |
| TASK-006 | Add step `Wait before config validation` — `sleep 120` — to avoid `az containerapp exec` rate limit (CON-003). Add comment in the step `name` field explaining the reason.                                                                                                                                                                                                                                                          |           |      |
| TASK-007 | Add step `Run OpenClaw config validation`: `bash scripts/test-openclaw-config.sh dev`. Append `## Config Validation` heading and fenced output block to `$GITHUB_STEP_SUMMARY`.                                                                                                                                                                                                                                                     |           |      |
| TASK-008 | Add final step `Test Summary` with `if: always()`. Write a summary line to `$GITHUB_STEP_SUMMARY` reporting outcomes of the health and config steps using `${{ steps.health.outcome }}` and `${{ steps.config.outcome }}`. Assign `id: health` and `id: config` to TASK-005/007 steps respectively so outcomes are accessible.                                                                                                      |           |      |

**TASK-004 detail — ArgoCD sync + pod readiness wait shell logic:**

```bash
set -euo pipefail
TIMEOUT=600
INTERVAL=15
ELAPSED=0

echo "Waiting for ArgoCD to sync openclaw-dev..."
until kubectl get application openclaw-dev -n argocd \
      -o jsonpath='{.status.sync.status}' 2>/dev/null \
      | grep -q "Synced"; do
  if [[ $ELAPSED -ge $TIMEOUT ]]; then
    echo "Timeout waiting for ArgoCD sync after ${TIMEOUT}s"; exit 1
  fi
  sleep $INTERVAL
  ELAPSED=$(( ELAPSED + INTERVAL ))
done
echo "ArgoCD sync: Synced"

echo "Waiting for OpenClaw pod readiness..."
kubectl rollout status deployment/openclaw -n openclaw --timeout=5m
echo "OpenClaw pod: Ready"
```

### Implementation Phase 2 — Activate required status check in Ruleset

- GOAL-002: Register `test-dev` as a required status check on the `main` branch Ruleset (completing SUB-001 TASK-006).

| Task     | Description                                                                                                                                                                                                  | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-009 | After `openclaw-test-dev.yml` has merged to `main` and the `test-dev` job has run at least once on a PR to `dev` (so GitHub registers the check name), return to the GitHub Ruleset created in SUB-001 TASK-005 and add `Require status checks to pass` with check name `test-dev`. |           |      |

### Implementation Phase 3 — End-to-end validation

- GOAL-003: Verify the full chain fires correctly on a real PR.

| Task     | Description                                                                                                                                                                              | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-010 | Open a test PR from a feature branch to `dev` touching any file under `terraform/`. Verify the chain: `Terraform Dev` → `AKS Bootstrap` (bootstrap-dev) → `OpenClaw Test Dev` (test-dev). Confirm all three complete successfully. |           |      |
| TASK-011 | Confirm the `test-dev` job summary on the PR shows health test output and config validation output.                                                                                      |           |      |
| TASK-012 | Temporarily introduce a bad value in the dev Key Vault, retrigger via `workflow_dispatch`, confirm the workflow fails and the `test-dev` check turns red. Restore the correct value.    |           |      |
| TASK-013 | After TASK-009 activates the required status check, attempt to open or merge a `dev` → `main` PR with a failing `test-dev` check. Confirm GitHub blocks the merge.                     |           |      |

## 3. Alternatives

- **ALT-001**: Trigger on `aks-bootstrap.yml` completion (`workflow_run: ["AKS Bootstrap"]`) rather than `Terraform Dev`. Originally planned in the v1 standalone approach. Changed to trigger on `Terraform Dev` because: (a) ArgoCD deploys from `dev` branch, not from bootstrap; (b) bootstrap may not run on every PR (only infra-path PRs); (c) workload-only PRs that don't touch `terraform/` need a different trigger path — see RISK-001.
- **ALT-002**: Embed the tests as additional steps in `aks-bootstrap.yml`. Rejected: separate concern; failure triage is cleaner with isolated workflows.
- **ALT-003**: Use `argocd` CLI (`argocd app wait`) for sync-wait. Rejected: requires port-forward to internal-only ArgoCD service.

## 4. Dependencies

- **DEP-001**: SUB-001 must complete — `dev` branch and ArgoCD `targetRevision: dev` must exist.
- **DEP-002**: SUB-002 must complete — `Terraform Dev` workflow name must exist for the `workflow_run` trigger.
- **DEP-003**: CI Service Principal must have `Key Vault Secrets User` on the dev Key Vault.
- **DEP-004**: `scripts/test-multi-model.sh` and `scripts/test-openclaw-config.sh` — consumed as-is, no modifications.
- **DEP-005**: GitHub Actions `dev` environment secrets: `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` — already present.
- **DEP-006**: `openclaw-test-dev.yml` must be merged to `main` before the `workflow_run` trigger is active (CON-005). Initial bootstrap merge to `main` is a one-time exception to the Ruleset, performed before the required status check is activated.

## 5. Files

- **FILE-001**: `.github/workflows/openclaw-test-dev.yml` — new file, primary deliverable.
- **FILE-002**: `scripts/test-multi-model.sh` — consumed as-is, no changes.
- **FILE-003**: `scripts/test-openclaw-config.sh` — consumed as-is, no changes.

## 6. Testing

- **TEST-001**: `workflow_dispatch` manual trigger against a healthy dev cluster — all sections pass.
- **TEST-002**: Full automated chain on a PR-to-`dev` touching `terraform/`.
- **TEST-003**: Deliberate config error causes `test-dev` to fail and PR check to block.
- **TEST-004**: ArgoCD not synced (e.g., manifest error) — wait step times out with clear message.

## 7. Risks & Assumptions

- **RISK-001**: PRs that only touch `workloads/` or `argocd/` (no `terraform/` changes) will not trigger `Terraform Dev`, so the test workflow will not fire automatically. Mitigation options (out of scope for this plan): (a) add a separate `on.push` trigger to `dev` for workload-path changes; (b) require manual `workflow_dispatch` retrigger for workload-only PRs. Document this gap in CONTRIBUTING.md.
- **RISK-002**: `workflow_run` fires from the default branch (`main`). The workflow file must be on `main` to be active. The initial three-subplan merge sequence to `main` (SUB-001 → SUB-002 → SUB-003) must happen in order as a one-time bootstrap before the Ruleset's source-branch restriction is activated.
- **RISK-003**: ArgoCD Application CR name mismatch. TASK-004 polls `application/openclaw-dev` in namespace `argocd`. Verify this name against the cluster after SUB-001 deploys.
- **RISK-004**: `deployment/openclaw` name in namespace `openclaw`. Verify against `workloads/dev/openclaw/values.yaml` before TASK-010.
- **ASSUMPTION-001**: `test-multi-model.sh` and `test-openclaw-config.sh` exit with code `1` on test failure.
- **ASSUMPTION-002**: AKS API server is reachable from GitHub Actions runners via `az aks get-credentials` (same assumption as bootstrap).

## 8. Related Specifications / Further Reading

- [Parent plan](parent-openclaw-test-dev-feature-1.md)
- [AKS Bootstrap workflow](../.github/workflows/aks-bootstrap.yml)
- [Terraform Dev workflow (to be created)](../.github/workflows/terraform-dev.yml)
- [OpenClaw health test script](../scripts/test-multi-model.sh)
- [OpenClaw config validation script](../scripts/test-openclaw-config.sh)
