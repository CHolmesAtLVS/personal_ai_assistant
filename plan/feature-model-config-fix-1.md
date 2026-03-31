---
goal: Fix OpenClaw model configuration — wrong baseUrl, missing memorySearch, broken test assertions
plan_type: standalone
version: 1.0
date_created: 2026-03-31
last_updated: 2026-03-31
owner: Platform Engineering
status: 'In Progress'
tags: [bug, openclaw, models, azure-ai-foundry, terraform, testing]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

`openclaw models status` confirms the Grok models are not reachable. Root cause analysis of `config/openclaw.json.tpl`, `terraform/containerapp.tf`, and `scripts/test-multi-model.sh` has identified three distinct bugs. None of these require new Azure resources — all fixes are in Terraform locals, the config template, and the test script.

---

## Root Cause Analysis

### Bug 1 — Wrong `baseUrl` for `azure-foundry` provider (PRIMARY)

**Symptom**: All Grok models fail with HTTP 400 or 404 when OpenClaw tries to call them.

The Terraform local `ai_inference_endpoint` is built as:
```hcl
format("%s/models", trimsuffix(...endpoints["Azure AI Model Inference API"]..., "/"))
```
This produces: `https://<account>.services.ai.azure.com/models`

OpenClaw's `openai-completions` adapter appends `/chat/completions` to `baseUrl`, resulting in:
```
POST https://<account>.services.ai.azure.com/models/chat/completions
```

This is the **deprecated** Azure AI Inference path which **requires** `?api-version=2024-05-01-preview`. OpenClaw does not append api-version parameters. Without it, Azure returns a 400.

The GA path — `https://<account>.services.ai.azure.com/openai/v1` — works without api-version:
```
POST https://<account>.services.ai.azure.com/openai/v1/chat/completions  ✅
```

**Fix**: Change the Terraform local to replace `/models` with `/openai/v1`. The env var `AZURE_AI_INFERENCE_ENDPOINT` will then carry the correct path automatically.

> **Note on the live inference test in `test-multi-model.sh`**: Section J explicitly appends `?api-version=2024-05-01-preview` to the curl call, so it passes even with the wrong base path. This creates a false positive — the direct API call succeeds but OpenClaw's own calls to the same URL (without api-version) fail. The test must be updated to use the `/openai/v1` path consistently.

---

### Bug 2 — `azure-foundry` test assertion checks a field that doesn't exist

**Symptom**: `test-multi-model.sh` reports FAIL on "azure-foundry auth" even when the config is correct.

The test script checks:
```bash
check_json_path "azure-foundry auth" ".models.providers[\"azure-foundry\"].auth" "api-key"
```

The corrected config (v4.0) uses `authHeader: false` + `headers: {"api-key": "..."}` — there is **no `.auth` field** in the provider object. The check therefore always fails the `path not found` branch.

The correct assertion is:
1. `.models.providers["azure-foundry"].authHeader == false`
2. `.models.providers["azure-foundry"].headers["api-key"]` is non-empty

---

### Bug 3 — `memorySearch` missing from `agents.defaults` (TASK-020b)

**Symptom**: `openclaw memory status --deep` reports embedding not configured; memory/RAG is non-functional.

The `azure-openai` entry in `models.providers` does not wire to memory operations. OpenClaw memory search requires a dedicated `agents.defaults.memorySearch` block (confirmed by voytas75 gist, v5.0 findings). The block is absent from the current template.

Additionally, the redundant `azure-openai` entry in `models.providers` has a malformed `baseUrl` (`properties.endpoint` = `https://...openai.azure.com/` without the required `/openai/v1` suffix) and should be removed.

---

## 1. Requirements & Constraints

