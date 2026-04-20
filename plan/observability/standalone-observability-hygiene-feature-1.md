---
goal: Observability & Hygiene — Availability alerting, failed-request signals, dependency reviews, and cluster/pod health using built-in OpenClaw tooling
plan_type: standalone
version: 1.0
date_created: 2026-04-20
owner: Platform operator / individual instance owners
status: 'Planned'
tags: [observability, hygiene, health, security, alerting, dependencies]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

This plan establishes a lightweight but complete observability and hygiene practice for the OpenClaw deployment on AKS.  The philosophy is **OpenClaw-first**: where the product ships a built-in tool (`openclaw health`, `openclaw doctor`, `openclaw security audit`, `openclaw status`) it is used in preference to bespoke infrastructure monitoring.  Infrastructure signals (AKS cluster events, Key Vault audit logs, Log Analytics) serve only where no OpenClaw equivalent exists.

The outcome is a set of runbooks, scheduled checks, and alert rules that keep the deployment available, secure, and up-to-date without heavy operational overhead.

---

## 1. Requirements & Constraints

- **REQ-001**: All health-check and diagnostic commands must be executable from the management workstation via the `openclaw` CLI (using `./scripts/openclaw-connect.sh` to connect to the remote gateway).
- **REQ-002**: Availability signal must distinguish "gateway unreachable" from "channel degraded" — the two require different remediation paths.
- **REQ-003**: Security audit findings that are `critical` must block the next release or config change until resolved or explicitly waived.
- **REQ-004**: The `openclaw doctor` and `openclaw security audit` commands must be run against the **dev** instance before any config change is promoted to prod.
- **REQ-005**: All operational commands must target the `dev` environment first; prod commands require explicit operator confirmation per project Non-Negotiable Rules.
- **SEC-001**: `openclaw status --all` output (redacted) is the preferred shareable diagnostic artefact — do not paste raw log files.
- **SEC-002**: Security alert findings must not be committed to Git or shared in public channels — treat `checkId` values and finding details as operationally sensitive.
- **CON-001**: The AKS cluster runs on `Standard_B2s` nodes; avoid scheduling additional monitoring workloads that would crowd out OpenClaw pods.
- **CON-002**: OpenClaw gateway config (`gateway.*`) changes require a pod restart and must be coordinated to avoid availability gaps.
- **GUD-001**: Prefer `openclaw health --json` for machine-readable outputs in any automation scripts.
- **GUD-002**: Use `openclaw doctor --non-interactive` (safe migrations only) in automated/CI contexts; always review interactively before using `--repair`.
- **PAT-001**: Follow the Health Checks doc flow: `openclaw status` → `openclaw health --verbose` → deep diagnostics only when the first two indicate a problem.
- **PAT-002**: Follow the Security doc priority order for audit findings: open+tools > public network exposure > browser control > permissions > plugins > model choice.

---

## 2. Implementation Steps

### Phase 1 — Baseline: Instrument Health Checks

- **GOAL-001**: Establish the canonical health-check commands and verify they work for every deployed instance (dev + prod).

| Task     | Description                                                                                                                                                                                                                                                                     | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | For each instance, run `openclaw status --all` and confirm output is reachable and parseable. Document any instance that requires a different `--gateway` flag due to URL or token differences in a per-instance note in `docs/observability-notes.md`.                           |           |      |
| TASK-002 | For each instance, run `openclaw health --json` and pipe output through `jq '.ok'` to verify the boolean health signal works. Record the baseline `durationMs` as the p50 probe-time reference for future SLA comparisons.                                                       |           |      |
| TASK-003 | Verify the `/status` WhatsApp shortcut works for each instance (send `/status` as a standalone DM and confirm a status reply is returned). This confirms the end-to-end channel path is alive independent of the CLI.                                                            |           |      |
| TASK-004 | Confirm that `gateway.channelHealthCheckMinutes` is set (default `5`) and `gateway.channelStaleEventThresholdMinutes` is set (default `30`) for every instance. These built-in health-monitor settings are the primary availability watchdog for channel connectivity.           |           |      |
| TASK-005 | Document the standard triage sequence in `docs/observability-runbook.md`: (1) `openclaw status`, (2) `openclaw health --verbose`, (3) `openclaw status --deep`, (4) consult logs at `/tmp/openclaw/openclaw-*.log` filtered for `web-heartbeat\|web-reconnect\|web-auto-reply`. |           |      |

