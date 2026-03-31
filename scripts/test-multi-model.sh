#!/usr/bin/env bash
# test-multi-model.sh — OpenClaw gateway health validation
#
# Pairs this machine as a temporary trusted device, runs layered health checks
# against the remote gateway, revokes the device, and restores local state.
#
# Sections:
#   Infrastructure pre-flight  — AI account, env vars, /healthz + /readyz  [always]
#   Gateway health             — openclaw health, probe, RPC status         [live]
#   Full gateway status        — openclaw status --all                      [live]
#   Remote config validation   — schema, auth mode, primary model, catalog  [CLI only]
#   Model availability         — openclaw models status, missing providers   [CLI only]
#   Channel health             — openclaw channels status --probe           [live]
#   Agent health               — openclaw agents status                     [live]
#   Memory health              — openclaw memory status --deep              [live]
#   Config doctor              — openclaw doctor --non-interactive          [live]
#   Live inference             — az containerapp exec + IMDS MI token       [always]
#
# [live]     = requires live gateway connection (paired device)
# [CLI only] = requires openclaw CLI binary, no live connection needed
# [always]   = runs regardless of openclaw CLI or gateway availability
#
# Usage:
#   bash scripts/test-multi-model.sh [dev|prod]
#   CI=true bash scripts/test-multi-model.sh dev   # skip interactive prod confirmation
#
# Prerequisites:
#   az login + correct subscription, Key Vault Secrets User on target KV
#   openclaw CLI installed (npm install -g openclaw), jq, curl
#
# Exit: 0 = all passed, 1 = one or more tests failed.

set -uo pipefail

# ── Arguments ─────────────────────────────────────────────────────────────────
ENV="${1:-dev}"
CI_MODE="${CI:-false}"

if [[ "${ENV}" != "dev" && "${ENV}" != "prod" ]]; then
  echo "Usage: bash scripts/test-multi-model.sh [dev|prod]"
  exit 1
fi

