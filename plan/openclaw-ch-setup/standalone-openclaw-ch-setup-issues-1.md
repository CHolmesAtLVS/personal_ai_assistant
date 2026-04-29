---
goal: Resolve open issues found during initial openclaw-ch prod health check
plan_type: standalone
version: 1.0
date_created: 2026-04-28
owner: Platform operator
status: In Progress
tags: [openclaw, ch, prod, setup, health, channels, model, memory]
---

# All Instances — Setup Issues

Originally discovered on openclaw-ch prod during initial CLI health check on 2026-04-28; confirmed to apply to all instances (ch, jh, kjm, main) on 2026-04-29.
Reference gateway: `https://ch-paa.acmeadventure.ca` · Pod: `openclaw-78f44cd67b-2bc8f` · App: `2026.4.8`

---

## ISSUE-1: Stale session transcript (agent history will reset)

**Status:** Open  
**Symptom:** `openclaw doctor` reports 1/1 sessions missing transcript.  
Session: `37603e47-69d9-49c2-9392-300a9b20c1ff` in `/home/node/.openclaw/agents/main/sessions/sessions.json`  
**Impact:** Agent `main` shows last active 20d ago; history appears reset on next turn.  
**Fix:**
```bash
openclaw sessions cleanup \
  --store "/home/node/.openclaw/agents/main/sessions/sessions.json" \
  --enforce --fix-missing
```

---

## ISSUE-2: No LLM model credentials configured

**Status:** Open  
**Symptom:** Agent is `bootstrapping` (0 active). No auth profiles in `/home/node/.openclaw/agents/main/agent/auth-profiles.json`.  
**Impact:** Gateway serves the UI but cannot process any agent turns.  
**Fix:** Configure Azure AI Foundry as the model backend (per ARCHITECTURE.md):
```bash
openclaw configure --section model
```
Use `${VAR}` substitution in `openclaw.json`; do not embed keys directly.

---

## ISSUE-3: Memory search / embeddings not configured

**Status:** In Progress  
**Symptom:** `doctor` reports no embedding provider ready / `Unknown memory embedding provider` error in running pods.  
**Impact:** Semantic memory recall disabled for agent `main` on all instances.  
**Scope (confirmed 2026-04-29):** Affects all instances — ch, jh, kjm, and main (openclaw).

| Instance | Dev fixed | Prod fixed |
|---|---|---|
| openclaw | 2026-04-29 | 2026-04-29 |
| openclaw-ch | 2026-04-29 | 2026-04-29 |
| openclaw-jh | 2026-04-29 | 2026-04-29 |
| openclaw-kjm | N/A | 2026-04-29 |

**Fix applied:** Added `azure-openai-embeddings` provider to `models.providers` (`api: "openai"`, `baseUrl: "${AZURE_OPENAI_ENDPOINT}/openai/v1/"`, `apiKey: "${AZURE_AI_API_KEY}"`) and set `memorySearch.provider: "azure-openai-embeddings"`, `model: "text-embedding-3-large"` in all instance `values.yaml` files. The main `openclaw` instances (dev + prod) had no `memorySearch` block at all — full block added. See `plan/openclaw-ch-setup/standalone-openclaw-ch-embeddings-feature-1.md` for original ch embeddings plan.  
**Pending:** ArgoCD sync for all instances + `openclaw doctor` verification per instance.

---

## ISSUE-4: No channels configured

**Status:** Open  
**Symptom:** `openclaw status --all` shows empty channels table.  
**Impact:** No Telegram/Discord/etc. — users cannot interact with the agent.  
**Fix:**
```bash
openclaw configure          # full interactive wizard
# or scope to channels:
openclaw channels login --verbose
```

---

## ISSUE-5: AKS workload node kubelet crash (transient)

**Status:** Resolved (self-healed)  
**Symptom:** Node `aks-workload-39853944-vmss000002` went `NotReady` at ~16:12 UTC.  
Cause: kubelet / containerd stopped responding; `KubeletIsDown` + `ContainerRuntimeIsDown` conditions fired.  
**Impact during outage:** `kubectl exec` returned 502 (Konnectivity tunnel down); pod remained running but was unreachable for direct exec.  
**Resolved:** AKS auto-repair brought node back `Ready` at 16:16 UTC (~4 min outage). Pod was unaffected.  
**Note:** Monitor recurrence via Log Analytics — repeated kubelet crashes on `Standard_B2s` may indicate memory pressure.