- **REQ-001**: All fixes must be backward-compatible with the existing Terraform state. No resource recreation.
- **REQ-002**: `AZURE_AI_INFERENCE_ENDPOINT` env var value must change from `/models` path to `/openai/v1` path. This requires a Container App revision rollout (env var change).
- **REQ-003**: `openclaw.json.tpl` is a reference template only. The live config at `/home/node/.openclaw/openclaw.json` on the Azure Files share must be updated separately after template changes (ASSUMPTION-003 in the feature plan).
- **REQ-004**: Test script assertions must match the actual config schema after the fix.
- **CON-001**: The `/openai/v1` GA path must be reachable from the AI Services account. Confirmed working per voytas75 gist (Feb 2026) and Microsoft Tech Community blog.
- **CON-002**: `AZURE_OPENAI_ENDPOINT` (used for `memorySearch`) is `properties.endpoint` which has a trailing slash. The `/openai/v1` suffix must be appended in a way that avoids double-slash.
- **SEC-001**: No secrets are changed. `AZURE_AI_API_KEY` secret reference is unchanged.

---

## 2. Implementation Steps

### Implementation Phase 1 — Fix Terraform: endpoint paths

- GOAL-001: Correct both Azure endpoint locals so they carry the `/openai/v1` path, making the env vars directly usable in `openclaw.json.tpl` without string manipulation.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-001 | In `terraform/containerapp.tf`, change the `ai_inference_endpoint` local from `format("%s/models", ...)` to `format("%s/openai/v1", trimsuffix(...))`. This changes `AZURE_AI_INFERENCE_ENDPOINT` from `https://<account>.services.ai.azure.com/models` to `https://<account>.services.ai.azure.com/openai/v1`. | ✅ | 2026-03-31 |
| TASK-002 | In `terraform/containerapp.tf`, change the `AZURE_OPENAI_ENDPOINT` env value from `tostring(data.azapi_resource.ai_foundry.output.properties.endpoint)` to `format("%s/openai/v1", trimsuffix(tostring(data.azapi_resource.ai_foundry.output.properties.endpoint), "/"))`. This changes its value from `https://<account>.openai.azure.com/` to `https://<account>.openai.azure.com/openai/v1`. | ✅ | 2026-03-31 |
| TASK-003 | In `terraform/outputs.tf`, update the `ai_inference_endpoint` output description to reflect the `/openai/v1` GA path. No value change needed (the local drives the value). | ✅ | 2026-03-31 |

### Implementation Phase 2 — Fix `openclaw.json.tpl`

- GOAL-002: Remove the redundant `azure-openai` models provider (wrong path, not wired to memory), and add the correct `memorySearch` block so embeddings are actually used by OpenClaw memory/RAG.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-004 | Remove the `azure-openai` block from `models.providers` in `config/openclaw.json.tpl`. It is unused (not referenced in `agents.defaults.models`), has a malformed baseUrl, and is superseded by `memorySearch`. | ✅ | 2026-03-31 |
| TASK-005 | Add `memorySearch` to `agents.defaults` in `config/openclaw.json.tpl`:<br>`"memorySearch": { "provider": "openai", "remote": { "baseUrl": "${AZURE_OPENAI_ENDPOINT}", "apiKey": "${AZURE_AI_API_KEY}" }, "model": "${AZURE_OPENAI_DEPLOYMENT_EMBEDDING}" }`. With TASK-002 applied, `${AZURE_OPENAI_ENDPOINT}` resolves to `https://<account>.openai.azure.com/openai/v1` — the correct base for the OpenAI embeddings API. | ✅ | 2026-03-31 |
| TASK-006 | Since `TASK-002` now bakes `/openai/v1` into the env var, update the `azure-foundry.baseUrl` comment (or inline documentation) in the template to note the env var already includes the full path. No JSON value change needed for `azure-foundry.baseUrl` — `${AZURE_AI_INFERENCE_ENDPOINT}` is now correct. | ✅ | 2026-03-31 |

### Implementation Phase 3 — Fix test script assertions