### Phase 2 — Unified OpenClaw Observability Workflow

- **GOAL-002**: Run `openclaw health`, `openclaw doctor`, and `openclaw security audit` for every instance on a daily schedule. Upload the full results to a private Azure Blob container on every run — whether clean or not. If any issues are detected, open (or update) a GitHub Issue containing only a one-line severity summary and a time-limited SAS URL pointing to the full report in the private blob. No technical details — no instance hostnames, checkIds, channel names, or error payloads — appear in the issue body.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-006 | Add an observability blob storage account to `terraform/storage.tf`: `Standard_LRS`, blob-only, named `{project}{env}obs` (max 24 chars, lowercase alphanumeric). Add a private blob container named `observability-reports`. Add a lifecycle management policy: delete blobs older than 90 days. Declare a `terraform output "obs_storage_account_name"` so the value can be stored as a GitHub Variable (`OPENCLAW_OBS_STORAGE_ACCOUNT`) after `terraform apply`.                                                                                                                                                                                                                                                                                                        |           |      |
| TASK-007 | Grant the existing GitHub Actions SP the `Storage Blob Data Contributor` role scoped to the `observability-reports` container. Declare as `azurerm_role_assignment` in `terraform/storage.tf`. This enables blob upload and user-delegation SAS token generation without a storage account key (`az storage blob generate-sas --auth-mode login`).                                                                                                                                                                                                                                                                                                                                                                                                                        |           |      |
| TASK-008 | Create `scripts/check-openclaw.sh`: for a single instance, (a) run `openclaw health --json --timeout 15000` (capture output + exit code); (b) run `openclaw doctor --non-interactive` (capture stdout/stderr + exit code); (c) run `openclaw security audit --json` (capture output + exit code). If any command is unreachable, set its output to `null` and flag as failed. Bundle the three raw outputs and a computed summary — `{"health_ok": bool, "health_channel_degraded": bool, "doctor_exit": int, "audit_critical": int, "audit_warn": int, "instance": str, "env": str, "ts": "ISO8601"}` — into a single JSON report. Upload to `observability-reports/{env}/{instance}/{YYYY-MM-DD-HHMMSS}.json` via `az storage blob upload --auth-mode login`. Generate a read-only user-delegation SAS URL (`--permissions r`, 7-day expiry) via `az storage blob generate-sas --auth-mode login --full-uri`. Print the summary object and SAS URL to stdout. Accept `OPENCLAW_GATEWAY_URL`, `OPENCLAW_GATEWAY_TOKEN`, `OPENCLAW_OBS_STORAGE_ACCOUNT` as env vars. Do not print gateway URL, token, or raw OpenClaw output to the workflow log. |           |      |
| TASK-009 | Create `scripts/check-openclaw-all.sh`: reads the instance list, retrieves each instance's gateway token from Key Vault via `az keyvault secret show --auth-mode login`, calls `check-openclaw.sh` for each instance, collects per-instance summary + SAS URL. Outputs a JSON array: `[{"instance": "ch", "env": "dev", "health_ok": true, "doctor_exit": 0, "audit_critical": 0, "audit_warn": 1, "sas_url": "https://..."}]`. Exits non-zero if any instance has `health_ok: false`, `health_channel_degraded: true`, `doctor_exit != 0`, or `audit_critical > 0`.                                                                                                                                                                                               |           |      |
| TASK-010 | Create `.github/workflows/openclaw-health.yml`: cron `0 6 * * *` (daily at 06:00 UTC). Steps: (a) `az login` with existing SP credentials from GitHub Secrets; (b) export `OPENCLAW_OBS_STORAGE_ACCOUNT` from GitHub Variables; (c) run `scripts/check-openclaw-all.sh` and capture the output JSON; (d) for each instance reporting issues, open or update a GitHub Issue. **Issue title**: `[Alert] OpenClaw health issue — {instance} ({env}) — {YYYY-MM-DD}`. **Issue body**: severity summary line only (e.g. `health: FAIL, doctor: warnings, audit: 1 critical 3 warn`) and the SAS URL — no hostnames, checkIds, channel details, or error payloads. Deduplicate: if an open issue for the same instance+env already exists, add a comment with the new SAS URL instead of opening a duplicate; close it automatically when the next run is clean. If all instances are clean, no issue is created or modified. |           |      |

