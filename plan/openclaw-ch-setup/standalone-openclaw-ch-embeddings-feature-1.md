---
goal: Enable Azure AI Foundry embeddings for OpenClaw-ch memory search (dev + prod)
plan_type: standalone
version: 1.0
date_created: 2026-04-29
owner: Platform operator
status: 'Planned'
tags: [openclaw, ch, embeddings, memory, foundry, feature]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

OpenClaw's semantic memory recall requires an embedding provider.
The Reddit community confirmed the correct pattern for Azure AI Foundry: set `memorySearch.provider` to `"openai"` and supply an explicit `remote` block with the Azure OpenAI legacy endpoint.

The `text-embedding-3-large` deployment already exists in Azure AI Foundry (Terraform `ai_model_deployments.embedding`).  
The required environment variables (`AZURE_OPENAI_ENDPOINT`, `AZURE_AI_API_KEY`) are already injected into ch pods via `openclaw-env-config` / `openclaw-env-secret`.

The bug is that both prod and dev `openclaw-ch` `values.yaml` files specify the wrong provider type for `memorySearch`:
- **Prod**: `provider: "azure-openai-responses"` — the Responses API is a chat API, not embeddings.
- **Dev**: provider/remote/model fields are entirely absent.

The canonical correct config is already in `config/openclaw.batch.json` and must be reflected in the Helm values.

## 1. Requirements & Constraints

- **REQ-001**: `memorySearch` must use `provider: "openai"` with an explicit `remote.baseUrl` pointing to `${AZURE_OPENAI_ENDPOINT}/openai/v1/` (Azure OpenAI legacy endpoint, not the AI Services endpoint).
- **REQ-002**: `memorySearch.model` must be set to `"text-embedding-3-large"` — the deployment name that exists in Azure AI Foundry and is captured by `TF_VAR_EMBEDDING_MODEL_NAME`.
- **REQ-003**: `remote.apiKey` must reference `${AZURE_AI_API_KEY}` (Key Vault–injected); no literal keys in source.
- **REQ-004**: Both dev and prod `openclaw-ch` values.yaml files must be updated and kept consistent.
- **REQ-005**: The `store.vector.enabled: false` setting must be preserved in both files (vector store is not yet provisioned).
- **CON-001**: No secrets may be committed to source; use `${VAR}` substitution only.
- **CON-002**: Changes target the `dev` branch. PRs target `dev` per branch model.
- **GUD-001**: `openclaw.batch.json` is the canonical reference config — the Helm values must match its `memorySearch` structure.
- **PAT-001**: Follow the Reddit-confirmed pattern: `provider: "openai"`, `remote.baseUrl`, `remote.apiKey`, `model: "text-embedding-3-large"`.

## 2. Implementation Steps

### Implementation Phase 1 — Fix prod openclaw-ch memorySearch config

- GOAL-001: Replace the incorrect `provider: "azure-openai-responses"` with the `openai` provider pattern and add the `remote` block in `workloads/prod/openclaw-ch/values.yaml`.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | ✅ | In `workloads/prod/openclaw-ch/values.yaml`, locate the `"memorySearch"` JSON block (currently: `"provider": "azure-openai-responses"`, `"model": "text-embedding-3-large"`, `"store": { "vector": { "enabled": false } }`). Replace it with: `"provider": "openai"`, `"remote": { "baseUrl": "${AZURE_OPENAI_ENDPOINT}/openai/v1/", "apiKey": "${AZURE_AI_API_KEY}" }`, `"model": "text-embedding-3-large"`, `"store": { "vector": { "enabled": false } }`. Preserve `"enabled": true`. The resulting block must match the structure in `config/openclaw.batch.json` lines 27–31. |           |      |

**Exact replacement for TASK-001** — change this existing block in `workloads/prod/openclaw-ch/values.yaml`:

