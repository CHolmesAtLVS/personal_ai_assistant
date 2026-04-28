#!/usr/bin/env bash
# test-openclaw.sh — OpenClaw AKS integration test runner
#
# Usage:
#   bash scripts/test-openclaw.sh [dev|prod]
#
# Prerequisites:
#   - kubectl configured for the target cluster
#   - jq, curl on PATH
#
# Sections:
#   A. ArgoCD sync + pod readiness
#   B. Health probes  — /healthz + /readyz via kubectl port-forward
#   C. Config assertions — image tag, envFrom, volume mount, live config values
#   D. Log scan — crash/fatal indicator check
#   E. Live inference — end-to-end Azure OpenAI chat completions from pod
#
# Exit: 0 = all passed, 1 = one or more failed
# GITHUB_STEP_SUMMARY is written to if set (GitHub Actions only).

set -uo pipefail

ENV="${1:-}"
if [[ "${ENV}" != "dev" && "${ENV}" != "prod" ]]; then
  echo "Usage: bash scripts/test-openclaw.sh [dev|prod]" >&2
  exit 1
fi

# ── Instance registry ─────────────────────────────────────────────────────────
case "${ENV}" in
  dev)
    ARGOCD_APPS=(ch-openclaw-dev jh-openclaw-dev)
    TEST_NAMESPACES=(openclaw-ch openclaw-jh)
    ;;
  prod)
    ARGOCD_APPS=(ch-openclaw-prod jh-openclaw-prod kjm-openclaw-prod)
    TEST_NAMESPACES=(openclaw-ch openclaw-jh openclaw-kjm)
    ;;
esac

# Path to the inference Node.js script (relative to repo root or absolute).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFERENCE_SCRIPT="${SCRIPT_DIR}/test-openclaw-inference.js"

# ── Helpers ───────────────────────────────────────────────────────────────────
PASS=0; FAIL=0
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