### Phase 3 — Failed-Request Signals

- **GOAL-003**: Establish the set of failed-request signals worth monitoring and map each to the correct OpenClaw diagnostic surface.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                    | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-011 | Define the three failed-request signal tiers and document them in `docs/observability-runbook.md`: (1) **Gateway unreachable or degraded** — detected by `openclaw health` in the daily workflow (TASK-008); (2) **Channel degraded** — detected by per-channel parsing in the daily workflow (TASK-008); (3) **Model error** — AI Foundry 4xx/5xx visible in Log Analytics, handled separately by an Azure Monitor alert (TASK-014). Tiers 1 and 2 route through the blob + SAS Issue path; tier 3 routes through Azure Monitor email only. |           |      |
| TASK-012 | In `check-openclaw.sh` (TASK-008), parse the `openclaw health --json` per-channel section: if `.ok == true` but any channel entry has a non-ok status, set `health_channel_degraded: true` in the summary object. The daily workflow treats `health_channel_degraded: true` as an issue requiring a GitHub Issue with SAS URL. Document the remediation path in the runbook: `openclaw channels logout && openclaw channels login --verbose` for `loggedOut` or `409–515` status codes. |           |      |
| TASK-013 | For model-error detection, create a Log Analytics query (`docs/log-analytics-queries.md`) that surfaces 4xx/5xx responses from the AI Services endpoint over the last 24 hours: filter `AzureDiagnostics` on `ResourceType == "COGNITIVESERVICES/ACCOUNTS"` and `httpStatusCode_d >= 400`. Include the query as a saved query in the Log Analytics workspace.  |           |      |
| TASK-014 | Wire the model-error query into an Azure Monitor Alert rule (action group: existing budget email action group). Threshold: ≥5 errors in 15 minutes. Document the alert rule in Terraform (`terraform/logging.tf`) as a `azurerm_monitor_scheduled_query_rules_alert_v2` resource so it is version-controlled and reproducible.                                  |           |      |
| TASK-015 | Add a section to `docs/observability-runbook.md` covering the model-error remediation path: (1) check `openclaw status --all` for auth-profile cooldown/disabled state; (2) run `openclaw doctor` to check OAuth expiry and refresh tokens; (3) if quota-exceeded, check AI Foundry quota in Azure Portal and adjust `model_capacity` in the central tfvars.  |           |      |

### Phase 4 — Security Hygiene: Regular `openclaw security audit`

