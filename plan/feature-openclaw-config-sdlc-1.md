---
goal: Version-control OpenClaw gateway config and deploy it via the GitHub workflow (dev/prod SDLC)
plan_type: standalone
version: 1.1
date_created: 2026-03-30
last_updated: 2026-03-30
owner: Platform Engineering
status: 'Complete'
tags: [feature, workflow, terraform, openclaw, sdlc, configuration, security]
---

# Introduction

![Status: Complete](https://img.shields.io/badge/status-Complete-brightgreen)

The OpenClaw gateway configuration (`openclaw.json`) is currently not version-controlled and is not deployed by the GitHub Actions workflow. It requires a **manual `az storage file upload` step** described in section 1.3 of the ops runbook, which an operator must run by hand after every fresh Terraform apply. The runbook template also contains an invalid value (`"mode": "server"`) that causes a startup crash.

Additionally, some gateway settings are already injected via Terraform environment variables (`OPENCLAW_GATEWAY_BIND`, `OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS`, `OPENCLAW_GATEWAY_TOKEN`), while others (`gateway.mode`, `gateway.port`) are only in the manually-seeded file. This split creates an inconsistent configuration surface: Terraform controls some settings, a hand-crafted file on Azure Files controls others.

This plan reforms the configuration approach so that all non-secret OpenClaw configuration is version-controlled in the repo and deployed automatically as part of the existing `terraform-dev` / `terraform-prod` workflow jobs, with secrets passed in at deploy time from GitHub Secrets/variables.

> **Investigation complete (2026-03-30):** Phase 1 investigation tasks (TASK-001–TASK-004) are done. Key findings are recorded below. **The env-var-only path (Phase 2 preferred) is NOT FEASIBLE.** The file-upload path (Phase 2 alt) is the required implementation path. See findings below and updated Phase 2 alt tasks.

### Investigation Findings Summary

| Finding | Detail |
|---|---|
| `OPENCLAW_GATEWAY_MODE` | **NOT supported** as env var — must be in `openclaw.json` (confirms file is required) |
| `OPENCLAW_GATEWAY_BIND` | **NOT supported** as env var — currently a dead Terraform env var with no effect; must be in `openclaw.json` |
| `OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS` | **NOT supported** as env var — currently a dead Terraform env var with no effect; `gateway.controlUi.allowedOrigins` must be in `openclaw.json` |
| `OPENCLAW_GATEWAY_PORT` | **IS supported** — env var takes priority over config file; default is already `18789` so the field is technically optional in the config |
| `OPENCLAW_GATEWAY_TOKEN` | **IS supported** — env var takes priority over `gateway.auth.token` in config file; since KV injection already sets this, `auth.token` is NOT needed in `openclaw.json` |
| Config template substitutions needed | Only `${APP_FQDN}` — no Key Vault secret retrieval required in the workflow seed step |
| Dev root cause | `openclaw.json` on dev Azure Files only has `gateway.auth.{mode,token}`; missing `gateway.mode`, `gateway.bind`, `gateway.controlUi.allowedOrigins` |
| CI storage permissions | `allowSharedKeyAccess` is enabled (default null = true); `az storage account keys list` will work for the CI SP if it has the Contributor role |
| Phase 2 decision | **File-upload path (TASK-009–TASK-013) is required** — proceed directly; Phase 2 preferred (TASK-005–TASK-008) is closed as infeasible |

## 1. Requirements & Constraints

- **REQ-001**: All non-secret OpenClaw configuration must be stored in the repo and deployed via the GitHub Actions workflow for both `dev` and `prod` environments. Manual `az storage file upload` steps must not be required for routine deployments.
- **REQ-002**: Secrets (gateway `auth.token`) must never appear in committed files. They must be substituted at deploy time from GitHub Secrets or retrieved from Key Vault during the workflow run.
- **REQ-003**: The deployed configuration must be environment-specific: dev and prod environments may have different FQDNs for `controlUi.allowedOrigins` and may use different port or bind settings if needed.
- **REQ-004**: The solution must be idempotent — running the workflow twice must not corrupt or double-apply config.
- **REQ-005**: The `"mode": "server"` error in the current ops runbook seed template (section 1.3) must be corrected as part of this work; this plan also owns that fix (see [plan/feature-openclaw-startup-1.md](feature-openclaw-startup-1.md) TASK-007 for cross-reference — one of the two plans should own the fix; this plan takes ownership).
- **SEC-001**: The gateway `auth.token` value must never be written to `openclaw.json` (or any other on-disk config, including temporary files) during CI/CD. It must be sourced exclusively from Key Vault via the `OPENCLAW_GATEWAY_TOKEN` environment variable injected into the Container App at startup.
- **SEC-002**: Any committed config template (including `openclaw.json` variants) must contain no token value, no placeholder secrets, and no environment-variable placeholder for the gateway token. The gateway reads the token exclusively from the `OPENCLAW_GATEWAY_TOKEN` runtime environment variable; workflows must not substitute a token into files.
- **CON-001**: The preferred approach is to drive all configuration via Terraform environment variables on the Container App, eliminating the `openclaw.json` dependency entirely. This must be investigated first (Phase 1). The file-upload approach is the fallback.
- **CON-002**: If environment variables cannot fully replace `openclaw.json`, a template file must be committed to the repo (e.g., `config/openclaw.json.tpl`) and the workflow must render and upload it after `terraform apply`.
- **CON-003**: The workflow currently triggers only on changes to `terraform/**`. If a config template file is added (CON-002 path), the workflow `paths` filter must be extended to trigger on changes to that file as well.
- **CON-004**: Config upload to Azure Files requires the storage account key. The CI service principal has the `Storage File Data SMB Share Contributor` role or the storage account key must be retrieved via the SP's Key Vault access. The required permissions must be confirmed.
- **GUD-001**: Changes to the dev workflow step must be validated in a PR before merging to main. Prod config seed must only run in the `terraform-prod` job.
- **PAT-001**: Follow the existing workflow pattern: Azure CLI commands run in `shell: bash` steps with `set -euo pipefail`. Secrets come from `${{ secrets.* }}` only.

## 2. Implementation Steps

### Implementation Phase 0 — Immediate dev recovery (unblocking)

- GOAL-000: Re-seed `openclaw.json` on dev Azure Files with the correct minimum-valid content so the dev Container App can start immediately, before the full SDLC workflow is in place.

| Task     | Description                                                                                                                                                                                                                                                  | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-000 | Re-seed `openclaw.json` on dev Azure Files. The file must contain at minimum: `gateway.mode="local"`, `gateway.port=18789`, `gateway.bind="lan"`, `gateway.auth.mode="token"`, and `gateway.controlUi.allowedOrigins=["https://<app-fqdn>"]`. Do NOT include `gateway.auth.token` — the KV-injected `OPENCLAW_GATEWAY_TOKEN` env var supplies it. Use `az storage file upload` with the storage account key. Follow the tech runbook section 1.3 procedure. Confirm the Container App revision reaches `Running / Healthy` state after re-seed. Root cause: file on share had `"bind": "all"` (invalid). Fixed to `"bind": "lan"`. Revision reached `Running / Healthy` after upload + forcing activation. | ✅        | 2026-03-30 |

- GOAL-001: ~~Determine whether OpenClaw can be fully configured via environment variables~~ **CLOSED: Investigation complete. Findings recorded in the Introduction. The env-var-only path is NOT feasible. Proceed directly to Phase 2 alt (file-upload path).**

| Task     | Description                                                                                                                                                                                                                                                                                                                            | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | Inspect the OpenClaw image binary for env var support. Results: `OPENCLAW_GATEWAY_PORT` IS supported (env > config > default 18789). `OPENCLAW_GATEWAY_TOKEN` IS supported (env > config). `OPENCLAW_GATEWAY_MODE` NOT supported. `OPENCLAW_GATEWAY_BIND` NOT supported (dead Terraform env var). `OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS` NOT supported (dead Terraform env var). | ✅         | 2026-03-30 |
| TASK-002 | ~~Smoke test env-var-only start~~ **CLOSED: Not feasible. `gateway.mode` has no env var support; the config file is required.** | ✅         | 2026-03-30 |
| TASK-003 | Minimum required `openclaw.json` fields confirmed (via binary inspection and current dev failure analysis): `gateway.mode` (required, `"local"` or `"remote"`), `gateway.bind` (required for non-loopback operation), `gateway.controlUi.allowedOrigins` (required when binding non-loopback), `gateway.auth.mode` (required for token auth enforcement). `gateway.port` is optional (defaults to 18789). `gateway.auth.token` is NOT required when `OPENCLAW_GATEWAY_TOKEN` env var is set. | ✅         | 2026-03-30 |
| TASK-004 | CI SP permissions confirmed: `allowSharedKeyAccess` on dev storage account is `null` (defaults to `true` = enabled). The CI SP needs `Microsoft.Storage/storageAccounts/listKeys/action` to retrieve the key. This is included in the `Contributor` role — verify the CI SP has Contributor scope on the environment resource group in `terraform/roleassignments.tf`. | ✅         | 2026-03-30 |

### Implementation Phase 2 — Implementation (env-var path, preferred)

- GOAL-002: **CLOSED — NOT FEASIBLE.** `OPENCLAW_GATEWAY_MODE` and `OPENCLAW_GATEWAY_BIND` have no env var support. Proceed directly to Phase 2 alt (file-upload path). TASK-005–TASK-008 are cancelled.

### Implementation Phase 2 (alt) — Implementation (file-upload path, **required**)

- GOAL-003: Create a version-controlled config template and a workflow step that renders and uploads `openclaw.json` to Azure Files after `terraform apply`. **`auth.token` is NOT required in the template** — the KV-injected `OPENCLAW_GATEWAY_TOKEN` env var supplies it. Only `${APP_FQDN}` needs substitution at deploy time.

| Task     | Description                                                                                                                                                                                                                                                                                                                                      | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-009 | Create `config/openclaw.json.tpl` in the repo. The file must contain no secrets. Use only `${APP_FQDN}` as a substitution placeholder. Confirmed minimum content (from TASK-003 findings): `{ "gateway": { "mode": "local", "port": 18789, "bind": "lan", "auth": { "mode": "token" }, "controlUi": { "allowedOrigins": ["https://${APP_FQDN}"] } } }`. Do NOT include `auth.token` — the `OPENCLAW_GATEWAY_TOKEN` env var (KV-injected) handles it. | ✅        | 2026-03-30 |
| TASK-010 | In `.github/workflows/terraform-deploy.yml`, extend the `paths` filter to include `config/openclaw.json.tpl` so the workflow triggers on config template changes.                                                                                                                                                                                | ✅        | 2026-03-30 |
| TASK-011 | Add a `Seed OpenClaw Config` workflow step to both `terraform-dev` and `terraform-prod` jobs, placed immediately after `Terraform Apply`. The step must: (1) resolve `APP_FQDN` using `az containerapp show --name paa-${TF_VAR_environment}-app --resource-group paa-${TF_VAR_environment}-rg --query "properties.configuration.ingress.fqdn" -o tsv`; (2) substitute `${APP_FQDN}` into `config/openclaw.json.tpl` using `envsubst` (available on ubuntu-latest); (3) retrieve the storage account key via `az storage account keys list --account-name paa${TF_VAR_environment}ocstate --resource-group paa-${TF_VAR_environment}-rg --query "[0].value" -o tsv`; (4) upload the rendered file via `az storage file upload --share-name openclaw-state --path openclaw.json`; (5) delete the temp file immediately. All in `set -euo pipefail`. No Key Vault retrieval is required. | ✅        | 2026-03-30 |
| TASK-012 | Confirm the CI SP has `Microsoft.Storage/storageAccounts/listKeys/action` by checking its effective roles on the resource group. The `Contributor` built-in role includes this — verify the CI SP has `Contributor` (or at minimum `Storage Account Key Operator Service Role`) scoped to the environment resource groups. If missing, add a role assignment to `terraform/roleassignments.tf` for the CI SP. | ✅        | 2026-03-30 |
| TASK-013 | Remove dead Terraform env vars from `terraform/containerapp.tf`: `OPENCLAW_GATEWAY_BIND` and `OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS` are confirmed to have no effect on the OpenClaw binary. Remove them to avoid confusion. Also remove the `openclaw_control_ui_allowed_origins_json` Terraform variable from `terraform/variables.tf` and all references in the workflow `env` blocks and GitHub Environment variables (this variable is now replaced by the `APP_FQDN` substitution at deploy time). | ✅        | 2026-03-30 |

### Implementation Phase 3 — Ops runbook update

- GOAL-004: Update the ops runbook to reflect the automated config deployment, fix the `"mode": "server"` error, and mark the manual seed section as deprecated.

| Task     | Description                                                                                                                                                                                                                                                                        | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-014 | In `docs/openclaw-containerapp-operations.md` section 1.3, fix `"mode": "server"` → `"mode": "local"` in the heredoc template.                                                                                                                                                   | ✅        | 2026-03-30 |
| TASK-015 | If the env-var path (TASK-005–TASK-008) is taken, update section 1.3 to state that manual config seeding is no longer required and that all gateway config is managed via Terraform environment variables. Archive the heredoc as a reference snapshot only. |           |      |
| TASK-016 | If the file-upload path (TASK-009–TASK-013) is taken, update section 1.3 to describe the automated workflow seed step and note that manual re-seeding is only required for emergency out-of-band recovery. Update the heredoc to reference `config/openclaw.json.tpl` as the canonical source of truth. | ✅        | 2026-03-30 |

## 3. Alternatives

- **ALT-001**: Keep the manual seed process but improve it with a single `scripts/seed-openclaw-config.sh` script that wraps all the `az` commands. Rejected as primary approach — it still requires a human operator, creates SDLC drift, and does not make the config auditable in the PR review process. Acceptable as an emergency recovery script only (TASK-000 covers this for the immediate outage).
- **ALT-002**: Store `openclaw.json` as a Kubernetes ConfigMap equivalent using Azure Container Apps volume mounts sourced from an Azure Blob or Key Vault reference. Not available in Azure Container Apps at the time of writing — no native ConfigMap analogue exists for file-backed secrets.
- **ALT-003**: Use Azure App Configuration to externalize all gateway settings and have the container pull them at startup. Requires OpenClaw to natively support App Configuration, which is not the case. Rejected.
- **ALT-004** (previously preferred): Fully env-var-driven configuration without a config file. **Rejected — confirmed infeasible.** `OPENCLAW_GATEWAY_MODE` and `OPENCLAW_GATEWAY_BIND` have no env var equivalents. The config file cannot be eliminated.

## 4. Dependencies

- **DEP-001**: ~~Phase 1 investigation must complete before Phase 2~~ Phase 1 complete. Proceed to Phase 2 alt (TASK-009–TASK-013).
- **DEP-002**: ~~If the file-upload path is chosen, TASK-012 (role assignment evaluation) must complete before TASK-011~~ Confirmed: verify Contributor role for CI SP covers `listKeys` (TASK-012) before merging TASK-011.
- **DEP-003**: The fix to `"mode": "server"` in TASK-014 supersedes TASK-007 in [plan/feature-openclaw-startup-1.md](feature-openclaw-startup-1.md). Coordinate to avoid duplicate edits; this plan takes ownership of the runbook fix.
- **DEP-004**: `TF_VAR_OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS_JSON` will be **removed** from workflow env blocks and GitHub Environment variables as part of TASK-013 (it was a dead variable). The FQDN is now resolved dynamically in the seed step. Ensure this variable removal is coordinated before the workflow step is merged.

## 5. Files

- **FILE-001**: ~~`terraform/containerapp.tf` — add `OPENCLAW_GATEWAY_MODE` and `OPENCLAW_GATEWAY_PORT` env vars (env-var path)~~ **CANCELLED** (env-var path infeasible).
- **FILE-001b**: `terraform/containerapp.tf` — **REMOVE** dead env vars `OPENCLAW_GATEWAY_BIND` and `OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS` (TASK-013).
- **FILE-002**: `config/openclaw.json.tpl` — new committed config template with only `${APP_FQDN}` placeholder (no `${GATEWAY_TOKEN}` — token is KV-injected via env var).
- **FILE-003**: `.github/workflows/terraform-deploy.yml` — extend `paths` filter; add `Seed OpenClaw Config` step after `Terraform Apply` (TASK-010, TASK-011).
- **FILE-004**: `terraform/roleassignments.tf` — add storage listKeys role for CI SP if not already covered by Contributor (TASK-012).
- **FILE-005**: `docs/openclaw-containerapp-operations.md` — fix `"mode": "server"` error; update or deprecate section 1.3 (TASK-014–TASK-016).
- **FILE-006**: `terraform/variables.tf` — remove `openclaw_control_ui_allowed_origins_json` variable (TASK-013).

## 6. Testing

- **TEST-000**: TASK-000 — re-seed dev and confirm `Running / Healthy` via `bash scripts/diagnose-containerapp.sh dev`; section B must show `runningState: Running`, section G must show `gateway.mode=local` and non-empty `allowedOrigins`.
- **TEST-001**: Delete `openclaw.json` from the dev Azure Files share, trigger the workflow via a PR touching `config/openclaw.json.tpl`. Confirm the container revision reaches `Running / Healthy` state without manual intervention.
- **TEST-002**: Confirm the running revision's env vars (via `az containerapp show`) do NOT contain `OPENCLAW_GATEWAY_BIND` or `OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS` after TASK-013 is applied. Confirm `openclaw.json` is present on the share with `gateway.mode="local"` and the correct `controlUi.allowedOrigins` FQDN.
- **TEST-003**: Confirm the workflow run log shows no secret values in plain text (the gateway token must not appear in workflow step output).
- **TEST-004**: Merge to main and confirm the `terraform-prod` job seeds the prod config correctly. Verify via `bash scripts/diagnose-containerapp.sh prod` that the prod revision is `Running / Healthy`.
- **TEST-005**: Run the workflow a second time (no changes) and confirm idempotency: no errors, the existing `openclaw.json` is overwritten with identical content, revision is unchanged.

## 7. Risks & Assumptions

- **RISK-001** ~~OpenClaw may not support `OPENCLAW_GATEWAY_MODE`~~ **RESOLVED:** Confirmed not supported — file-upload path is required.
- **RISK-002**: The CI SP may not have `az storage account keys list` permission on the environment storage accounts. `allowSharedKeyAccess` is confirmed enabled. Contributor role covers `listKeys` — verify in TASK-012 before merging the workflow step.
- **RISK-003**: The workflow `paths` filter currently scopes triggers to `terraform/**`. Changes to `config/openclaw.json.tpl` will not trigger a re-deploy until TASK-010 extends the filter. Mitigation: TASK-010.
- **RISK-004**: `envsubst` is available on ubuntu-latest runners without installation (part of GNU gettext). Confirmed safe to use for `${APP_FQDN}` substitution.
- **RISK-005**: Removing `OPENCLAW_GATEWAY_BIND` and `OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS` from `containerapp.tf` (TASK-013) will cause a new Container App revision to be deployed on the next Terraform apply. This is expected and safe — the env vars had no effect on the running binary.
- **ASSUMPTION-001**: The Azure Files share (`openclaw-state`) is writable by the CI SP via the storage account key pattern. Confirmed: `allowSharedKeyAccess` is enabled.
- **ASSUMPTION-002** ~~Both dev and prod GitHub Environments have `TF_VAR_OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS_JSON` set~~ **SUPERSEDED:** This variable will be removed (TASK-013). The FQDN is resolved dynamically from `az containerapp show` in the workflow seed step.

## 8. Related Specifications / Further Reading

- [docs/openclaw-containerapp-operations.md](../docs/openclaw-containerapp-operations.md) — current manual seed procedure (section 1.3)
- [plan/feature-openclaw-startup-1.md](feature-openclaw-startup-1.md) — related bug fixes; TASK-007 ownership transferred to this plan
- [.github/workflows/terraform-deploy.yml](../.github/workflows/terraform-deploy.yml)
- [terraform/containerapp.tf](../terraform/containerapp.tf)
- [terraform/roleassignments.tf](../terraform/roleassignments.tf)