step_summary() { [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && printf '%s\n' "$*" >> "${GITHUB_STEP_SUMMARY}" || true; }
pass()    { echo "  PASS  $*"; (( PASS++ )) || true; step_summary "  PASS  $*"; }
fail()    { echo "  FAIL  $*" >&2; (( FAIL++ )) || true; step_summary "  FAIL  $*"; }
section() { echo ""; echo "── $* ────────────────────────────────────────────────────────────"; }

# ── Banner ────────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " OpenClaw integration tests  env=${ENV}  ${TIMESTAMP}"
echo " Instances: ${TEST_NAMESPACES[*]}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
step_summary "## OpenClaw ${ENV^^} Integration Tests — ${TIMESTAMP}"
step_summary ""

# ══════════════════════════════════════════════════════════════════════════════
# A. ArgoCD sync + pod readiness
# ══════════════════════════════════════════════════════════════════════════════
section "A. ArgoCD sync + pod readiness"
step_summary "### A. ArgoCD sync + pod readiness"
step_summary '```'

ARGOCD_TIMEOUT=600
ARGOCD_INTERVAL=15

# POD_FOR[<namespace>] is populated here and reused by sections C and E
# to avoid redundant (and potentially flaky) pod lookups.
declare -A POD_FOR

for APP in "${ARGOCD_APPS[@]}"; do
  ELAPSED=0
  echo "  Waiting for ArgoCD to sync ${APP}..."
  until [[ "$(kubectl get application "${APP}" -n argocd \
        -o jsonpath='{.status.sync.status}' 2>/dev/null || true)" == "Synced" ]]; do
    if [[ $ELAPSED -ge $ARGOCD_TIMEOUT ]]; then
      fail "Timeout waiting for ArgoCD sync: ${APP} (${ARGOCD_TIMEOUT}s)"; break
    fi
    sleep "${ARGOCD_INTERVAL}"
    ELAPSED=$(( ELAPSED + ARGOCD_INTERVAL ))
  done

  SYNC_STATUS="$(kubectl get application "${APP}" -n argocd \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  if [[ "${SYNC_STATUS}" == "Synced" ]]; then
    pass "ArgoCD Synced: ${APP}"
  fi

  TARGET_NS="$(kubectl get application "${APP}" -n argocd \
    -o jsonpath='{.spec.destination.namespace}' 2>/dev/null || true)"
  if kubectl rollout status deployment/openclaw -n "${TARGET_NS}" --timeout=5m 2>&1; then
    pass "Pod ready: ${TARGET_NS}"
  else
    fail "Pod not ready: ${TARGET_NS}"
  fi

  # Cache the running pod name for this namespace.
  POD_FOR["${TARGET_NS}"]="$(kubectl get pods -n "${TARGET_NS}" \
    -l app.kubernetes.io/instance=openclaw \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
done
step_summary '```'

# ══════════════════════════════════════════════════════════════════════════════
# B. Health probes — /healthz + /readyz via port-forward
# ══════════════════════════════════════════════════════════════════════════════
section "B. Health probes"
step_summary "### B. Health probes"
step_summary '```'

for NS in "${TEST_NAMESPACES[@]}"; do
  echo "--- ${NS} ---"
  step_summary "--- ${NS} ---"

  READY="$(kubectl get endpoints openclaw -n "${NS}" \
    -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null \
    | grep -c . 2>/dev/null || echo 0)"
  if (( READY < 1 )); then
    fail "no ready endpoints — ${NS}"; continue
  fi

  PORT="$(kubectl get svc openclaw -n "${NS}" -o jsonpath='{.spec.ports[0].port}')"
  kubectl port-forward "svc/openclaw" -n "${NS}" "18080:${PORT}" \
    >/tmp/pf-"${NS}".log 2>&1 &
  PF_PID=$!
  sleep 3

  for PROBE in healthz readyz; do
    PROBE_OK=0
    for _ in $(seq 1 15); do
      HTTP=$(curl -so /dev/null -w "%{http_code}" --max-time 5 \
        "http://127.0.0.1:18080/${PROBE}" 2>/dev/null || echo "000")
      if [[ "${HTTP}" == "200" ]]; then PROBE_OK=1; break; fi
      sleep 2
    done
    if (( PROBE_OK )); then
      pass "/${PROBE} HTTP 200 — ${NS}"
    else
      fail "/${PROBE} no 200 response — ${NS}"
      cat "/tmp/pf-${NS}.log" 2>/dev/null | head -10 || true
    fi
  done

  kill "${PF_PID}" >/dev/null 2>&1 || true
done
step_summary '```'

# ══════════════════════════════════════════════════════════════════════════════
# C. Config assertions — deployment spec + live pod config values
# ══════════════════════════════════════════════════════════════════════════════
section "C. Config assertions"
step_summary "### C. Config assertions"
step_summary '```'

for NS in "${TEST_NAMESPACES[@]}"; do
  echo "--- ${NS} ---"
  step_summary "--- ${NS} ---"
  DEP="$(kubectl get deployment openclaw -n "${NS}" -o json)"

  # Image tag must not be :latest
  IMAGE="$(echo "${DEP}" | jq -r '.spec.template.spec.containers[] | select(.name=="main") | .image // empty')"
  if [[ -z "${IMAGE}" ]]; then
    fail "no main container image — ${NS}"
  elif echo "${IMAGE}" | grep -q ':latest$'; then
    fail "image uses :latest tag — ${IMAGE} — ${NS}"
  else
    pass "image pinned — ${IMAGE}"
  fi

  # envFrom must reference both the secret and the configmap
  ENV_FROM="$(echo "${DEP}" | jq -r '
    .spec.template.spec.containers[] | select(.name=="main") |
    (.envFrom[]?.secretRef.name // empty), (.envFrom[]?.configMapRef.name // empty)' \
    | sort | uniq)"
  if echo "${ENV_FROM}" | grep -q "openclaw-env-secret" \
      && echo "${ENV_FROM}" | grep -q "openclaw-env-config"; then
    pass "envFrom: env-secret + env-config present — ${NS}"
  else
    fail "envFrom missing env-secret or env-config — ${NS} (found: $(echo "${ENV_FROM}" | tr '\n' ' '))"
  fi

  # Persistent state volume must be mounted
  MOUNTS="$(echo "${DEP}" | jq -r '
    .spec.template.spec.containers[] | select(.name=="main") | .volumeMounts[]?.mountPath' 2>/dev/null)"
  if echo "${MOUNTS}" | grep -q "/home/node/.openclaw"; then
    pass "volume mount /home/node/.openclaw present — ${NS}"
  else
    fail "volume mount /home/node/.openclaw missing — ${NS}"
  fi

  # All remaining checks require a running pod
  POD="${POD_FOR[${NS}]:-}"
  if [[ -z "${POD}" ]]; then
    fail "no running pod for exec checks — ${NS}"; continue
  fi

  # oc_config_get retries for up to 60 s to tolerate OpenClaw startup
  # initialization (pod may still be merging config when first called).
  oc_config_get() {
    local KEY="$1" VAL="" WAITED=0
    while [[ $WAITED -lt 60 ]]; do
      VAL="$(kubectl exec -n "${NS}" "${POD}" -c main -- \
        node /app/openclaw.mjs config get "${KEY}" 2>/dev/null | tr -d '"' || true)"
      [[ -n "${VAL}" && "${VAL}" != "null" ]] && break
      sleep 5; WAITED=$(( WAITED + 5 ))
    done
    echo "${VAL}"
  }

  # Primary model must be azure-openai/*
  MODEL="$(oc_config_get agents.defaults.model.primary)"
  if echo "${MODEL}" | grep -q "^azure-openai/"; then
    pass "primary model = ${MODEL}"
  else
    fail "primary model '${MODEL}' (expected azure-openai/*) — ${NS}"
  fi

  # azure-openai provider baseUrl must be set
  BASE_URL="$(oc_config_get models.providers.azure-openai.baseUrl)"
  if [[ -n "${BASE_URL}" && "${BASE_URL}" != "null" ]]; then
    pass "azure-openai baseUrl configured — ${NS}"
  else
    fail "azure-openai baseUrl empty or missing — ${NS}"
  fi

  # memorySearch.enabled must be true
  MS_ENABLED="$(oc_config_get agents.defaults.memorySearch.enabled)"
  if [[ "${MS_ENABLED}" == "true" ]]; then
    pass "memorySearch.enabled = true — ${NS}"
  else
    fail "memorySearch.enabled = '${MS_ENABLED}' (expected true) — ${NS}"
  fi
done
step_summary '```'

# ══════════════════════════════════════════════════════════════════════════════
# D. Log scan — no crash/fatal indicators in recent container logs
# ══════════════════════════════════════════════════════════════════════════════
section "D. Log scan"
step_summary "### D. Log scan"
step_summary '```'

for NS in "${TEST_NAMESPACES[@]}"; do
  echo "--- ${NS} ---"
  step_summary "--- ${NS} ---"
  CRASH="$(kubectl logs -n "${NS}" deployment/openclaw -c main --tail=100 2>/dev/null \
    | grep -iE "crash|panic|fatal|OOMKilled|unhandledRejection|exit code [^0 ]" \
    | grep -ivE "pairing required|closed before connect|trustedProxies" \
    | head -5 || true)"
  if [[ -n "${CRASH}" ]]; then
    fail "crash/fatal indicators — ${NS}:"
    echo "${CRASH}" | sed 's/^/    /'
  else
    pass "no crash indicators — ${NS}"
  fi
done
step_summary '```'

# ══════════════════════════════════════════════════════════════════════════════
# E. Live inference — end-to-end Azure OpenAI chat completions from the pod
# Validates: pod env vars → AZURE_AI_API_KEY → Azure OpenAI endpoint → response
# ══════════════════════════════════════════════════════════════════════════════
section "E. Live inference"
step_summary "### E. Live inference"
step_summary '```'

if [[ ! -f "${INFERENCE_SCRIPT}" ]]; then
  fail "inference script not found: ${INFERENCE_SCRIPT}"
else
  for NS in "${TEST_NAMESPACES[@]}"; do
    echo "--- ${NS} ---"
    step_summary "--- ${NS} ---"

    POD="${POD_FOR[${NS}]:-}"
    if [[ -z "${POD}" ]]; then
      fail "no running pod — ${NS}"; continue
    fi

    # Stream the Node.js script into the pod via stdin — avoids shell quoting issues.
    RESULT="$(kubectl exec -i -n "${NS}" "${POD}" -c main -- node - \
      < "${INFERENCE_SCRIPT}" 2>/dev/null || echo 'FAIL:exec error')"

    if echo "${RESULT}" | grep -q "^PASS:"; then
      REPLY="$(echo "${RESULT}" | grep "^PASS:" | cut -d: -f2-)"
      pass "inference ok, model replied: '${REPLY}' — ${NS}"
    else
      fail "inference failed: ${RESULT} — ${NS}"
    fi
  done
fi
step_summary '```'

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Results — env=${ENV}: ${PASS} passed, ${FAIL} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
step_summary ""
step_summary "## Summary — ${ENV^^}"
step_summary "| | Count |"
step_summary "| --- | --- |"
step_summary "| ✅ Passed | ${PASS} |"
step_summary "| ❌ Failed | ${FAIL} |"

[[ "${FAIL}" -eq 0 ]]