- **GOAL-004**: Embed `openclaw security audit` into the daily workflow (Phase 2) and as a PR gate to catch configuration drift before it reaches production. The daily workflow (TASK-008–010) handles scheduled auditing with full results stored privately in blob storage. The PR gate provides a lightweight blocking check at change time.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                  | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-016 | Establish the security audit baseline: after the first clean daily workflow run for each instance, download the corresponding blob report (`az storage blob download --auth-mode login`) and record only the severity counts (`critical: 0, warn: N, info: N`) in `docs/observability-runbook.md` as the approved baseline. Do not commit raw JSON (contains checkIds). Store raw baselines locally or in a private Key Vault secret if historical comparison is needed.                                                                      |           |      |
| TASK-017 | Add a security audit gate to the GitHub Actions workflow that runs on every PR to `dev`: (a) run `openclaw security audit --json` against the dev instance for the author's instance (or all instances if the change is config-wide); (b) fail the CI job if any `critical` finding is present; (c) write a PR comment with severity counts only — no finding details, no checkIds. Use `openclaw security audit --json \| jq '.findings \| group_by(.severity) \| map({(.[0].severity): length}) \| add'` to produce the summary. |           |      |
| TASK-018 | Document the audit-finding priority order from the Security docs in `docs/observability-runbook.md` (open+tools → public network exposure → browser control → permissions → plugins → model choice). For each severity level, define the required response time: critical within 24 hours, warn within 7 days (or waived with documented rationale).                          |           |      |
| TASK-019 | Establish a monthly `openclaw security audit --deep` ritual: run on the first Monday of each month for all prod instances, review all findings against the baseline (TASK-016), and record any new critical/warn items in the security section of `docs/observability-runbook.md`. Resolve or waive with documented rationale before the next release.                        |           |      |
| TASK-020 | When `openclaw security audit --fix` is used to auto-remediate (file permission flips, `logging.redactSensitive` restore, allowlist tightening), run `openclaw doctor` immediately after to confirm config is still valid and the gateway remains healthy. Document this two-step pattern explicitly in the runbook.                                                            |           |      |

### Phase 5 — Dependency Review: `openclaw doctor` and Version Cadence

- **GOAL-005**: Keep the OpenClaw image version, plugin/skill dependencies, and OAuth tokens current and healthy through a regular review cadence.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                            | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-021 | The daily workflow (TASK-008) runs `openclaw doctor --non-interactive` automatically for all instances. For interactive repair before a config promotion, run `openclaw doctor` (without `--non-interactive`) on the dev instance and resolve all warnings. Pay particular attention to: legacy config key migrations (§2), model auth health / OAuth expiry (§5), plugin compatibility (§11), and gateway runtime best practices (§17). Do not promote to prod until the daily workflow blob report for that instance shows `doctor_exit: 0`. |           |      |
| TASK-022 | Track the deployed `openclaw_image_tag` in the central tfvars. Create a bi-weekly reminder (GitHub Actions scheduled workflow, cron `0 9 * * 1` every two weeks) that fetches the latest tag from `ghcr.io/openclaw/openclaw` via `gh api /orgs/openclaw/packages/container/openclaw/versions` and opens a GitHub issue if the deployed tag is more than one minor version behind the latest release.  |           |      |
| TASK-023 | For plugins installed on any instance (`openclaw plugins list`), run `openclaw plugins update --dry-run` monthly and review the output for: unpinned npm specs (`hooks.installs_unpinned_npm_specs`), missing integrity (`hooks.installs_missing_integrity`), and version drift (`hooks.installs_version_drift`). Apply updates in dev first, validate with `openclaw doctor`, then promote to prod.   |           |      |
| TASK-024 | For skills installed on any instance (`openclaw skills list`), verify that all skills in `skills-lock.json` remain pinned to immutable specs. Run `openclaw security audit` and check for `skills.code_safety` and `skills.code_safety.scan_failed` findings after any new skill installation.                                                                                                         |           |      |
| TASK-025 | Review GitHub Dependabot alerts and `detect-secrets` pre-commit hook failures on the repo's own code (Terraform, shell scripts, YAML) weekly. Any new secret-candidate in `.secrets.baseline` must be resolved (rotate + remove or mark as false positive) before merging to `dev`.                                                                                                                     |           |      |

### Phase 6 — Cluster/Pod Health (Infrastructure Complement)