- GOAL-003: Bring `test-multi-model.sh` assertions in sync with the corrected auth pattern and endpoint paths, and add a `memorySearch` presence check.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-007 | In `scripts/test-multi-model.sh`, remove `EXPECTED_PROVIDER_AUTH="api-key"` and the `check_json_path "azure-foundry auth" ...` assertion. Replace with two checks: (a) `.models.providers["azure-foundry"].authHeader == false`, (b) `.models.providers["azure-foundry"].headers["api-key"]` is non-empty. | ✅ | 2026-03-31 |
| TASK-008 | In `scripts/test-multi-model.sh` Section J (live inference), update `BASE` to use the `/openai/v1` path instead of the deprecated `/models` path with `api-version`. Change: `BASE="${AZURE_AI_INFERENCE_ENDPOINT}/chat/completions?api-version=2024-05-01-preview"` → `BASE="${AZURE_AI_INFERENCE_ENDPOINT}/chat/completions"`. With `AZURE_AI_INFERENCE_ENDPOINT` now pointing to `/openai/v1`, this resolves correctly without needing the query parameter. | ✅ | 2026-03-31 |
| TASK-009 | Add a `memorySearch` config presence check to the remote config validation section: assert `.agents.defaults.memorySearch.provider == "openai"` and `.agents.defaults.memorySearch.model` is non-empty. | ✅ | 2026-03-31 |
| TASK-010 | Add a `EXPECTED_AZURE_OPENAI_ENDPOINT_SUFFIX` guard: after downloading the share config, assert that `${AZURE_OPENAI_ENDPOINT}` (resolved value from env) ends in `/openai/v1`. This catches any future drift where the env var loses the suffix. | ✅ | 2026-03-31 |

### Implementation Phase 4 — Update live config on Azure Files share

- GOAL-004: Propagate the corrected template to the live `openclaw.json` on the Azure Files share and trigger a gateway reload. This is the step that will make `openclaw models status` report models as available.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-011 | Run `terraform apply` in dev to push the updated `AZURE_AI_INFERENCE_ENDPOINT` and `AZURE_OPENAI_ENDPOINT` env vars into the Container App. This triggers a revision rollout. Wait for the revision to be ready. | | |
| TASK-012 | After the revision is ready, update `openclaw.json` on the Azure Files share. Options in order of preference: (a) `openclaw configure --section model` via the CLI (hot-reloads, no restart), (b) direct file upload via `az storage file upload` using the corrected config rendered from the template, (c) `az containerapp exec` with `openclaw configure` if CLI pairing fails. | | |
| TASK-013 | Verify via `openclaw models status` that `azure-foundry/grok-4-fast-reasoning`, `azure-foundry/grok-3`, and `azure-foundry/grok-3-mini` are all reported as available and reachable. | | |
| TASK-014 | Verify via `openclaw memory status --deep` that the embedding model is configured and the memory provider is healthy. | | |

### Implementation Phase 5 — Update parent feature plan

- GOAL-005: Mark TASK-020b complete in `feature-ai-multi-model-1.md` and record the baseUrl fix as a new finding.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-015 | Update `plan/feature-ai-multi-model-1.md` to v6.0: add v6.0 research findings section documenting Bug 1 (wrong baseUrl path), Bug 2 (auth assertion), Bug 3 (missing memorySearch). Mark TASK-020b complete. Update the open question about the endpoint URL. | | |

---

## 3. Alternatives

- **ALT-001**: **Keep `/models` path and append `?api-version=2024-05-01-preview` explicitly** — OpenClaw custom providers may support static `queryParams` in the provider config. If so, this avoids changing the Terraform env var. Rejected: no `queryParams` field is documented in `openclaw.json` schema; the GA `/openai/v1` path is the correct long-term solution in any case.
- **ALT-002**: **Set `baseUrl` in `openclaw.json.tpl` to a hardcoded value rather than env var** — Avoids the Terraform change. Rejected: violates REQ-003 of the parent feature plan (env var substitution is mandatory for auditability).
- **ALT-003**: **Keep `azure-openai` in `models.providers` and fix its baseUrl** — The provider is never used for chat or memory and would remain dead config. Rejected per gist findings (v5.0): `memorySearch` is the correct hook; the models provider entry is redundant.

