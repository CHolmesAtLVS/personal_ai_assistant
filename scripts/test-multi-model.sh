#!/usr/bin/env bash
# test-multi-model.sh — OpenClaw gateway health validation
#
# Pairs this machine as a temporary trusted device, runs layered health checks
# against the remote gateway, revokes the device, and restores local state.
#
# Sections:
#   A — Infrastructure pre-flight  (AI account, env vars, health probes)
#   B — Gateway health             (openclaw health, probe, RPC status)
#   C — Full gateway status        (openclaw status --all)
#   D — Remote config validation   (schema, auth mode, primary model, catalog)
#   E — Model availability         (openclaw models status)
#   F — Channel health             (openclaw channels status --probe)
#   G — Agent health               (openclaw agents status)
#   H — Memory health              (openclaw memory status --deep)
#   I — Config doctor              (openclaw doctor --non-interactive)
#   J — Live inference             (az containerapp exec — optional, rate-limited)
#
# Sections B–C and F–I require a live gateway connection (paired device).
# Sections D and E use the config swap trick and only require the CLI binary.
# Section A and J use az CLI only.
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
PROJECT="paa"
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
EXPECTED_PRIMARY_MODEL="azure-foundry/grok-4-fast-reasoning"
EXPECTED_FALLBACK_MODEL="azure-foundry/grok-3"
EXPECTED_PROVIDER_AUTH="api-key"