- **GOAL-006**: Cover the infrastructure-level signals that have no OpenClaw CLI equivalent, keeping them minimal to avoid duplicating what `openclaw health` already provides.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                         | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-026 | Add an AKS diagnostic setting for pod restarts to Log Analytics (`ContainerLog` + `KubeEvents` tables). Create a Log Analytics alert: any pod in `openclaw-*` namespace restarting more than 3 times in 10 minutes → email via existing action group. Document as `azurerm_monitor_scheduled_query_rules_alert_v2` in `terraform/logging.tf`.                                      |           |      |
| TASK-027 | Add a Key Vault diagnostic alert for secret-access failures: query `AzureDiagnostics` where `OperationName == "SecretGet"` and `ResultType != "Success"` — threshold ≥3 in 5 minutes → email alert. This catches CSI secret-sync failures before they surface as a pod crashloop.                                                                                                   |           |      |
| TASK-028 | Document the pod-restart remediation sequence in `docs/observability-runbook.md`: (1) `kubectl get events -n openclaw-{inst}`; (2) `openclaw health --verbose`; (3) `openclaw doctor --non-interactive`; (4) check CSI mount status with `kubectl describe pod`; (5) if NFS mount failed, verify `azurerm_storage_share` exists and MI has `Storage Account Contributor` role.     |           |      |
| TASK-029 | Add a monthly cost-hygiene step: review the Consumption Budget alert threshold in `terraform/costs.tf` and compare against actual spend in Azure Cost Management. If actual spend is trending above 80% of budget, record the finding in the monthly runbook review log (`docs/observability-runbook.md` hygiene section) and verify the existing `azurerm_consumption_budget_resource_group` alert threshold is still appropriate — adjust it in `terraform/costs.tf` if needed and apply via a PR to `dev`. |           |      |

### Phase 7 — Runbook and Documentation

- **GOAL-007**: Consolidate all observability and hygiene procedures into a single, actionable runbook.

| Task     | Description                                                                                                                                                                                                                                                                                                              | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-030 | Create `docs/observability-runbook.md` with these sections: (1) Quick triage commands, (2) Alert definitions and thresholds, (3) Remediation playbooks per alert type, (4) Cadence calendar (daily/weekly/monthly/bi-weekly tasks), (5) Security audit procedures, (6) Dependency review checklist, (7) Incident response reference (from Security docs).                      |           |      |
| TASK-031 | Add the cadence calendar to the runbook as a markdown table:  (a) **Per-PR**: `openclaw security audit` in CI (TASK-017), `detect-secrets` pre-commit (TASK-025); (b) **Bi-weekly**: image version check (TASK-022); (c) **Monthly**: `openclaw security audit --deep` (TASK-019), plugin update review (TASK-023), skill audit (TASK-024), cost review (TASK-029); (d) **Ad-hoc**: `openclaw doctor` before/after any config change (TASK-021). |           |      |

---

## 3. Alternatives

- **ALT-001**: **Prometheus + Grafana stack on AKS**: rejected — adds significant resource pressure to `Standard_B2s` nodes and duplicates what `openclaw health` already surfaces natively. Grafana dashboards would need custom exporters to extract the meaningful signal (channel health, model auth state) that `openclaw health --json` provides for free.
- **ALT-002**: **Azure Monitor Application Insights SDK instrumentation**: rejected — requires code changes to the upstream OpenClaw container; the paid OpenClaw product ships its own health and doctor surfaces that are authoritative for its internal state.
- **ALT-003**: **External uptime monitors (e.g. UptimeRobot, Pingdom)**: out of scope — the gateway is IP-restricted to a home IP, so external probes would always fail. The GitHub Actions probe approach (TASK-006–TASK-010) runs from inside the allowed network context via SP credentials.
- **ALT-005**: **Azure Monitor DCE/DCR custom table for openclaw-specific alerting**: considered but replaced — wires probe results to a `Standard_LRS` blob and surfaces the SAS URL via a GitHub Issue instead. The DCE/DCR approach requires a custom table schema, an immutable DCR ID as a GitHub Variable, a `Monitoring Metrics Publisher` role assignment, and query-rule alert infrastructure. The blob+SAS+Issue approach achieves the same notification outcome with fewer moving parts, keeps all technical detail in a private store, and uses the GitHub Issue only as a pointer containing no sensitive content.
- **ALT-006**: **Post full report details directly in the GitHub Issue body**: rejected — instance hostnames, channel status details, checkIds, and gateway error payloads are operationally sensitive and must not appear in a public or semi-public repository. The SAS URL approach keeps all technical detail in the private blob.
- **ALT-004**: **Datadog / New Relic**: rejected — cost overhead disproportionate to personal-scale deployment; and again, the most important internal state (channel health, config drift, security posture) is only visible through OpenClaw's own CLI.