---

## 4. Dependencies

- **DEP-001**: `terraform apply` in dev must succeed for TASK-011. Requires Terraform state to be initialized and the service principal to have Contributor on the resource group.
- **DEP-002**: `openclaw configure` or an Azure Files upload requires either CLI pairing or storage account key access.

---

## 5. Files

- **FILE-001**: `terraform/containerapp.tf` — fix `ai_inference_endpoint` local and `AZURE_OPENAI_ENDPOINT` env var value.
- **FILE-002**: `config/openclaw.json.tpl` — remove `azure-openai` from `models.providers`, add `memorySearch`.
- **FILE-003**: `scripts/test-multi-model.sh` — fix `EXPECTED_PROVIDER_AUTH` check, update Section J `BASE` URL, add `memorySearch` assertion.
- **FILE-004**: `plan/feature-ai-multi-model-1.md` — update to v6.0 with findings and mark TASK-020b complete.

---

## 6. Testing

- **TEST-001**: After TASK-001 + TASK-002, `terraform plan` shows only the two env var value changes — no resource recreation.
- **TEST-002**: After TASK-011, `az containerapp show ... --query "properties.template.containers[0].env"` confirms `AZURE_AI_INFERENCE_ENDPOINT` = `https://<account>.services.ai.azure.com/openai/v1`.
- **TEST-003**: After TASK-012, `openclaw models status` shows all three Grok models available.
- **TEST-004**: After TASK-014, `openclaw memory status --deep` shows embedding provider healthy.
- **TEST-005**: Full run of `bash scripts/test-multi-model.sh dev` produces 0 FAILs.

---

## 7. Risks & Assumptions

- **RISK-001**: **`/openai/v1` path may not be enabled on the AI Services account** — If the account was provisioned before the GA path was available, it may require an upgrade or re-registration. Mitigation: confirm with a direct `curl` test before Terraform apply: `curl -s -o /dev/null -w "%{http_code}" -H "api-key: $KEY" -H "Content-Type: application/json" -d '{"model":"grok-4-fast-reasoning","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' "https://<account>.services.ai.azure.com/openai/v1/chat/completions"`. Expected: 200 or 429 (not 404).
- **RISK-002**: **Config on Azure Files share is stale / manual sync required** — TASK-012 must be performed manually after TASK-011. If the share config is not updated, the model fix will not take effect even after the revision rollout.
- **ASSUMPTION-001**: `properties.endpoint` from the azapi data source has a trailing slash that `trimsuffix(..., "/")` correctly strips.
- **ASSUMPTION-002**: OpenClaw `memorySearch.remote.baseUrl` = `https://<account>.openai.azure.com/openai/v1` (without trailing slash) is the correct format. The gist uses this pattern.
- **ASSUMPTION-003**: `AZURE_AI_API_KEY` is also valid for the Azure OpenAI embeddings endpoint on the same AI Services account. This is the same account used for `AZURE_OPENAI_ENDPOINT`, so the same key covers both endpoints.

---

## 8. Related Specifications / Further Reading

- [feature-ai-multi-model-1.md](../plan/feature-ai-multi-model-1.md) — parent feature plan; this plan resolves bugs found post-implementation.
- [config/openclaw.json.tpl](../config/openclaw.json.tpl) — gateway config template.
- [terraform/containerapp.tf](../terraform/containerapp.tf) — Container App and env var definitions.
- [scripts/test-multi-model.sh](../scripts/test-multi-model.sh) — validation script.
- Azure AI Inference `/openai/v1` GA path: `https://learn.microsoft.com/en-us/azure/ai-services/openai/reference`
- voytas75 working gist (v5.0 source): `https://gist.github.com/voytas75/e6960a8f67f0b7b4d4e72cb4d4ae5999`