```json
                  "memorySearch": {
                    "enabled": true,
                    "provider": "azure-openai-responses",
                    "model": "text-embedding-3-large",
                    "store": {
                      "vector": {
                        "enabled": false
                      }
                    }
                  }
```

to:

```json
                  "memorySearch": {
                    "enabled": true,
                    "provider": "openai",
                    "remote": {
                      "baseUrl": "${AZURE_OPENAI_ENDPOINT}/openai/v1/",
                      "apiKey": "${AZURE_AI_API_KEY}"
                    },
                    "model": "text-embedding-3-large",
                    "store": {
                      "vector": {
                        "enabled": false
                      }
                    }
                  }
```

### Implementation Phase 2 — Fix dev openclaw-ch memorySearch config

- GOAL-002: Add the missing `provider`, `remote`, and `model` fields to `workloads/dev/openclaw-ch/values.yaml`.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-002 | Add `azure-openai-embeddings` provider (`api: openai`) to `models.providers` in dev ch values.yaml and set `memorySearch.provider` + `model` to reference it. | ✅ | 2026-04-29 |

**Exact replacement for TASK-002** — change this existing block in `workloads/dev/openclaw-ch/values.yaml`:

```json
                  "memorySearch": {
                    "enabled": true,
                    "store": {
                      "vector": {
                        "enabled": false
                      }
                    }
                  }
```

to:

```json
                  "memorySearch": {
                    "enabled": true,
                    "provider": "openai",
                    "remote": {
                      "baseUrl": "${AZURE_OPENAI_ENDPOINT}/openai/v1/",
                      "apiKey": "${AZURE_AI_API_KEY}"
                    },
                    "model": "text-embedding-3-large",
                    "store": {
                      "vector": {
                        "enabled": false
                      }
                    }
                  }
```

### Implementation Phase 3 — Update issue tracking

- GOAL-003: Mark ISSUE-3 resolved in the existing setup tracking document.

| Task     | Description                                                                                                                                                                                                                                           | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-003 | In `plan/openclaw-ch-setup/standalone-openclaw-ch-setup-issues-1.md`, update **ISSUE-3** status from `Open` to `In Progress`. Add a note referencing this plan and the canonical custom-provider fix. | ✅ | 2026-04-29 |

### Implementation Phase 4 — Deploy and verify

- GOAL-004: Confirm embeddings become active after pod restart triggered by ArgoCD sync.

| Task     | Description                                                                                                                                                                                                                                           | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-004 | Commit changes to a feature branch, open PR targeting `dev`. After merge and ArgoCD sync, verify the prod ch pod restarts with the new ConfigMap. Run `openclaw doctor --non-interactive` (via `openclaw-connect.sh ch prod`) and confirm embedding provider status is no longer flagged as missing. |           |      |
| TASK-005 | Run a test memory write + retrieval turn via the ch interface (e.g., tell the agent a fact, then ask it to recall it in a new session). Confirm the embedding API call succeeds in pod logs: `kubectl logs -n openclaw-ch <pod> -c main --tail=50 \| grep -i embed`. |           |      |

## 3. Alternatives

- **ALT-001**: Configure a separate named provider (e.g., `azure-openai-embeddings`) in `models.providers` and reference it by name in `memorySearch.provider`. This is cleaner for multi-provider setups but adds config surface for what is a single-purpose endpoint. The inline `remote` block approach matches community-confirmed patterns and `openclaw.batch.json`.
- **ALT-002**: Enable the vector store (`store.vector.enabled: true`) backed by an Azure AI Search or pgvector instance for persistent long-term memory. Deferred — vector store infra not yet provisioned (tracked separately).
- **ALT-003**: Use Managed Identity for the embedding endpoint instead of API key. Azure AI Foundry supports Managed Identity for the `openai.azure.com` embeddings path via `Cognitive Services OpenAI User` role (already assigned per ARCHITECTURE.md). The `openai` provider's `remote.apiKey` approach is simpler and already proven. Managed Identity upgrade is a separately tracked improvement.

