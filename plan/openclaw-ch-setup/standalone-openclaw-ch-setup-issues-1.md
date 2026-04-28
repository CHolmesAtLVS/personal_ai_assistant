---
goal: Resolve open issues found during initial openclaw-ch prod health check
plan_type: standalone
version: 1.0
date_created: 2026-04-28
owner: Platform operator
status: In Progress
tags: [openclaw, ch, prod, setup, health, channels, model, memory]
---

# openclaw-ch Prod — Setup Issues

Discovered during initial CLI health check on 2026-04-28.
Gateway: `https://ch-paa.acmeadventure.ca` · Pod: `openclaw-78f44cd67b-2bc8f` · App: `2026.4.8`

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

**Status:** Open  
**Symptom:** `doctor` reports no embedding provider ready. Checked openai, google, voyage, mistral — all missing API keys.  
**Impact:** Semantic memory recall disabled for agent `main`.  
**Fix (pick one):**
- Set `OPENAI_API_KEY` / `GEMINI_API_KEY` etc. via Key Vault + SecretProviderClass and reference via `${VAR}` in config
- Or disable: `openclaw config set agents.defaults.memorySearch.enabled false`

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
