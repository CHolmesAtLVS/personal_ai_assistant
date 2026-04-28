#!/usr/bin/env bash
# test-openclaw.sh — OpenClaw AKS integration test runner
#
# Usage:
#   bash scripts/test-openclaw.sh [dev|prod]
#
# Prerequisites:
#   - kubectl configured for the target cluster
#   - jq, curl, python3 on PATH
#
# Sections:
#   A. ArgoCD sync + pod readiness
#   B. Health probes  — /healthz + /readyz via kubectl port-forward
#   C. Log scan — crash/fatal indicator check
#   D. Gateway chat test — POST /v1/chat/completions through OpenClaw
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

# SKIP_NS[<namespace>]=1 when pod readiness failed — all subsequent sections skip it.
declare -A SKIP_NS

for APP in "${ARGOCD_APPS[@]}"; do
  ELAPSED=0
  # Force ArgoCD to re-fetch from Git so it detects any recent commits
  # (e.g. post-merge smoke test running before ArgoCD's polling interval fires).
  kubectl annotate application "${APP}" -n argocd \
    argocd.argoproj.io/refresh=normal --overwrite 2>/dev/null || true
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
    SKIP_NS["${TARGET_NS}"]=1
    echo "  Skipping further tests for ${TARGET_NS} — pod not ready."
  fi
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

  if [[ -n "${SKIP_NS[${NS}]:-}" ]]; then
    echo "  SKIP  pod not ready — ${NS}"
    step_summary "  SKIP  pod not ready — ${NS}"
    continue
  fi

  READY="$(kubectl get endpoints openclaw -n "${NS}" \
    -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null \
    | wc -l | tr -d '[:space:]')"
  READY="${READY:-0}"
  if [[ "${READY}" -lt 1 ]]; then
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
# C. Log scan — no crash/fatal indicators in recent container logs
# ══════════════════════════════════════════════════════════════════════════════
section "C. Log scan"
step_summary "### C. Log scan"
step_summary '```'

for NS in "${TEST_NAMESPACES[@]}"; do
  echo "--- ${NS} ---"
  step_summary "--- ${NS} ---"
  if [[ -n "${SKIP_NS[${NS}]:-}" ]]; then
    echo "  SKIP  pod not ready — ${NS}"
    step_summary "  SKIP  pod not ready — ${NS}"
    continue
  fi
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
# D. Gateway chat test — POST /v1/chat/completions through OpenClaw
# Validates the full stack: gateway auth → agent routing → Azure OpenAI → response
# ══════════════════════════════════════════════════════════════════════════════
section "D. Gateway chat test"
step_summary "### D. Gateway chat test"
step_summary '```'

for NS in "${TEST_NAMESPACES[@]}"; do
  echo "--- ${NS} ---"
  step_summary "--- ${NS} ---"

  if [[ -n "${SKIP_NS[${NS}]:-}" ]]; then
    echo "  SKIP  pod not ready — ${NS}"
    step_summary "  SKIP  pod not ready — ${NS}"
    continue
  fi

  # Read the gateway token from the Kubernetes secret.
  GW_TOKEN="$(kubectl get secret openclaw-env-secret -n "${NS}" \
    -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' 2>/dev/null \
    | base64 -d 2>/dev/null || true)"
  if [[ -z "${GW_TOKEN}" ]]; then
    fail "gateway token unavailable from openclaw-env-secret — ${NS}"; continue
  fi

  # Port-forward to the OpenClaw service.
  kubectl port-forward "svc/openclaw" -n "${NS}" "18082:18789" \
    >/tmp/pf-chat-"${NS}".log 2>&1 &
  PF_PID=$!
  sleep 3

  # POST a chat message to the OpenClaw gateway HTTP API.
  # model=openclaw/default routes to the configured default agent (per OpenClaw docs).
  CHAT_REQUEST='{"model":"openclaw/default","messages":[{"role":"user","content":"Reply with exactly one word: OK"}],"max_tokens":20}'
  CHAT_RESPONSE="$(curl -s --max-time 45 \
    -X POST \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer ${GW_TOKEN}" \
    -d "${CHAT_REQUEST}" \
    http://127.0.0.1:18082/v1/chat/completions 2>/dev/null || echo 'CURL_FAIL')"

  kill "${PF_PID}" >/dev/null 2>&1 || true

  REPLY="$(echo "${CHAT_RESPONSE}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['choices'][0]['message']['content'].strip())
except Exception as e:
    print('PARSE_ERROR: ' + str(e)[:100])
" 2>/dev/null || echo 'PARSE_ERROR')"

  if [[ -n "${REPLY}" && "${REPLY}" != PARSE_ERROR* && "${REPLY}" != 'CURL_FAIL' ]]; then
    pass "gateway chat ok, replied: '${REPLY}' — ${NS}"
  else
    fail "gateway chat failed — ${NS}"
    echo "  response: $(echo "${CHAT_RESPONSE}" | head -c 300)" >&2
    cat "/tmp/pf-chat-${NS}.log" 2>/dev/null | head -5 || true
  fi
done
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