## 4. Dependencies

- **DEP-001**: `AZURE_OPENAI_ENDPOINT` env var — already injected via `openclaw-env-config` ConfigMap from the bootstrap secrets seeding process. The `-ch` workloads share this ConfigMap with the main `openclaw` instance in the same namespace.
- **DEP-002**: `AZURE_AI_API_KEY` env var — already injected via `openclaw-env-secret` (Key Vault CSI sync). Same shared secret.
- **DEP-003**: `text-embedding-3-large` model deployment in Azure AI Foundry — already provisioned by Terraform (`ai_model_deployments.embedding` in `terraform/ai.tf`).
- **DEP-004**: ArgoCD sync — changes in `workloads/prod/openclaw-ch/values.yaml` trigger a pod rollout via the `openclaw-appset-prod.yaml` ApplicationSet.

## 5. Files

- **FILE-001**: `workloads/prod/openclaw-ch/values.yaml` — Primary change: `memorySearch` provider fix (Phase 1).
- **FILE-002**: `workloads/dev/openclaw-ch/values.yaml` — Primary change: `memorySearch` provider + fields addition (Phase 2).
- **FILE-003**: `plan/openclaw-ch-setup/standalone-openclaw-ch-setup-issues-1.md` — ISSUE-3 status update (Phase 3).
- **FILE-004**: `config/openclaw.batch.json` — Read-only reference; already correct. No changes required.

## 6. Testing

- **TEST-001**: `openclaw doctor --non-interactive` output must not report a missing embedding provider after pod restart.
- **TEST-002**: Pod logs (`kubectl logs -n openclaw-ch <pod> -c main`) must show successful embedding API calls (no 401/404 errors for the embeddings path) during a memory-enabled agent turn.
- **TEST-003**: Run a two-session recall test: session 1 — inject a unique fact; session 2 — ask the agent to recall it. Semantic result must surface the injected fact.

## 7. Risks & Assumptions

- **RISK-001**: The `AZURE_OPENAI_ENDPOINT` env var in `-ch` pods resolves to the `openai.azure.com` legacy endpoint. If it resolves to the AI Services endpoint instead, the `/openai/v1/` path may return 404 for embeddings. Verify with `openclaw doctor` output after rollout.
- **RISK-002**: The `text-embedding-3-large` deployment name must match `var.embedding_model_name` exactly. If the deployment was given a custom name differing from the model name, update `"model"` in the config to match the actual Azure deployment name.
- **ASSUMPTION-001**: `openclaw-env-config` in the `openclaw-ch` namespace contains `AZURE_OPENAI_ENDPOINT`. The `-ch` values.yaml references this ConfigMap name, and the main `openclaw` bootstrap in the same namespace seeds it. If shared-namespace assumptions are incorrect, a separate `bootstrap/configmap.yaml` under `workloads/prod/openclaw-ch/bootstrap/` may be needed (mirroring `workloads/prod/openclaw/bootstrap/configmap.yaml`).
- **ASSUMPTION-002**: OpenClaw `2026.4.8` treats the `openai` provider type as a standard OpenAI-compatible embeddings client (not a chat client), matching the Reddit-confirmed behavior.

## 8. Related Specifications / Further Reading

- [ISSUE-3 in openclaw-ch setup tracker](standalone-openclaw-ch-setup-issues-1.md)
- [openclaw.batch.json canonical config reference](../../config/openclaw.batch.json)
- [ARCHITECTURE.md — embedding endpoint notes](../../ARCHITECTURE.md)
- [secrets-inventory.md — TF_VAR_EMBEDDING_MODEL_NAME](../../docs/secrets-inventory.md)
- [terraform/ai.tf — embedding deployment block](../../terraform/ai.tf)
- Reddit thread: r/AZURE — "Has anyone figured out how to use OpenClaw with Azure AI Foundry embeddings?" (2026-02)