EXPECTED_ENV_VARS=(
  "AZURE_OPENAI_ENDPOINT"
  "AZURE_AI_INFERENCE_ENDPOINT"
  "AZURE_OPENAI_DEPLOYMENT_EMBEDDING"
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
  warn "openclaw CLI not installed — Sections B–I skipped (install: npm install -g openclaw)"
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
  warn "Cannot resolve gateway credentials or FQDN — live CLI sections B–C, F–I will be skipped"
else
  ONBOARD_OUT=$(openclaw onboard \
    --non-interactive \
    --accept-risk \
    --mode remote \
    --remote-url "${GATEWAY_WS_URL}" \
    --remote-token "${GATEWAY_TOKEN}" 2>&1 || echo "ONBOARD_FAILED")

  if echo "${ONBOARD_OUT}" | grep -q "ONBOARD_FAILED"; then
    warn "Device self-pairing failed — live gateway sections B–C, F–I will be skipped; D + E will still run"
    echo "${ONBOARD_OUT}" | head -3 | sed 's/^/    /'
  else
    pass "Device paired to ${GATEWAY_WS_URL}"
    cp "${LOCAL_CONFIG}" "${ONBOARD_CONFIG_CACHE}" 2>/dev/null || true
    # Verify the gateway accepted the session. onboard exits 0 when the pairing
    # request is submitted, but the gateway rejects with 1008 (pairing required)
    # until an admin approves the device. Probe here so failures become WARNs.
    PROBE_VERIFY=$(timeout 15 openclaw gateway probe 2>&1 || echo "OC_PROBE_FAILED")
    if echo "${PROBE_VERIFY}" | grep -qiE "pairing required|1008|OC_PROBE_FAILED|failed|error|unreachable"; then
      warn "Gateway rejected session (${PROBE_VERIFY%%$'\n'*}) — device approval pending; live sections B–C, F–I skipped"
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
section "A  Infrastructure pre-flight"

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
  check_env_value "AZURE_AI_DEPLOYMENT_GROK4FAST"     "${EXPECTED_GROK4FAST_DEPLOYMENT}"
  check_env_value "AZURE_AI_DEPLOYMENT_GROK3"         "${EXPECTED_GROK3_DEPLOYMENT}"
  check_env_value "AZURE_AI_DEPLOYMENT_GROK3MINI"     "${EXPECTED_GROK3MINI_DEPLOYMENT}"
fi

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
# Sections B–C: live gateway checks (openclaw CLI + paired session required)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "${OPENCLAW_UNAVAILABLE}" == "true" ]]; then
  warn "Sections B–C skipped (openclaw CLI not installed)"
elif [[ "${GATEWAY_CONNECTED}" != "true" ]]; then
  warn "Sections B–C skipped (pairing failed — live gateway connection unavailable)"
else

section "B  Gateway health"

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

section "C  Full gateway status"

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

fi  # end GATEWAY_CONNECTED sections (B–C)

# ══════════════════════════════════════════════════════════════════════════════
# Sections D + E: run when CLI is available, even if pairing failed.
# Both use the config swap trick (temporarily replace local config with the
# one downloaded from Azure Files) — no live gateway RPC required.
# ══════════════════════════════════════════════════════════════════════════════
if [[ "${OPENCLAW_UNAVAILABLE}" == "true" ]]; then
  warn "Sections D, E skipped (openclaw CLI not installed)"
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
fi
# AZURE_AI_API_KEY: pre-exported by CI workflow env step (or caller); no-op if already set.

section "D  Remote config validation"

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
        'azure-foundry/${AZURE_AI_DEPLOYMENT_GROK4FAST}'

      FALLBACKS=$(jq -r '.agents.defaults.model.fallbacks // [] | join(", ")' "${TMP_SHARE_CONFIG}" 2>/dev/null || echo "")
      if echo "${FALLBACKS}" | grep -qE '(azure-foundry/grok-3($|[^-])|azure-foundry/\$\{AZURE_AI_DEPLOYMENT_GROK3\})'; then
        pass "Fallback list: ${FALLBACKS}"
      else
        fail "Fallback missing grok-3: [${FALLBACKS}]"
      fi

      check_json_path "azure-foundry auth"    ".models.providers[\"azure-foundry\"].auth"    "${EXPECTED_PROVIDER_AUTH}" ""
      check_json_path "azure-foundry apiKey"  ".models.providers[\"azure-foundry\"].apiKey"  "" ""
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

section "E  Model availability"

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
# Sections F–I: live gateway checks continued (requires GATEWAY_CONNECTED)
# ══════════════════════════════════════════════════════════════════════════════
if [[ "${OPENCLAW_UNAVAILABLE}" != "true" && "${GATEWAY_CONNECTED}" == "true" ]]; then

section "F  Channel health"

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

section "G  Agent health"

AGENTS_OUT=$(oc agents status)
if echo "${AGENTS_OUT}" | grep -q "OC_TIMEOUT_OR_ERROR"; then
  warn "openclaw agents status: timed out or error"
elif echo "${AGENTS_OUT}" | grep -qiE "error|failed|missing"; then
  fail "Agent health: errors detected"
  echo "${AGENTS_OUT}" | grep -iE "error|failed|missing" | head -5 | sed 's/^/    /'
else
  pass "Agent health: $(echo "${AGENTS_OUT}" | head -1 | tr -s ' ')"
fi

section "H  Memory health"

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

section "I  Config doctor"

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

fi  # end GATEWAY_CONNECTED sections (F–I)

# ══════════════════════════════════════════════════════════════════════════════
# Section J — Live inference (exec into container)
# Runs from INSIDE the container via az containerapp exec, using an IMDS
# Managed Identity token to hit the Azure AI Model Inference endpoint.
# This validates the complete auth chain: MI → Foundry → Grok model.
# Uses node for JSON (jq is not in the OpenClaw container image).
# Rate-limited by Azure (~HTTP 429 after frequent calls; wait 10 min if hit).
# ══════════════════════════════════════════════════════════════════════════════
section "J  Live inference [TEST-004, TEST-005]"

INNER_SCRIPT=$(cat <<'INNEREOF'
set -euo pipefail
IMDS_URL="http://169.254.169.254/metadata/identity/oauth2/token"
RESOURCE="https://cognitiveservices.azure.com/"
IMDS_RESP=$(curl -s --max-time 10 \
  "${IMDS_URL}?api-version=2018-02-01&resource=${RESOURCE}" \
  -H "Metadata: true")
TOK=$(node -pe 'JSON.parse(require("fs").readFileSync("/dev/stdin","utf8")).access_token' <<< "${IMDS_RESP}")
if [[ -z "${TOK}" || "${TOK}" == "null" || "${TOK}" == "undefined" ]]; then
  echo "IMDS_FAIL: could not obtain MI token"; exit 1
fi
BASE="${AZURE_AI_INFERENCE_ENDPOINT}/chat/completions?api-version=2024-05-01-preview"
test_model() {
  local model="$1" label="$2"
  local payload="{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly one word: OK\"}],\"max_tokens\":20}"
  HTTP=$(curl -s -o /tmp/inf_resp.json -w "%{http_code}" --max-time 45 \
    -X POST "${BASE}" \
    -H "Authorization: Bearer ${TOK}" \
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
        IMDS_FAIL:*) fail "IMDS: ${line}" ;;
      esac
    done <<< "${EXEC_OUT}"

    if ! echo "${EXEC_OUT}" | grep -qE "^(PASS|FAIL|IMDS_FAIL):"; then
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