---

## 4. Dependencies

- **DEP-001**: `openclaw` CLI must be installed and able to connect to each instance's gateway via `./scripts/openclaw-connect.sh`. Required by all Phase 1–5 tasks.
- **DEP-002**: GitHub Actions SP credentials must have: (a) `Key Vault Secrets User` on the environment vault (to retrieve gateway tokens in TASK-009); (b) `Storage Blob Data Contributor` on the `observability-reports` container (to upload blobs and generate user-delegation SAS tokens in TASK-008). Both role assignments are declared in Terraform (TASK-006, TASK-007).
- **DEP-003**: Log Analytics Workspace must have `ContainerLog` and `KubeEvents` diagnostic categories enabled for the AKS cluster (TASK-026). Verify with `az monitor diagnostic-settings list` on the AKS resource.
- **DEP-004**: `jq` must be available in the GitHub Actions runner (ubuntu-latest ships it by default).
- **DEP-005**: The observability storage account name must be captured from `terraform output obs_storage_account_name` after TASK-006 is applied and stored as a GitHub Variable (`OPENCLAW_OBS_STORAGE_ACCOUNT`) before TASK-010's workflow can run. This is a non-secret infrastructure identifier — do not store it as a GitHub Secret.

---

## 5. Files

- **FILE-001**: `scripts/check-openclaw.sh` — per-instance probe: runs `openclaw health`, `openclaw doctor`, `openclaw security audit`; bundles full report JSON; uploads to blob; returns summary + SAS URL (TASK-008)
- **FILE-002**: `scripts/check-openclaw-all.sh` — iterates instances, retrieves KV tokens, drives `check-openclaw.sh`, aggregates results (TASK-009)
- **FILE-003**: `.github/workflows/openclaw-health.yml` — daily scheduled workflow: invokes `check-openclaw-all.sh`; creates/updates GitHub Issues with SAS URL on failures only; auto-closes when clean (TASK-010)
- **FILE-004**: `.github/workflows/version-check.yml` — bi-weekly image version drift check (TASK-022)
- **FILE-005**: `docs/observability-runbook.md` — consolidated runbook (TASK-030–TASK-031)
- **FILE-006**: `docs/log-analytics-queries.md` — saved KQL queries for model-error and pod-restart signals (TASK-013)
- **FILE-007**: `terraform/storage.tf` — observability `Standard_LRS` blob storage account, `observability-reports` container, 90-day lifecycle policy, `Storage Blob Data Contributor` role assignment for SP, `obs_storage_account_name` output (TASK-006, TASK-007)
- **FILE-008**: `terraform/logging.tf` — model-error alert rule, pod-restart alert rule, Key Vault secret-sync alert rule (TASK-014, TASK-026, TASK-027)

---