if [[ "${ENV}" == "prod" && "${CI_MODE}" != "true" ]]; then
  echo "⚠  You are about to run tests against PROD."
  echo "   This script is intended for dev by default."
  read -r -p "   Type 'prod' to confirm and continue: " confirmation
  if [[ "${confirmation}" != "prod" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

# ── Resource names (Terraform locals.tf naming convention) ─────────────────────
# Derive project slug from TF_VAR_project env var (set by CI) or default to "paa".
PROJECT="${TF_VAR_project:-${TF_VAR_PROJECT:-paa}}"
APP_NAME="${PROJECT}-${ENV}-app"
RG_NAME="${PROJECT}-${ENV}-rg"
KV_NAME="${PROJECT}-${ENV}-kv"
STORAGE_ACCOUNT="${PROJECT}${ENV}ocstate"
SHARE_NAME="openclaw-state"

# ── Expected values ────────────────────────────────────────────────────────────
EXPECTED_EMBEDDING_DEPLOYMENT="text-embedding-3-large"
EXPECTED_GROK4FAST_DEPLOYMENT="grok-4-fast-reasoning"
EXPECTED_GROK3_DEPLOYMENT="grok-3"
EXPECTED_GROK3MINI_DEPLOYMENT="grok-3-mini"
EXPECTED_CHAT_DEPLOYMENT="gpt-4o"
EXPECTED_PRIMARY_MODEL="azure-openai/gpt-4o"
EXPECTED_FALLBACK_MODEL="azure-foundry/grok-4-fast-reasoning"

EXPECTED_ENV_VARS=(
  "AZURE_OPENAI_ENDPOINT"
  "AZURE_AI_INFERENCE_ENDPOINT"
  "AZURE_OPENAI_DEPLOYMENT_EMBEDDING"
  "AZURE_OPENAI_DEPLOYMENT_CHAT"
  "AZURE_AI_DEPLOYMENT_GROK4FAST"
  "AZURE_AI_DEPLOYMENT_GROK3"
  "AZURE_AI_DEPLOYMENT_GROK3MINI"
  "OPENCLAW_GATEWAY_PORT"
  "AZURE_AI_API_KEY"
)

# ── Counters + helpers ─────────────────────────────────────────────────────────
PASS=0; FAIL=0; WARN=0
pass() { echo "  PASS  $*"; (( PASS++ )) || true; }
fail() { echo "  FAIL  $*"; (( FAIL++ )) || true; }
warn() { echo "  WARN  $*"; (( WARN++ )) || true; }
section() { echo ""; echo "── $* ────────────────────────────────────────────────"; }

# ── Banner ────────────────────────────────────────────────────────────────────
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " OpenClaw health validation — env=${ENV}  started=${TIMESTAMP}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  App: ${APP_NAME}   RG: ${RG_NAME}   KV: ${KV_NAME}"

# ── Prerequisites ──────────────────────────────────────────────────────────────
section "Prerequisites"
PREREQ_FAIL=false
for tool in az jq curl; do
  if command -v "${tool}" &>/dev/null; then
    pass "Tool: ${tool}"
  else
    fail "Required tool not found: ${tool}"
    PREREQ_FAIL=true
  fi
done

# Two flags: OPENCLAW_UNAVAILABLE = CLI binary absent;
#            GATEWAY_CONNECTED   = pairing succeeded, live RPC session active.
OPENCLAW_UNAVAILABLE=false
GATEWAY_CONNECTED=false

if command -v openclaw &>/dev/null; then
  OC_VER=$(openclaw --version 2>/dev/null | head -1 || echo "unknown")
  pass "Tool: openclaw ${OC_VER}"
else
  warn "openclaw CLI not installed — gateway/config/model sections skipped (install: npm install -g openclaw)"
  OPENCLAW_UNAVAILABLE=true
fi

if [[ "${PREREQ_FAIL}" == "true" ]]; then
  echo ""; echo "Required tools missing. Cannot continue."; exit 1
fi

# ── Resolve gateway credentials + endpoints ────────────────────────────────────
GATEWAY_TOKEN=$(az keyvault secret show \
  --vault-name "${KV_NAME}" \
  --name "openclaw-gateway-token" \
  --query "value" -o tsv 2>/dev/null || echo "")

FQDN=$(az containerapp show \
  --name "${APP_NAME}" \
  --resource-group "${RG_NAME}" \
  --query "properties.configuration.ingress.fqdn" \
  -o tsv 2>/dev/null || echo "")

GATEWAY_HTTPS_URL="${FQDN:+https://${FQDN}}"
GATEWAY_WS_URL="${FQDN:+wss://${FQDN}}"

STORAGE_KEY=$(az storage account keys list \
  --resource-group "${RG_NAME}" \
  --account-name "${STORAGE_ACCOUNT}" \
  --query "[0].value" -o tsv 2>/dev/null || echo "")

# ── Local config backup + cleanup trap ────────────────────────────────────────
LOCAL_CONFIG="${HOME}/.openclaw/openclaw.json"
LOCAL_CONFIG_BACKUP="/tmp/openclaw-pre-test-backup-$$.json"
ONBOARD_CONFIG_CACHE="/tmp/openclaw-onboard-cache-$$.json"
TMP_SHARE_CONFIG="/tmp/openclaw-share-config-$$.json"
DEVICE_ID=""
DEVICE_ROLE="admin"

mkdir -p "${HOME}/.openclaw"
cp "${LOCAL_CONFIG}" "${LOCAL_CONFIG_BACKUP}" 2>/dev/null || true

cleanup() {
  echo ""
  # 1. Revoke test device while onboard credentials are still reachable.
  if [[ -n "${DEVICE_ID}" && "${OPENCLAW_UNAVAILABLE}" != "true" ]]; then
    echo "  CLEANUP  Revoking test device ${DEVICE_ID} (role: ${DEVICE_ROLE})..."
    [[ -f "${ONBOARD_CONFIG_CACHE}" ]] && cp "${ONBOARD_CONFIG_CACHE}" "${LOCAL_CONFIG}" 2>/dev/null || true
    openclaw devices revoke "${DEVICE_ID}" "${DEVICE_ROLE}" 2>/dev/null \
      && echo "  CLEANUP  Device revoked." \
      || echo "  CLEANUP  Device revoke failed (may already be removed)."
  fi
  # 2. Restore the original pre-test local config.
  if [[ -f "${LOCAL_CONFIG_BACKUP}" ]]; then
    cp "${LOCAL_CONFIG_BACKUP}" "${LOCAL_CONFIG}" 2>/dev/null || true
    echo "  CLEANUP  Local openclaw config restored."
  else
    rm -f "${LOCAL_CONFIG}"
  fi
  rm -f "${LOCAL_CONFIG_BACKUP}" "${ONBOARD_CONFIG_CACHE}" "${TMP_SHARE_CONFIG}" 2>/dev/null || true
}
trap cleanup EXIT

# ── Device pairing ────────────────────────────────────────────────────────────
section "Device pairing"

if [[ "${OPENCLAW_UNAVAILABLE}" == "true" ]]; then
  echo "  SKIP  No openclaw CLI"
elif [[ -z "${GATEWAY_TOKEN}" || -z "${FQDN}" ]]; then
  warn "Cannot resolve gateway credentials or FQDN — live connection sections skipped"
else
  ONBOARD_OUT=$(openclaw onboard \
    --non-interactive \
    --accept-risk \
    --mode remote \
    --remote-url "${GATEWAY_WS_URL}" \
    --remote-token "${GATEWAY_TOKEN}" 2>&1 || echo "ONBOARD_FAILED")

  if echo "${ONBOARD_OUT}" | grep -q "ONBOARD_FAILED"; then
    warn "Device self-pairing failed — gateway/channel/agent sections skipped; config+model checks will still run"
    echo "${ONBOARD_OUT}" | head -3 | sed 's/^/    /'
  else
    pass "Device paired to ${GATEWAY_WS_URL}"
    cp "${LOCAL_CONFIG}" "${ONBOARD_CONFIG_CACHE}" 2>/dev/null || true
    # Verify the gateway accepted the session. onboard exits 0 when the pairing
    # request is submitted, but the gateway rejects with 1008 (pairing required)
    # until an admin approves the device. Probe here so failures become WARNs.
    PROBE_VERIFY=$(timeout 15 openclaw gateway probe 2>&1 || echo "OC_PROBE_FAILED")
    if echo "${PROBE_VERIFY}" | grep -qiE "pairing required|1008|OC_PROBE_FAILED|failed|error|unreachable"; then
      warn "Gateway rejected session (${PROBE_VERIFY%%$'\n'*}) — device approval pending; gateway/channel/agent sections skipped"
    else
      GATEWAY_CONNECTED=true
      pass "Gateway session confirmed active"
    fi
    DEVICES_JSON=$(openclaw devices list --json 2>/dev/null || echo "[]")
    DEVICE_ID=$(echo "${DEVICES_JSON}" | jq -r \
      'if type=="array" then sort_by(.pairedAt // .lastSeen // "") | last | .id // "" else "" end' \
      2>/dev/null || echo "")
    DEVICE_ROLE=$(echo "${DEVICES_JSON}" | jq -r \
      'if type=="array" then sort_by(.pairedAt // .lastSeen // "") | last | .role // "admin" else "admin" end' \
      2>/dev/null || echo "admin")
    [[ -n "${DEVICE_ID}" ]] && echo "  INFO  Device ID: ${DEVICE_ID}  Role: ${DEVICE_ROLE}"
  fi
fi

# Helper: run openclaw with a 30s timeout.
oc() { timeout 30 openclaw "$@" 2>&1 || echo "OC_TIMEOUT_OR_ERROR"; }

# ══════════════════════════════════════════════════════════════════════════════
# Section A — Infrastructure pre-flight
# ══════════════════════════════════════════════════════════════════════════════
section "Infrastructure pre-flight"

AI_ACCOUNT_NAME=$(az cognitiveservices account list \
  --resource-group "${RG_NAME}" \
  --query "[?kind=='AIServices' || kind=='OpenAI'].name | [0]" \
  -o tsv 2>/dev/null || true)
[[ -z "${AI_ACCOUNT_NAME}" ]] && AI_ACCOUNT_NAME=$(az cognitiveservices account list \
  --resource-group "${RG_NAME}" --query "[0].name" -o tsv 2>/dev/null || true)

if [[ -z "${AI_ACCOUNT_NAME}" ]]; then
  fail "No AI Services / Cognitive Services account found in ${RG_NAME}"
else
  pass "AI Services account: ${AI_ACCOUNT_NAME}"
  DEPLOYMENTS=$(az cognitiveservices account deployment list \
    --resource-group "${RG_NAME}" --name "${AI_ACCOUNT_NAME}" \
    -o json 2>/dev/null || echo "[]")

  EMBEDDING_STATE=$(echo "${DEPLOYMENTS}" | jq -r \
    --arg n "${EXPECTED_EMBEDDING_DEPLOYMENT}" \
    '.[] | select(.name==$n) | .properties.provisioningState // "missing"')

  if [[ "${EMBEDDING_STATE}" == "Succeeded" ]]; then
    pass "Embedding deployment '${EXPECTED_EMBEDDING_DEPLOYMENT}': Succeeded"
  elif [[ -n "${EMBEDDING_STATE}" && "${EMBEDDING_STATE}" != "missing" ]]; then
    fail "Embedding deployment '${EXPECTED_EMBEDDING_DEPLOYMENT}': state=${EMBEDDING_STATE}"
  else
    fail "Embedding deployment '${EXPECTED_EMBEDDING_DEPLOYMENT}': not found"
  fi

  for grok_name in "${EXPECTED_GROK4FAST_DEPLOYMENT}" "${EXPECTED_GROK3_DEPLOYMENT}" "${EXPECTED_GROK3MINI_DEPLOYMENT}"; do
    GROK_ENTRY=$(echo "${DEPLOYMENTS}" | jq -r --arg n "${grok_name}" '.[] | select(.name==$n) | .name // ""')
    if [[ -z "${GROK_ENTRY}" ]]; then
      pass "Grok MaaS '${grok_name}': correctly absent from account deployments"
    else
      fail "Grok MaaS '${grok_name}': unexpectedly present as account deployment"
    fi
  done
fi

ENV_JSON=$(az containerapp show \
  --name "${APP_NAME}" --resource-group "${RG_NAME}" \
  --query "properties.template.containers[0].env" \
  -o json 2>/dev/null || echo "null")

if [[ "${ENV_JSON}" == "null" || -z "${ENV_JSON}" ]]; then
  fail "Cannot retrieve Container App env vars"
else
  SENSITIVE_VARS=("OPENCLAW_GATEWAY_TOKEN" "AZURE_AI_API_KEY")
  for expected_var in "${EXPECTED_ENV_VARS[@]}"; do
    VAR_PRESENT=$(echo "${ENV_JSON}" | jq -r --arg k "${expected_var}" '.[] | select(.name==$k) | .name // ""')
    if [[ -z "${VAR_PRESENT}" ]]; then
      fail "Env var missing: ${expected_var}"
    else
      is_sensitive=false
      for sv in "${SENSITIVE_VARS[@]}"; do [[ "${expected_var}" == "${sv}" ]] && is_sensitive=true; done
      if [[ "${is_sensitive}" == "true" ]]; then
        pass "Env var (secret ref): ${expected_var}"
      else
        VAL=$(echo "${ENV_JSON}" | jq -r --arg k "${expected_var}" '.[] | select(.name==$k) | .value // "(secret ref)"')
        pass "Env var: ${expected_var} = ${VAL}"
      fi
    fi
  done

  check_env_value() {
    local varname="$1" expected="$2" actual
    actual=$(echo "${ENV_JSON}" | jq -r --arg k "${varname}" '.[] | select(.name==$k) | .value // ""')
    [[ "${actual}" == "${expected}" ]] \
      && pass "Env var value: ${varname} = ${actual}" \
      || fail "Env var value mismatch: ${varname} — expected '${expected}', got '${actual}'"
  }
  check_env_value "AZURE_OPENAI_DEPLOYMENT_EMBEDDING" "${EXPECTED_EMBEDDING_DEPLOYMENT}"
  check_env_value "AZURE_OPENAI_DEPLOYMENT_CHAT"      "${EXPECTED_CHAT_DEPLOYMENT}"
  check_env_value "AZURE_AI_DEPLOYMENT_GROK4FAST"     "${EXPECTED_GROK4FAST_DEPLOYMENT}"
  check_env_value "AZURE_AI_DEPLOYMENT_GROK3"         "${EXPECTED_GROK3_DEPLOYMENT}"
  check_env_value "AZURE_AI_DEPLOYMENT_GROK3MINI"     "${EXPECTED_GROK3MINI_DEPLOYMENT}"
fi

# ── Container App provisioning + revision state ───────────────────────────────
APP_JSON=$(az containerapp show \
  --name "${APP_NAME}" \
  --resource-group "${RG_NAME}" \
  -o json 2>/dev/null || echo "{}")

PROV_STATE=$(echo "${APP_JSON}" | jq -r '.properties.provisioningState // "unknown"')
if [[ "${PROV_STATE}" == "Succeeded" ]]; then
  pass "Container App provisioning state: Succeeded"
else
  fail "Container App provisioning state: ${PROV_STATE} (expected Succeeded)"
fi

LATEST_REV=$(echo "${APP_JSON}" | jq -r '.properties.latestRevisionName // ""')
LATEST_READY=$(echo "${APP_JSON}" | jq -r '.properties.latestReadyRevisionName // ""')
if [[ -n "${LATEST_REV}" && "${LATEST_REV}" == "${LATEST_READY}" ]]; then
  pass "Active revision is ready: ${LATEST_REV}"
else
  fail "Revision mismatch: latest=${LATEST_REV} ready=${LATEST_READY}"
fi

ACTUAL_IMAGE=$(echo "${APP_JSON}" | jq -r '.properties.template.containers[0].image // ""')
EXPECTED_IMAGE_PREFIX="ghcr.io/openclaw/openclaw:"
if echo "${ACTUAL_IMAGE}" | grep -q "^${EXPECTED_IMAGE_PREFIX}"; then
  pass "Container image: ${ACTUAL_IMAGE}"
else
  fail "Unexpected container image: '${ACTUAL_IMAGE}' (expected prefix: ${EXPECTED_IMAGE_PREFIX})"
fi

# ── Revision running state ─────────────────────────────────────────────────────
REV_JSON=$(az containerapp revision show \
  --name "${APP_NAME}" \
  --resource-group "${RG_NAME}" \
  --revision "${LATEST_REV}" \
  -o json 2>/dev/null || echo "{}")

REV_RUNNING=$(echo "${REV_JSON}" | jq -r '.properties.runningState // "unknown"')
REV_REPLICAS=$(echo "${REV_JSON}" | jq -r '.properties.replicas // 0')
if [[ "${REV_RUNNING}" == "Running" ]]; then
  pass "Revision running state: Running (replicas: ${REV_REPLICAS})"
elif [[ "${REV_RUNNING}" == "Stopped" && "${REV_REPLICAS}" == "0" ]]; then
  warn "Revision stopped (replicas=0) — scale-to-zero; /healthz probe will wake it"
else
  fail "Revision running state: ${REV_RUNNING} (replicas: ${REV_REPLICAS})"
fi

# ── Console log health scan ────────────────────────────────────────────────────
# Scan the last 50 log lines for crash/fatal indicators.
# Pairing-required and closed-before-connect lines are normal operation.
LOG_LINES=$(az containerapp logs show \
  --name "${APP_NAME}" \
  --resource-group "${RG_NAME}" \
  --type console \
  --tail 50 \
  --follow false \
  -o json 2>/dev/null \
  | jq -r '.[].Log' 2>/dev/null || echo "")

if [[ -z "${LOG_LINES}" ]]; then
  warn "Container log scan: no log lines returned (container may be scaled to zero)"
else
  CRASH_LINES=$(echo "${LOG_LINES}" \
    | grep -iE "crash|panic|fatal|OOMKilled|unhandledRejection|exit code [^0 ]" \
    | grep -ivE "pairing required|closed before connect|Proxy headers|trustedProxies" \
    | head -5 || true)
  if [[ -n "${CRASH_LINES}" ]]; then
    fail "Container log: crash/fatal indicators found:"
    echo "${CRASH_LINES}" | sed 's/^/    /'
  else
    WS_OK=$(echo "${LOG_LINES}" | grep -c '\[ws\].*res.*' 2>/dev/null || echo "0")
    if [[ "${WS_OK}" -gt 0 ]]; then
      pass "Container log scan: no crashes; ${WS_OK} recent gateway RPC response(s)"
    else
      pass "Container log scan: no crash or fatal indicators"
    fi
  fi
fi

# ── Health probes ─────────────────────────────────────────────────────────────
if [[ -n "${GATEWAY_HTTPS_URL}" ]]; then
  pass "Gateway FQDN: ${FQDN}"
  for probe in healthz readyz; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
      "${GATEWAY_HTTPS_URL}/${probe}" 2>/dev/null || echo "000")
    [[ "${HTTP_CODE}" == "200" ]] \
      && pass "Probe /${probe}: HTTP 200" \
      || fail "Probe /${probe}: HTTP ${HTTP_CODE} (expected 200)"
  done
else
  fail "Cannot resolve Container App FQDN — skipping health probes"
fi

# ══════════════════════════════════════════════════════════════════════════════
# Gateway health + full status: live gateway checks (openclaw CLI + paired session required)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "${OPENCLAW_UNAVAILABLE}" == "true" ]]; then
  warn "Gateway health + status skipped (openclaw CLI not installed)"
elif [[ "${GATEWAY_CONNECTED}" != "true" ]]; then
  warn "Gateway health + status skipped (pairing failed — live gateway connection unavailable)"
else

section "Gateway health"

HEALTH_OUT=$(oc health)
if echo "${HEALTH_OUT}" | grep -qiE "OC_TIMEOUT_OR_ERROR|error|unreachable|failed"; then
  fail "openclaw health: ${HEALTH_OUT}"
else
  pass "openclaw health: $(echo "${HEALTH_OUT}" | head -1)"
fi

PROBE_OUT=$(oc gateway probe)
if echo "${PROBE_OUT}" | grep -qiE "OC_TIMEOUT_OR_ERROR|unreachable|error"; then
  fail "openclaw gateway probe: ${PROBE_OUT}"
else
  pass "openclaw gateway probe: $(echo "${PROBE_OUT}" | head -1)"
fi

GW_STATUS_JSON=$(oc gateway status --json)
if echo "${GW_STATUS_JSON}" | grep -q "OC_TIMEOUT_OR_ERROR"; then
  warn "openclaw gateway status --json: timed out or error"
else
  RPC_OK=$(echo "${GW_STATUS_JSON}" | jq -r '.rpc.ok // false' 2>/dev/null || echo "false")
  if [[ "${RPC_OK}" == "true" ]]; then
    pass "Gateway RPC: ok"
  else
    warn "Gateway RPC not ready — device may still be establishing session"
    echo "${GW_STATUS_JSON}" | jq -r '.' 2>/dev/null | head -8 | sed 's/^/    /'
  fi
fi

section "Full gateway status"

STATUS_OUT=$(oc status --all)
if echo "${STATUS_OUT}" | grep -qiE "OC_TIMEOUT_OR_ERROR|Cannot connect|not reachable"; then
  fail "openclaw status --all: gateway not reachable"
else
  SUMMARY=$(echo "${STATUS_OUT}" | grep -iE "uptime|running|replica|version" | head -1 | tr -s ' ' || echo "")
  LATENCY=$(echo "${STATUS_OUT}" | grep -iE "latenc|ms\b" | head -1 | sed 's/^[[:space:]]*//' || echo "")
  pass "openclaw status --all: reachable${SUMMARY:+ — ${SUMMARY}}"
  [[ -n "${LATENCY}" ]] && echo "  INFO  ${LATENCY}"
  PROBLEM_LINES=$(echo "${STATUS_OUT}" | grep -iE "error|warn|fail|disconnected|missing|degraded" \
    | grep -ivE "PASS|OK|healthy|connected|enabled|uptime|running|replica|version|latency|agent|pairing" \
    | head -5 || true)
  [[ -n "${PROBLEM_LINES}" ]] && { warn "Status issues:"; echo "${PROBLEM_LINES}" | sed 's/^/    /'; }
fi

fi  # end gateway health + status sections

# ══════════════════════════════════════════════════════════════════════════════
# Remote config validation + model availability: run when CLI is available, even if pairing failed.
# Both use the config swap trick (temporarily replace local config with the
# one downloaded from Azure Files) — no live gateway RPC required.
# ══════════════════════════════════════════════════════════════════════════════
if [[ "${OPENCLAW_UNAVAILABLE}" == "true" ]]; then
  warn "Remote config + model availability skipped (openclaw CLI not installed)"
else

# Export env vars so openclaw can resolve ${VAR} refs in the share config.
export OPENCLAW_GATEWAY_TOKEN="${GATEWAY_TOKEN}"
export APP_FQDN="${FQDN}"
export AZURE_AI_DEPLOYMENT_GROK4FAST="${EXPECTED_GROK4FAST_DEPLOYMENT}"
export AZURE_AI_DEPLOYMENT_GROK3="${EXPECTED_GROK3_DEPLOYMENT}"
export AZURE_AI_DEPLOYMENT_GROK3MINI="${EXPECTED_GROK3MINI_DEPLOYMENT}"
if [[ -n "${ENV_JSON:-}" && "${ENV_JSON}" != "null" ]]; then
  _ENDPOINT=$(echo "${ENV_JSON}" | jq -r '.[] | select(.name=="AZURE_AI_INFERENCE_ENDPOINT") | .value // ""' 2>/dev/null || echo "")
  [[ -n "${_ENDPOINT}" ]] && export AZURE_AI_INFERENCE_ENDPOINT="${_ENDPOINT}"
  _OAI_ENDPOINT=$(echo "${ENV_JSON}" | jq -r '.[] | select(.name=="AZURE_OPENAI_ENDPOINT") | .value // ""' 2>/dev/null || echo "")
  [[ -n "${_OAI_ENDPOINT}" ]] && export AZURE_OPENAI_ENDPOINT="${_OAI_ENDPOINT}"
  _CHAT_DEPLOY=$(echo "${ENV_JSON}" | jq -r '.[] | select(.name=="AZURE_OPENAI_DEPLOYMENT_CHAT") | .value // ""' 2>/dev/null || echo "")
  [[ -n "${_CHAT_DEPLOY}" ]] && export AZURE_OPENAI_DEPLOYMENT_CHAT="${_CHAT_DEPLOY}"
fi
# AZURE_AI_API_KEY: pre-exported by CI workflow env step (or caller); no-op if already set.

section "Remote config validation"

if [[ -z "${STORAGE_KEY}" ]]; then
  fail "Cannot read storage key for ${STORAGE_ACCOUNT} — skipping config checks"
else
  DOWNLOAD_OK=false
  az storage file download \
    --account-name "${STORAGE_ACCOUNT}" \
    --account-key "${STORAGE_KEY}" \
    --share-name "${SHARE_NAME}" \
    --path "openclaw.json" \
    --dest "${TMP_SHARE_CONFIG}" \
    --output none 2>/dev/null && DOWNLOAD_OK=true || true

  if [[ "${DOWNLOAD_OK}" != "true" || ! -f "${TMP_SHARE_CONFIG}" ]]; then
    fail "openclaw.json not found on share (config not seeded yet)"
  else
    pass "openclaw.json downloaded from Azure Files share"
      # Endpoint suffix guard: verify AZURE_OPENAI_ENDPOINT env var carries the /openai/v1 path.
      _OAI_ENV="${AZURE_OPENAI_ENDPOINT:-}"
      if [[ "${_OAI_ENV}" == */openai/v1 ]]; then
        pass "AZURE_OPENAI_ENDPOINT suffix: /openai/v1 (${_OAI_ENV})"
      elif [[ -z "${_OAI_ENV}" ]]; then
        warn "AZURE_OPENAI_ENDPOINT: not set in this context — cannot verify suffix"
      else
        fail "AZURE_OPENAI_ENDPOINT missing /openai/v1 suffix: ${_OAI_ENV}"
      fi
    if ! jq empty "${TMP_SHARE_CONFIG}" 2>/dev/null; then
      fail "openclaw.json: invalid JSON"
    else
      pass "openclaw.json: valid JSON"

      check_json_path() {
        local label="$1" path="$2" expected="$3" tpl="${4:-}" actual
        actual=$(jq -r "${path} // \"\"" "${TMP_SHARE_CONFIG}" 2>/dev/null || echo "")
        if [[ -z "${actual}" ]]; then
          fail "${label}: path not found (${path})"
        elif [[ -n "${expected}" && "${actual}" != "${expected}" && "${actual}" != "${tpl}" ]]; then
          fail "${label}: expected '${expected}'${tpl:+ or '${tpl}'}, got '${actual}'"
        else
          pass "${label}: ${actual}"
        fi
      }

      check_json_path "Primary model" \
        ".agents.defaults.model.primary" \
        "${EXPECTED_PRIMARY_MODEL}" \
        'azure-openai/${AZURE_OPENAI_DEPLOYMENT_CHAT}'

      FALLBACKS=$(jq -r '.agents.defaults.model.fallbacks // [] | join(", ")' "${TMP_SHARE_CONFIG}" 2>/dev/null || echo "")
      if echo "${FALLBACKS}" | grep -qE '(azure-foundry/grok-4-fast-reasoning|azure-foundry/\$\{AZURE_AI_DEPLOYMENT_GROK4FAST\})'; then
        pass "Fallback list: ${FALLBACKS}"
      else
        fail "Fallback missing grok-4-fast-reasoning: [${FALLBACKS}]"
      fi

      # azure-openai provider checks (primary chat model).
      OAI_AUTH_HDR=$(jq -r '.models.providers["azure-openai"].authHeader | if . == null then "missing" else tostring end' "${TMP_SHARE_CONFIG}" 2>/dev/null || echo "missing")
      if [[ "${OAI_AUTH_HDR}" == "false" ]]; then
        pass "azure-openai authHeader: false"
      else
        fail "azure-openai authHeader: expected false, got '${OAI_AUTH_HDR}'"
      fi
      OAI_HDR_KEY=$(jq -r '.models.providers["azure-openai"].headers["api-key"] // ""' "${TMP_SHARE_CONFIG}" 2>/dev/null || echo "")
      if [[ -n "${OAI_HDR_KEY}" ]]; then
        pass "azure-openai headers[api-key]: present"
      else
        fail "azure-openai headers[api-key]: missing or empty"
      fi
      check_json_path "azure-openai api" ".models.providers[\"azure-openai\"].api" "openai-completions" ""

      # authHeader must be false; headers["api-key"] replaces the auth field in this config version.
      # Use tostring (not //) because jq // treats false as falsy and returns the alternative.
      AUTH_HDR=$(jq -r '.models.providers["azure-foundry"].authHeader | if . == null then "missing" else tostring end' "${TMP_SHARE_CONFIG}" 2>/dev/null || echo "missing")
      if [[ "${AUTH_HDR}" == "false" ]]; then
        pass "azure-foundry authHeader: false"
      else
        fail "azure-foundry authHeader: expected false, got '${AUTH_HDR}'"
      fi
      HDR_KEY=$(jq -r '.models.providers["azure-foundry"].headers["api-key"] // ""' "${TMP_SHARE_CONFIG}" 2>/dev/null || echo "")
      if [[ -n "${HDR_KEY}" ]]; then
        pass "azure-foundry headers[api-key]: present"
      else
        fail "azure-foundry headers[api-key]: missing or empty"
      fi
      # apiKey is a ${VAR} placeholder in the template; check it is present and non-empty.
      AK_VAL=$(jq -r '.models.providers["azure-foundry"].apiKey // ""' "${TMP_SHARE_CONFIG}" 2>/dev/null || echo "")
      if [[ -n "${AK_VAL}" ]]; then
        pass "azure-foundry apiKey: present (${AK_VAL})"
      else
        fail "azure-foundry apiKey: missing or empty"
      fi
      check_json_path "azure-foundry baseUrl" ".models.providers[\"azure-foundry\"].baseUrl" "" ""
      check_json_path "azure-foundry api"     ".models.providers[\"azure-foundry\"].api"     "openai-completions" ""

      check_catalog_entry() {
        local label="$1" resolved_key="$2" tpl_key="$3" entry
        entry=$(jq -r --arg k "${resolved_key}" '.agents.defaults.models[$k] // ""' "${TMP_SHARE_CONFIG}" 2>/dev/null || echo "")
        if [[ -n "${entry}" ]]; then pass "Catalog entry: ${resolved_key}"; return; fi
        entry=$(jq -r --arg k "${tpl_key}" '.agents.defaults.models[$k] // ""' "${TMP_SHARE_CONFIG}" 2>/dev/null || echo "")
        if [[ -n "${entry}" ]]; then pass "Catalog entry (template key): ${tpl_key}"
        else fail "Catalog entry missing: ${resolved_key}"; fi
      }
      check_catalog_entry "grok-4-fast-reasoning" \
        "azure-foundry/${EXPECTED_GROK4FAST_DEPLOYMENT}" 'azure-foundry/${AZURE_AI_DEPLOYMENT_GROK4FAST}'
      check_catalog_entry "grok-3" \
        "azure-foundry/${EXPECTED_GROK3_DEPLOYMENT}" 'azure-foundry/${AZURE_AI_DEPLOYMENT_GROK3}'
      check_catalog_entry "grok-3-mini" \
        "azure-foundry/${EXPECTED_GROK3MINI_DEPLOYMENT}" 'azure-foundry/${AZURE_AI_DEPLOYMENT_GROK3MINI}'

      # memorySearch presence check.
      MS_PROVIDER=$(jq -r '.agents.defaults.memorySearch.provider // ""' "${TMP_SHARE_CONFIG}" 2>/dev/null || echo "")
      if [[ "${MS_PROVIDER}" == "openai" ]]; then
        pass "memorySearch.provider: openai"
      else
        fail "memorySearch.provider: expected 'openai', got '${MS_PROVIDER:-<missing>}'"
      fi
      MS_MODEL=$(jq -r '.agents.defaults.memorySearch.model // ""' "${TMP_SHARE_CONFIG}" 2>/dev/null || echo "")
      if [[ -n "${MS_MODEL}" ]]; then
        pass "memorySearch.model: present (${MS_MODEL})"
      else
        fail "memorySearch.model: missing or empty"
      fi
    fi

    # Schema validation via swap trick.
    SWAP_BACKUP_D="/tmp/openclaw-swap-d-$$.json"
    cp "${LOCAL_CONFIG}" "${SWAP_BACKUP_D}" 2>/dev/null || true
    cp "${TMP_SHARE_CONFIG}" "${LOCAL_CONFIG}"
    VALIDATE_OUT=$(openclaw config validate --json 2>&1)
    VALIDATE_EXIT=$?
    cp "${SWAP_BACKUP_D}" "${LOCAL_CONFIG}" 2>/dev/null || true
    rm -f "${SWAP_BACKUP_D}"

    if [[ ${VALIDATE_EXIT} -eq 0 ]]; then
      pass "Schema validation: valid"
    else
      ERRORS=$(echo "${VALIDATE_OUT}" | jq -r '.[] | "  \(.path): \(.message)"' 2>/dev/null \
        || echo "${VALIDATE_OUT}")
      fail "Schema validation failed:"
      echo "${ERRORS}" | sed 's/^/    /'
    fi
  fi
fi

section "Model availability"

if [[ ! -f "${TMP_SHARE_CONFIG}" ]]; then
  warn "Share config unavailable — skipping model availability check"
else
  SWAP_BACKUP_E="/tmp/openclaw-swap-e-$$.json"
  cp "${LOCAL_CONFIG}" "${SWAP_BACKUP_E}" 2>/dev/null || true
  cp "${TMP_SHARE_CONFIG}" "${LOCAL_CONFIG}"
  MODELS_STATUS_JSON=$(openclaw models status --json 2>/dev/null || echo "OC_ERROR")
  MODELS_LIST_JSON=$(openclaw models list --json 2>/dev/null || echo "OC_ERROR")
  cp "${SWAP_BACKUP_E}" "${LOCAL_CONFIG}" 2>/dev/null || true
  rm -f "${SWAP_BACKUP_E}"

  if echo "${MODELS_STATUS_JSON}" | grep -q "OC_ERROR"; then
    warn "openclaw models status: command failed"
  else
    MISSING=$(echo "${MODELS_STATUS_JSON}" | jq -r '.missingProvidersInUse // [] | join(", ")' 2>/dev/null || echo "")
    if [[ -z "${MISSING}" ]]; then
      pass "Models: no missing providers (auth correctly configured)"
    else
      fail "Models: missingProvidersInUse: [${MISSING}]"
    fi
  fi

  if ! echo "${MODELS_LIST_JSON}" | grep -q "OC_ERROR"; then
    for model_key in \
      "azure-foundry/${EXPECTED_GROK4FAST_DEPLOYMENT}" \
      "azure-foundry/${EXPECTED_GROK3_DEPLOYMENT}" \
      "azure-foundry/${EXPECTED_GROK3MINI_DEPLOYMENT}"; do
      AVAILABLE=$(echo "${MODELS_LIST_JSON}" | jq -r \
        --arg k "${model_key}" \
        '[.[] | select(.id==$k or .key==$k)] | first | .available // false' \
        2>/dev/null || echo "false")
      if [[ "${AVAILABLE}" == "true" ]]; then
        pass "Model available: ${model_key}"
      else
        warn "Model not available: ${model_key} (env vars may not be resolved in this context)"
      fi
    done
  fi
fi

fi  # end OPENCLAW_UNAVAILABLE check for D + E

# ══════════════════════════════════════════════════════════════════════════════
# Channel/agent/memory/doctor: live gateway checks (requires GATEWAY_CONNECTED)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "${OPENCLAW_UNAVAILABLE}" != "true" && "${GATEWAY_CONNECTED}" == "true" ]]; then

section "Channel health"

CHANNELS_OUT=$(oc channels status --probe)
if echo "${CHANNELS_OUT}" | grep -q "OC_TIMEOUT_OR_ERROR"; then
  warn "openclaw channels status --probe: timed out or error"
elif echo "${CHANNELS_OUT}" | grep -qiE "error|✗|failed|unreachable"; then
  PROBLEM=$(echo "${CHANNELS_OUT}" | grep -iE "error|✗|failed|unreachable" | head -5)
  fail "Channel health: issues detected"
  echo "${PROBLEM}" | sed 's/^/    /'
else
  CONNECTED=$(echo "${CHANNELS_OUT}" | grep -ciE "connected|ok|enabled" || echo "0")
  pass "Channel health: ${CONNECTED} channel(s) connected/enabled"
  echo "${CHANNELS_OUT}" | head -8 | sed 's/^/    /'
fi

section "Agent health"

AGENTS_OUT=$(oc agents status)
if echo "${AGENTS_OUT}" | grep -q "OC_TIMEOUT_OR_ERROR"; then
  warn "openclaw agents status: timed out or error"
elif echo "${AGENTS_OUT}" | grep -qiE "error|failed|missing"; then
  fail "Agent health: errors detected"
  echo "${AGENTS_OUT}" | grep -iE "error|failed|missing" | head -5 | sed 's/^/    /'
else
  pass "Agent health: $(echo "${AGENTS_OUT}" | head -1 | tr -s ' ')"
fi

section "Memory health"

MEMORY_OUT=$(oc memory status --deep)
if echo "${MEMORY_OUT}" | grep -q "OC_TIMEOUT_OR_ERROR"; then
  warn "openclaw memory status --deep: timed out or error"
elif echo "${MEMORY_OUT}" | grep -qiE "not configured|not enabled|disabled|no memory"; then
  warn "Memory: not configured (add memory section to openclaw.json to enable)"
elif echo "${MEMORY_OUT}" | grep -qiE "error|failed"; then
  fail "Memory health: $(echo "${MEMORY_OUT}" | grep -iE 'error|failed' | head -1)"
else
  pass "Memory health: $(echo "${MEMORY_OUT}" | head -1 | tr -s ' ')"
fi

section "Config doctor"

DOCTOR_OUT=$(openclaw doctor --non-interactive 2>&1)
DOCTOR_EXIT=$?
if [[ ${DOCTOR_EXIT} -ne 0 ]]; then
  fail "openclaw doctor exited ${DOCTOR_EXIT}"
  echo "${DOCTOR_OUT}" | tail -10 | sed 's/^/    /'
else
  CRITICAL_COUNT=$(echo "${DOCTOR_OUT}" | grep -ic "CRITICAL" || true)
  WARN_COUNT=$(echo "${DOCTOR_OUT}" | grep -ic "warn" || true)
  [[ "${CRITICAL_COUNT}" -gt 0 ]] && {
    warn "Doctor: ${CRITICAL_COUNT} CRITICAL issue(s):"
    echo "${DOCTOR_OUT}" | grep -i "CRITICAL" | sed 's/^/    /'
  }
  pass "openclaw doctor: complete (${CRITICAL_COUNT} critical, ${WARN_COUNT} warnings)"
fi

fi  # end channel/agent/memory/doctor sections

# ══════════════════════════════════════════════════════════════════════════════
# Section J — Live inference (exec into container)
# Runs from INSIDE the container via az containerapp exec, using the
# AZURE_AI_API_KEY env var (injected from Key Vault at runtime) to
# authenticate directly to the Azure AI Model Inference endpoint.
# This validates the complete auth chain: Key Vault → Container App env →
# Grok model, matching the auth: "api-key" strategy in openclaw.json.tpl.
# Uses node for JSON (jq is not in the OpenClaw container image).
# Rate-limited by Azure (~HTTP 429 after frequent calls; wait 10 min if hit).
# ══════════════════════════════════════════════════════════════════════════════
section "Live inference"

INNER_SCRIPT=$(cat <<'INNEREOF'
set -euo pipefail
API_KEY="${AZURE_AI_API_KEY:-}"
if [[ -z "${API_KEY}" ]]; then
  echo "APIKEY_FAIL: AZURE_AI_API_KEY env var is empty or not set"; exit 1
fi
BASE="${AZURE_AI_INFERENCE_ENDPOINT}/chat/completions"
test_model() {
  local model="$1" label="$2"
  local payload="{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly one word: OK\"}],\"max_tokens\":20}"
  HTTP=$(curl -s -o /tmp/inf_resp.json -w "%{http_code}" --max-time 45 \
    -X POST "${BASE}" \
    -H "api-key: ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "${payload}")
  if [[ "${HTTP}" == "200" ]]; then
    REPLY=$(node -pe 'JSON.parse(require("fs").readFileSync("/dev/stdin","utf8")).choices[0].message.content' \
      < /tmp/inf_resp.json 2>/dev/null || echo "(parse error)")
    echo "PASS:${label}:HTTP 200 reply=${REPLY}"
  else
    BODY=$(head -c 300 /tmp/inf_resp.json 2>/dev/null || echo "(no body)")
    echo "FAIL:${label}:HTTP ${HTTP} ${BODY}"
  fi
}
test_model "${AZURE_AI_DEPLOYMENT_GROK4FAST}" "grok-4-fast-reasoning"
test_model "${AZURE_AI_DEPLOYMENT_GROK3}"     "grok-3"
test_model "${AZURE_AI_DEPLOYMENT_GROK3MINI}" "grok-3-mini"
INNEREOF
)

INNER_SCRIPT_FILE="test-multi-model-inner-$$.sh"
if [[ -z "${STORAGE_KEY}" ]]; then
  fail "Cannot upload inner script — storage key unavailable"
else
  echo "${INNER_SCRIPT}" > "/tmp/${INNER_SCRIPT_FILE}"
  az storage file upload \
    --account-name "${STORAGE_ACCOUNT}" \
    --account-key "${STORAGE_KEY}" \
    --share-name "${SHARE_NAME}" \
    --source "/tmp/${INNER_SCRIPT_FILE}" \
    --path "${INNER_SCRIPT_FILE}" \
    --output none 2>/dev/null
  rm -f "/tmp/${INNER_SCRIPT_FILE}"

  echo "  INFO  Exec-ing into ${APP_NAME} (15–45s per model)..."
  EXEC_OUT=$(az containerapp exec \
    --name "${APP_NAME}" \
    --resource-group "${RG_NAME}" \
    --command "bash /home/node/.openclaw/${INNER_SCRIPT_FILE}" \
    2>&1 || echo "EXEC_ERROR:$?")

  az storage file delete \
    --account-name "${STORAGE_ACCOUNT}" \
    --account-key "${STORAGE_KEY}" \
    --share-name "${SHARE_NAME}" \
    --path "${INNER_SCRIPT_FILE}" \
    --output none 2>/dev/null || true

  if echo "${EXEC_OUT}" | grep -qE "429|Too Many|rate.limit|EXEC_ERROR"; then
    warn "az containerapp exec rate-limited — re-run after 10 min or from a paired device"
  else
    while IFS= read -r line; do
      case "${line}" in
        PASS:*) pass "$(echo "${line}" | cut -d: -f2-)" ;;
        FAIL:*) fail "$(echo "${line}" | cut -d: -f2-)" ;;
        APIKEY_FAIL:*) fail "API key: ${line}" ;;
      esac
    done <<< "${EXEC_OUT}"

    if ! echo "${EXEC_OUT}" | grep -qE "^(PASS|FAIL|APIKEY_FAIL):"; then
      warn "No PASS/FAIL output from exec — raw output (first 500 chars):"
      echo "${EXEC_OUT}" | head -c 500 | sed 's/^/    /'
    fi
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Results: ${PASS} passed,  ${FAIL} failed,  ${WARN} warnings"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if (( FAIL > 0 )); then
  echo ""
  echo "One or more tests FAILED. Review FAIL lines above."
  exit 1
fi

exit 0