## 6. Testing
workflow with failure path: (a) disable a gateway token temporarily in dev; (b) run `check-openclaw.sh` manually for that instance — confirm a blob appears in `observability-reports/dev/{inst}/` (`az storage blob list --auth-mode login`) and the SAS URL is printed to stdout; (c) confirm the blob contains `"health_ok": false`; (d) trigger the workflow manually (`workflow_dispatch`) and confirm a GitHub Issue is created with only the severity summary line and SAS URL in the body; (e) re-enable the token, trigger again — confirm the issue is closed automatically and a new clean blob exists. Validates TASK-006–TASK-010.
- **TEST-002**: Channel-degraded path: force a channel `loggedOut` state in dev. Run `check-openclaw.sh` — confirm the report blob contains `"health_channel_degraded": true` and `"health_ok": true`, and that the workflow creates a GitHub Issue. Validates TASK-012 minutes (query via `az monitor log-analytics query -w <workspace-id> --analytics-query 'OpenClawHealth_CL | where InstanceId == "<inst>" | order by TimeGenerated desc | take 5'`), and confirm an email alert is received within the alert evaluation window (≤20 minutes). Restore the token and confirm subsequent probes return `Ok: true` (validates TASK-006–TASK-010).
- **TEST-002**: Channel-degraded detection: force a channel `loggedOut` state in dev, confirm `check-health.sh` exits with a channel-degraded flag rather than a gateway-unreachable flag (validates TASK-012).
- **TEST-003**: Security audit CI gate: introduce a deliberate `critical` finding in a dev PR (e.g. set `gateway.auth.mode: "none"` temporarily in a branch), confirm the CI step fails and posts a PR comment (validates TASK-017).
- **TEST-004**: `openclaw doctor` clean run: after completing all Phase 4 tasks, run `openclaw doctor --non-interactive` on a dev instance and confirm zero warnings (validates TASK-021).
- **TEST-005**: Key Vault alert: revoke the CSI secret-sync MI role assignment temporarily in dev, confirm the Key Vault diagnostic alert fires within 5 minutes (validates TASK-027).

---

## 7. Risks & Assumptions

- **RISK-001**: The daily cron (`0 6 * * *`) means worst-case detection latency for a failure that occurs just after 06:00 UTC is ~24 hours. This is deliberate — OpenClaw has its own built-in channel health-monitor that restarts degraded channels automatically (TASK-004), so the daily workflow is a hygiene and audit check rather than a real-time pager. If tighter latency is needed, reduce the cron frequency or add a `workflow_dispatch` trigger for ad-hoc runs.
- **RISK-002**: `openclaw health --json` output schema may change between OpenClaw releases. Pin the `jq` paths to known field names (`.ok`, `.channels[]`, `.durationMs`) and run TASK-022's version-drift check to surface breaking changes before they hit prod.
- **RISK-003**: If the SP credentials in GitHub Secrets rotate without being updated, `check-openclaw-all.sh` will fail to retrieve gateway tokens from Key Vault and fail to upload blobs — both silently, meaning no issues are raised even when instances are unhealthy. This is a silent-sentinel failure mode. Mitigation: re-run TEST-001 after every SP credential rotation; also confirm the workflow's most recent Actions run did not fail with an `az login` error.
- **RISK-004**: `openclaw security audit --fix` applies narrow, well-defined repairs (file permissions, `logging.redactSensitive`, open-policy tightening). It does not auto-fix network exposure or token-rotation findings. Operators must review the full `--json` output for the remaining findings every time `--fix` is run.
- **ASSUMPTION-001**: All instances are reachable from the GitHub Actions runner via the same SP token / Key Vault token-retrieval path used for Terraform CI today.
- **ASSUMPTION-002**: The existing Log Analytics Workspace has diagnostic settings for the AKS cluster already configured by Terraform (`terraform/logging.tf`). Alert rules added in Phase 6 extend the existing resource, not replace it.

---

## 8. Related Specifications / Further Reading

- [ARCHITECTURE.md](../../ARCHITECTURE.md) — AKS cluster, Log Analytics, Key Vault topology
- [OpenClaw Health Checks](https://docs.openclaw.ai/gateway/health) — `openclaw health`, `openclaw status` reference
- [OpenClaw Doctor](https://docs.openclaw.ai/gateway/doctor) — full doctor command reference and repair behaviors
- [OpenClaw Security](https://docs.openclaw.ai/gateway/security) — security audit, threat model, hardened baseline, incident response
- [plan/personal-setup/standalone-personal-assistant-setup-guide-1.md](../personal-setup/standalone-personal-assistant-setup-guide-1.md) — per-instance setup guide (prerequisite)
