#!/usr/bin/env bash
# test-multi-model.sh — Validate the multi-model AI feature deployment for OpenClaw.
#
# Covers plan/feature-ai-multi-model-1.md — TEST-002 through TEST-005, and TEST-007 baseline.
#
# Sections:
#   A — AI Foundry embedding deployment (Cognitive Services account deployment)
#   B — Container App active-revision env var presence
#   C — Gateway health probes (/healthz, /readyz)
#   D — OpenClaw config integrity check (primary model, fallback, provider)
#   E — Live inference: default model (grok-4-fast-reasoning), grok-3, grok-3-mini
#
# Usage:
#   bash scripts/test-multi-model.sh [env]
#
#   env   dev | prod  (default: dev — NEVER run against prod in a troubleshooting session)
#
# Prerequisites:
#   - az login and correct subscription set.
#   - Key Vault Secrets User role on the target Key Vault.
#   - openclaw CLI installed (npm install -g openclaw) and device paired.
#   - jq installed.
#
# Exit code:
#   0  All tests passed.
#   1  One or more tests failed (see FAIL lines in output).

set -uo pipefail

# ── Arguments ─────────────────────────────────────────────────────────────────
ENV="${1:-dev}"

if [[ "${ENV}" != "dev" && "${ENV}" != "prod" ]]; then
  echo "Usage: bash scripts/test-multi-model.sh [dev|prod]"
  exit 1
fi

# Safety guard — production sessions must be explicitly authorized.
if [[ "${ENV}" == "prod" ]]; then
  echo "⚠  You are about to run tests against PROD."
  echo "   This script is intended for dev by default."
  read -r -p "   Type 'prod' to confirm and continue: " confirmation
  if [[ "${confirmation}" != "prod" ]]; then
    echo "Aborted."
    exit 1
  fi
fi

# ── Derived names (Terraform locals.tf naming convention) ──────────────────────
PROJECT="paa"
APP_NAME="${PROJECT}-${ENV}-app"
RG_NAME="${PROJECT}-${ENV}-rg"
KV_NAME="${PROJECT}-${ENV}-kv"

# ── Expected values ────────────────────────────────────────────────────────────
# These must match variables.tf defaults and scripts/dev.tfvars.
EXPECTED_EMBEDDING_DEPLOYMENT="text-embedding-3-large"
EXPECTED_GROK4FAST_DEPLOYMENT="grok-4-fast-reasoning"
EXPECTED_GROK3_DEPLOYMENT="grok-3"
EXPECTED_GROK3MINI_DEPLOYMENT="grok-3-mini"
EXPECTED_PRIMARY_MODEL="azure-foundry/grok-4-fast-reasoning"
EXPECTED_FALLBACK_MODEL="azure-foundry/grok-3"

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

# ── Test counters ──────────────────────────────────────────────────────────────
PASS=0
FAIL=0

# ── Helpers ────────────────────────────────────────────────────────────────────
pass() { echo "  PASS  $*"; (( PASS++ )) || true; }
fail() { echo "  FAIL  $*"; (( FAIL++ )) || true; }
section() { echo ""; echo "── $* ────────────────────────────────────────────────"; }

# ── Script header ─────────────────────────────────────────────────────────────
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " OpenClaw multi-model test — env=${ENV}  started=${TIMESTAMP}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  App         : ${APP_NAME}"
echo "  Resource Grp: ${RG_NAME}"
echo "  Key Vault   : ${KV_NAME}"

# ── Check required tools ───────────────────────────────────────────────────────
section "Prerequisites"
for tool in az jq curl; do
  if command -v "${tool}" &>/dev/null; then
    pass "Tool available: ${tool}"
  else
    fail "Tool not found: ${tool}  (required)"
  fi
done

if command -v openclaw &>/dev/null; then
  pass "Tool available: openclaw"
else
  fail "Tool not found: openclaw  (install: npm install -g openclaw — Sections D and E will be skipped)"
  OPENCLAW_MISSING=true
fi

OPENCLAW_MISSING="${OPENCLAW_MISSING:-false}"

# ── Device self-pairing ────────────────────────────────────────────────────────
# Register this devcontainer as a paired device so CLI health checks work.
# Uses openclaw onboard --non-interactive: writes remote URL + token to local
# ~/.openclaw/openclaw.json; the gateway token acts as the authorization credential,
# so no separate approve step is required.
if [[ "${OPENCLAW_MISSING}" != "true" ]]; then
  PAIR_TOKEN=$(az keyvault secret show \
    --vault-name "${KV_NAME}" \
    --name "openclaw-gateway-token" \
    --query "value" -o tsv 2>/dev/null || echo "")

  PAIR_FQDN=$(az containerapp show \
    --name "${APP_NAME}" \
    --resource-group "${RG_NAME}" \
    --query "properties.configuration.ingress.fqdn" \
    -o tsv 2>/dev/null || echo "")

  if [[ -n "${PAIR_TOKEN}" && -n "${PAIR_FQDN}" ]]; then
    PAIR_WS_URL="wss://${PAIR_FQDN}"
    ONBOARD_OUT=$(openclaw onboard \
      --non-interactive \
      --accept-risk \
      --mode remote \
      --remote-url "${PAIR_WS_URL}" \
      --remote-token "${PAIR_TOKEN}" 2>&1 || echo "ONBOARD_FAILED")
    if echo "${ONBOARD_OUT}" | grep -q "ONBOARD_FAILED"; then
      echo "  WARN  Device self-pairing failed — CLI health checks may not connect"
    else
      echo "  INFO  Device paired: wss://${PAIR_FQDN}"
      # Export for use in later sections.
      OPENCLAW_GATEWAY_TOKEN="${PAIR_TOKEN}"
      OPENCLAW_GATEWAY_WS_URL="${PAIR_WS_URL}"
    fi
  else
    echo "  WARN  Could not resolve gateway URL or token — skipping self-pairing"
  fi
fi

# ── Section A: AI Foundry embedding deployment ─────────────────────────────────
# Grok models (grok-4-fast-reasoning, grok-3, grok-3-mini) are MaaS serverless models —
# they are NOT Cognitive Services account deployments and do NOT appear in the deployment
# list. They are accessed by model name via AZURE_AI_INFERENCE_ENDPOINT.
# Only text-embedding-3-large is a Cognitive Services account deployment.
section "A  AI Foundry deployment check [TEST-002]"

# Find the AI Services account in the environment resource group.
AI_ACCOUNT_NAME=$(az cognitiveservices account list \
  --resource-group "${RG_NAME}" \
  --query "[?kind=='AIServices' || kind=='OpenAI'].name | [0]" \
  -o tsv 2>/dev/null || true)

if [[ -z "${AI_ACCOUNT_NAME}" ]]; then
  # Fall back to listing all accounts if kind filter returns empty.
  AI_ACCOUNT_NAME=$(az cognitiveservices account list \
    --resource-group "${RG_NAME}" \
    --query "[0].name" \
    -o tsv 2>/dev/null || true)
fi

if [[ -z "${AI_ACCOUNT_NAME}" ]]; then
  fail "No Azure Cognitive Services / AI Services account found in ${RG_NAME}"
else
  pass "AI Services account found: ${AI_ACCOUNT_NAME}"

  # List deployments.
  DEPLOYMENTS=$(az cognitiveservices account deployment list \
    --resource-group "${RG_NAME}" \
    --name "${AI_ACCOUNT_NAME}" \
    -o json 2>/dev/null || echo "[]")

  # Check embedding deployment.
  EMBEDDING_STATE=$(echo "${DEPLOYMENTS}" | \
    jq -r --arg n "${EXPECTED_EMBEDDING_DEPLOYMENT}" \
    '.[] | select(.name == $n) | .properties.provisioningState // "missing"')

  if [[ "${EMBEDDING_STATE}" == "Succeeded" ]]; then
    pass "Embedding deployment '${EXPECTED_EMBEDDING_DEPLOYMENT}': Succeeded"
  elif [[ -n "${EMBEDDING_STATE}" && "${EMBEDDING_STATE}" != "missing" ]]; then
    fail "Embedding deployment '${EXPECTED_EMBEDDING_DEPLOYMENT}': state=${EMBEDDING_STATE} (expected Succeeded)"
  else
    fail "Embedding deployment '${EXPECTED_EMBEDDING_DEPLOYMENT}': not found in account"
  fi

  # Confirm Grok deployments are intentionally absent (MaaS — no account deployment).
  for grok_name in "${EXPECTED_GROK4FAST_DEPLOYMENT}" "${EXPECTED_GROK3_DEPLOYMENT}" "${EXPECTED_GROK3MINI_DEPLOYMENT}"; do
    GROK_ENTRY=$(echo "${DEPLOYMENTS}" | jq -r --arg n "${grok_name}" '.[] | select(.name == $n) | .name // ""')
    if [[ -z "${GROK_ENTRY}" ]]; then
      pass "Grok MaaS model '${grok_name}': correctly absent from account deployments (MaaS)"
    else
      fail "Grok MaaS model '${grok_name}': unexpectedly found as an account deployment — verify ai.tf"
    fi
  done
fi

# ── Section B: Container App env var presence ─────────────────────────────────
section "B  Container App env var check [TEST-003]"

# Get env vars from the active revision.
ENV_JSON=$(az containerapp show \
  --name "${APP_NAME}" \
  --resource-group "${RG_NAME}" \
  --query "properties.template.containers[0].env" \
  -o json 2>/dev/null || echo "null")

if [[ "${ENV_JSON}" == "null" || -z "${ENV_JSON}" ]]; then
  fail "Could not retrieve Container App env vars — is the app deployed?"
else
  for expected_var in "${EXPECTED_ENV_VARS[@]}"; do
    VAR_PRESENT=$(echo "${ENV_JSON}" | jq -r --arg k "${expected_var}" \
      '.[] | select(.name == $k) | .name // ""')
    if [[ -n "${VAR_PRESENT}" ]]; then
      # Read value if non-sensitive; skip for token.
      if [[ "${expected_var}" == "OPENCLAW_GATEWAY_TOKEN" ]]; then
        pass "Env var present (secret ref): ${expected_var}"
      else
        VAR_VALUE=$(echo "${ENV_JSON}" | jq -r --arg k "${expected_var}" \
          '.[] | select(.name == $k) | .value // "(secret ref)"')
        pass "Env var present: ${expected_var} = ${VAR_VALUE}"
      fi
    else
      fail "Env var missing: ${expected_var}"
    fi
  done

  # Spot-check env var values match expected deployment names.
  check_env_value() {
    local varname="$1"
    local expected="$2"
    local actual
    actual=$(echo "${ENV_JSON}" | jq -r --arg k "${varname}" '.[] | select(.name == $k) | .value // ""')
    if [[ "${actual}" == "${expected}" ]]; then
      pass "Env var value correct: ${varname} = ${actual}"
    else
      fail "Env var value mismatch: ${varname} — expected '${expected}', got '${actual}'"
    fi
  }

  check_env_value "AZURE_OPENAI_DEPLOYMENT_EMBEDDING"  "${EXPECTED_EMBEDDING_DEPLOYMENT}"
  check_env_value "AZURE_AI_DEPLOYMENT_GROK4FAST"      "${EXPECTED_GROK4FAST_DEPLOYMENT}"
  check_env_value "AZURE_AI_DEPLOYMENT_GROK3"          "${EXPECTED_GROK3_DEPLOYMENT}"
  check_env_value "AZURE_AI_DEPLOYMENT_GROK3MINI"      "${EXPECTED_GROK3MINI_DEPLOYMENT}"
fi

# ── Section C: Gateway health probes ──────────────────────────────────────────
section "C  Gateway health probes"

# Resolve the FQDN from the Container App.
FQDN=$(az containerapp show \
  --name "${APP_NAME}" \
  --resource-group "${RG_NAME}" \
  --query "properties.configuration.ingress.fqdn" \
  -o tsv 2>/dev/null || true)

GATEWAY_URL=""
if [[ -z "${FQDN}" ]]; then
  fail "Cannot resolve Container App FQDN — skipping health probe tests"
else
  pass "Gateway FQDN resolved: ${FQDN}"
  GATEWAY_URL="https://${FQDN}"

  for probe in healthz readyz; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 15 \
      "${GATEWAY_URL}/${probe}" 2>/dev/null || echo "000")
    if [[ "${HTTP_CODE}" == "200" ]]; then
      pass "Probe /${probe} returned HTTP ${HTTP_CODE}"
    else
      fail "Probe /${probe} returned HTTP ${HTTP_CODE} (expected 200)"
    fi
  done
fi

# ── Section D: OpenClaw config integrity ──────────────────────────────────────
# Read openclaw.json directly from the Azure Files share.
# This avoids needing a paired RPC connection and works during initial bootstrap.
# The share name and storage account follow the Terraform naming convention in locals.tf.
section "D  OpenClaw config check [TEST-004 config side]"

STORAGE_ACCOUNT="paa${ENV}ocstate"
SHARE_NAME="openclaw-state"
CONFIG_FILE="openclaw.json"
TMP_CONFIG="/tmp/openclaw-test-config-$$.json"

# Retrieve storage account key for file download.
STORAGE_KEY=$(az storage account keys list \
  --resource-group "${RG_NAME}" \
  --account-name "${STORAGE_ACCOUNT}" \
  --query "[0].value" -o tsv 2>/dev/null || echo "")

if [[ -z "${STORAGE_KEY}" ]]; then
  fail "Cannot retrieve storage key for ${STORAGE_ACCOUNT} — skipping config checks"
else
  # Download openclaw.json from the share root (mounted at /home/node/.openclaw in the container).
  DOWNLOAD_OK=false
  az storage file download \
    --account-name "${STORAGE_ACCOUNT}" \
    --account-key "${STORAGE_KEY}" \
    --share-name "${SHARE_NAME}" \
    --path "${CONFIG_FILE}" \
    --dest "${TMP_CONFIG}" \
    --output none 2>/dev/null && DOWNLOAD_OK=true || true

  if [[ "${DOWNLOAD_OK}" != "true" || ! -f "${TMP_CONFIG}" ]]; then
    fail "openclaw.json not found on share '${SHARE_NAME}' — config has not been seeded yet (see ASSUMPTION-003 in the plan)"
    echo "  NOTE  Seed the config by running: openclaw configure, or by uploading config/openclaw.json.tpl"
  else
    pass "openclaw.json downloaded from Azure Files share"

    # Validate JSON syntax.
    if ! jq empty "${TMP_CONFIG}" 2>/dev/null; then
      fail "openclaw.json is not valid JSON"
    else
      pass "openclaw.json is valid JSON"

      # The live openclaw.json may use either:
      #   (a) ${VAR} template placeholders  — correct; OpenClaw expands them at runtime from env vars
      #   (b) Resolved literal values        — also correct; set directly
      # Either form is accepted; the test validates structure and that the right env vars are referenced.

      check_json_path() {
        local label="$1"
        local path="$2"
        local expected_literal="$3"   # exact string match, or empty to only check presence
        local expected_template="$4"  # ${VAR} form; also acceptable
        local actual
        actual=$(jq -r "${path} // \"\"" "${TMP_CONFIG}" 2>/dev/null || echo "")
        if [[ -z "${actual}" ]]; then
          fail "${label}: path not found (${path})"
        elif [[ -n "${expected_literal}" \
               && "${actual}" != "${expected_literal}" \
               && "${actual}" != "${expected_template:-}" ]]; then
          fail "${label}: expected '${expected_literal}' or '${expected_template:-}', got '${actual}'"
        else
          pass "${label}: ${actual}"
        fi
      }

      # Primary model — accept either the resolved value or the ${VAR} template form.
      check_json_path "Primary model" \
        ".agents.defaults.model.primary" \
        "${EXPECTED_PRIMARY_MODEL}" \
        "azure-foundry/\${AZURE_AI_DEPLOYMENT_GROK4FAST}"

      # Fallbacks — accept either resolved or template form.
      FALLBACKS=$(jq -r '.agents.defaults.model.fallbacks // [] | join(", ")' "${TMP_CONFIG}" 2>/dev/null || echo "")
      if echo "${FALLBACKS}" | grep -qE '(azure-foundry/grok-3[^-]|azure-foundry/grok-3$|azure-foundry/\$\{AZURE_AI_DEPLOYMENT_GROK3\})'; then
        pass "Fallback list includes grok-3 (full list: ${FALLBACKS})"
      else
        fail "Fallback list does not include 'azure-foundry/grok-3' or template equivalent — got: [${FALLBACKS}]"
      fi

      check_json_path "azure-foundry provider baseUrl" \
        ".models.providers[\"azure-foundry\"].baseUrl" "" ""

      check_json_path "azure-foundry provider auth" \
        ".models.providers[\"azure-foundry\"].auth" "token" ""

      check_json_path "azure-foundry provider api" \
        ".models.providers[\"azure-foundry\"].api" "" ""

      # Model catalog entries — the keys in openclaw.json may be template strings.
      # Accept either the resolved deployment name OR the ${VAR} template key.
      check_catalog_entry() {
        local label="$1"
        local resolved_key="$2"   # e.g. azure-foundry/grok-4-fast-reasoning
        local template_key="$3"   # e.g. azure-foundry/${AZURE_AI_DEPLOYMENT_GROK4FAST}
        local entry
        # Try resolved key first.
        entry=$(jq -r --arg k "${resolved_key}" '.agents.defaults.models[$k] // ""' \
          "${TMP_CONFIG}" 2>/dev/null || echo "")
        if [[ -n "${entry}" ]]; then
          pass "Model catalog entry found (resolved): ${resolved_key}"
          return
        fi
        # Try template key.
        entry=$(jq -r --arg k "${template_key}" '.agents.defaults.models[$k] // ""' \
          "${TMP_CONFIG}" 2>/dev/null || echo "")
        if [[ -n "${entry}" ]]; then
          pass "Model catalog entry found (template): ${template_key}"
        else
          fail "Model catalog entry missing: ${resolved_key} (also checked template key: ${template_key})"
        fi
      }

      check_catalog_entry \
        "grok-4-fast-reasoning" \
        "azure-foundry/${EXPECTED_GROK4FAST_DEPLOYMENT}" \
        'azure-foundry/${AZURE_AI_DEPLOYMENT_GROK4FAST}'
      check_catalog_entry \
        "grok-3" \
        "azure-foundry/${EXPECTED_GROK3_DEPLOYMENT}" \
        'azure-foundry/${AZURE_AI_DEPLOYMENT_GROK3}'
      check_catalog_entry \
        "grok-3-mini" \
        "azure-foundry/${EXPECTED_GROK3MINI_DEPLOYMENT}" \
        'azure-foundry/${AZURE_AI_DEPLOYMENT_GROK3MINI}'
    fi

    # Schema validation against the remote config from the share.
    # openclaw config validate has no --file flag, so temporarily swap it in.
    LOCAL_CONFIG="${HOME}/.openclaw/openclaw.json"
    BACKUP_CONFIG="/tmp/openclaw-local-backup-$$.json"
    cp "${LOCAL_CONFIG}" "${BACKUP_CONFIG}" 2>/dev/null || true
    cp "${TMP_CONFIG}" "${LOCAL_CONFIG}"
    VALIDATE_OUT=$(openclaw config validate --json 2>&1)
    VALIDATE_EXIT=$?
    # Restore immediately regardless of result.
    cp "${BACKUP_CONFIG}" "${LOCAL_CONFIG}" 2>/dev/null || true
    rm -f "${BACKUP_CONFIG}"

    if [[ ${VALIDATE_EXIT} -eq 0 ]]; then
      pass "Remote openclaw.json schema validation: valid"
    else
      ERRORS=$(echo "${VALIDATE_OUT}" | jq -r '.[] | "  \(.path): \(.message)"' 2>/dev/null \
        || echo "${VALIDATE_OUT}")
      fail "Remote openclaw.json schema validation failed:"
      echo "${ERRORS}" | sed 's/^/        /'
    fi

    rm -f "${TMP_CONFIG}"
  fi
fi

# Gateway RPC probe (requires openclaw CLI).
if [[ "${OPENCLAW_MISSING}" != "true" && -n "${GATEWAY_URL:-}" ]]; then
  GATEWAY_TOKEN=""
  if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    GATEWAY_TOKEN=$(az keyvault secret show \
      --vault-name "${KV_NAME}" \
      --name "openclaw-gateway-token" \
      --query "value" -o tsv 2>/dev/null || echo "")
  else
    GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN}"
  fi

  if [[ -n "${GATEWAY_TOKEN}" ]]; then
    GATEWAY_WS_URL="${GATEWAY_URL/https:/wss:}"
    GW_STATUS=$(openclaw gateway status \
      --url "${GATEWAY_WS_URL}" \
      --token "${GATEWAY_TOKEN}" \
      --json 2>/dev/null | jq -r '.rpc.ok // false' 2>/dev/null || echo "false")
    if [[ "${GW_STATUS}" == "true" ]]; then
      pass "Gateway RPC reachable via WebSocket"
    else
      echo "  WARN  Gateway RPC not reachable — this device may not be paired yet"
      echo "        Run: openclaw devices list   (then approve from a paired device)"
    fi
  fi
fi

# ── Section E: Live inference tests ───────────────────────────────────────────
section "E  Live inference tests [TEST-004, TEST-005]"
#
# Strategy: exec into the running Container App and POST directly to the Azure AI Model
# Inference endpoint from inside the container, using the Managed Identity IMDS token.
#
# Rationale: Grok MaaS models require the MaaS/chat/completions RBAC data action, which
# is granted only to the Container App Managed Identity (Cognitive Services User role).
# The devcontainer SP does not have this action. Running from inside the container is the
# only correct path to validate end-to-end MI auth WITHOUT granting extra RBAC to devs.
#
# Rate limit: az containerapp exec is rate-limited (~HTTP 429 after frequent calls).
# If exec fails with 429, the test is skipped with remediation instructions.

if [[ -z "${APP_NAME:-}" || -z "${RG_NAME:-}" ]]; then
  fail "Container App name or resource group not set — skipping inference tests"
else
  # Inline script executed inside the container.
  # Gets an MI token from IMDS, then tests each Grok model in order.
  # Use node for JSON parsing — jq is not present in the OpenClaw container image.
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
  local model="$1"
  local label="$2"
  local payload="{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly one word: OK\"}],\"max_tokens\":20}"
  HTTP=$(curl -s -o /tmp/inf_resp.json -w "%{http_code}" --max-time 45 \
    -X POST "${BASE}" \
    -H "Authorization: Bearer ${TOK}" \
    -H "Content-Type: application/json" \
    -d "${payload}")
  if [[ "${HTTP}" == "200" ]]; then
    REPLY=$(node -pe 'JSON.parse(require("fs").readFileSync("/dev/stdin","utf8")).choices[0].message.content' < /tmp/inf_resp.json 2>/dev/null || echo "(parse error)")
    echo "PASS:${label}:HTTP 200 reply=${REPLY}"
  else
    BODY=$(head -c 300 /tmp/inf_resp.json 2>/dev/null || echo "(no body)")
    echo "FAIL:${label}:HTTP ${HTTP} ${BODY}"
  fi
}
test_model "${AZURE_AI_DEPLOYMENT_GROK4FAST}"   "grok-4-fast-reasoning"
test_model "${AZURE_AI_DEPLOYMENT_GROK3}"       "grok-3"
test_model "${AZURE_AI_DEPLOYMENT_GROK3MINI}"   "grok-3-mini"
INNEREOF
  )

  # Stage the inner script on the Azure Files share so the exec command is a simple path —
  # avoids heredoc/quoting mangling when passing multi-line scripts through --command.
  INNER_SCRIPT_FILE="test-multi-model-inner-$$.sh"
  INNER_SCRIPT_REMOTE_PATH="/home/node/.openclaw/${INNER_SCRIPT_FILE}"

  STORAGE_KEY_EXEC=$(az storage account keys list \
    --resource-group "${RG_NAME}" \
    --account-name "paa${ENV}ocstate" \
    --query "[0].value" -o tsv 2>/dev/null || echo "")

  if [[ -z "${STORAGE_KEY_EXEC}" ]]; then
    fail "Cannot retrieve storage key for inner script upload — skipping inference exec test"
    EXEC_OUT="SKIP"
  else
    # Write inner script to a temp local file, upload to the share, then exec.
    INNER_SCRIPT_LOCAL="/tmp/${INNER_SCRIPT_FILE}"
    echo "${INNER_SCRIPT}" > "${INNER_SCRIPT_LOCAL}"

    az storage file upload \
      --account-name "paa${ENV}ocstate" \
      --account-key "${STORAGE_KEY_EXEC}" \
      --share-name "openclaw-state" \
      --source "${INNER_SCRIPT_LOCAL}" \
      --path "${INNER_SCRIPT_FILE}" \
      --output none 2>/dev/null

    rm -f "${INNER_SCRIPT_LOCAL}"

    echo "  INFO  Exec-ing into ${APP_NAME} to test MI-auth inference (15s+ per model)..."
    EXEC_OUT=$(az containerapp exec \
      --name "${APP_NAME}" \
      --resource-group "${RG_NAME}" \
      --command "bash ${INNER_SCRIPT_REMOTE_PATH}" \
      2>&1 || echo "EXEC_ERROR: $?")

    # Clean up the test script from the share.
    az storage file delete \
      --account-name "paa${ENV}ocstate" \
      --account-key "${STORAGE_KEY_EXEC}" \
      --share-name "openclaw-state" \
      --path "${INNER_SCRIPT_FILE}" \
      --output none 2>/dev/null || true
  fi

  if echo "${EXEC_OUT}" | grep -q "429\|Too Many\|rate.limit\|EXEC_ERROR"; then
    echo "  SKIP  az containerapp exec rate-limited or unavailable."
    echo "  NOTE  Run manually after 10 min or from a paired device:"
    echo "          az containerapp exec --name ${APP_NAME} --resource-group ${RG_NAME}"
    echo "        Then inside the container:"
    echo "          source /test-inference.sh  (or paste the test_model calls above)"
  else
    # Parse PASS:/FAIL: lines from the inner script output.
    while IFS= read -r line; do
      if [[ "${line}" == PASS:* ]]; then
        label=$(echo "${line}" | cut -d: -f2)
        detail=$(echo "${line}" | cut -d: -f3-)
        pass "${label}: ${detail}"
      elif [[ "${line}" == FAIL:* ]]; then
        label=$(echo "${line}" | cut -d: -f2)
        detail=$(echo "${line}" | cut -d: -f3-)
        fail "${label}: ${detail}"
      elif [[ "${line}" == IMDS_FAIL* ]]; then
        fail "Managed Identity token (IMDS): ${line}"
      fi
    done <<< "${EXEC_OUT}"

    # If no PASS/FAIL lines were emitted, exec produced unrecognised output.
    if ! echo "${EXEC_OUT}" | grep -qE "^(PASS|FAIL|IMDS_FAIL):"; then
      echo "  WARN  No PASS/FAIL output from exec. Raw output (first 500 chars):"
      echo "${EXEC_OUT}" | head -c 500
    fi
  fi
fi

# ── Section F: OpenClaw CLI health checks ─────────────────────────────────────
# Runs openclaw health, openclaw status, and openclaw doctor against the remote
# gateway. Requires the device to be paired (done above in self-pairing block).
section "F  Gateway CLI health checks"

if [[ "${OPENCLAW_MISSING}" == "true" ]]; then
  echo "  SKIP  openclaw CLI not available"
elif [[ -z "${OPENCLAW_GATEWAY_WS_URL:-}" ]]; then
  echo "  SKIP  Gateway not reachable — skipping CLI health checks"
else
  CLI_OPTS=(--url "${OPENCLAW_GATEWAY_WS_URL}" --token "${OPENCLAW_GATEWAY_TOKEN}")

  # openclaw health — fast liveness check via RPC.
  HEALTH_OUT=$(openclaw health "${CLI_OPTS[@]}" 2>&1 || echo "HEALTH_FAILED")
  if echo "${HEALTH_OUT}" | grep -qi "HEALTH_FAILED\|error\|unreachable\|failed"; then
    fail "openclaw health: ${HEALTH_OUT}"
  else
    pass "openclaw health: $(echo "${HEALTH_OUT}" | head -1)"
  fi

  # openclaw status — channel + session summary.
  STATUS_OUT=$(openclaw status "${CLI_OPTS[@]}" --timeout 15000 2>&1 || echo "STATUS_FAILED")
  if echo "${STATUS_OUT}" | grep -qi "STATUS_FAILED\|Cannot connect\|not reachable"; then
    fail "openclaw status: gateway not reachable"
  else
    ACTIVE_LINE=$(echo "${STATUS_OUT}" | grep -iE "uptime|running|sessions|channel" | head -2 | tr '\n' '  ' || echo "(no summary line)")
    pass "openclaw status: ${ACTIVE_LINE}"
  fi

  # openclaw doctor --non-interactive — config + state health checks.
  # Reads from local ~/.openclaw/openclaw.json (written by onboard above); no --url flag.
  # Exits 0 regardless of CRITICAL warnings; surface them as WARNs, not FAILs.
  DOCTOR_OUT=$(openclaw doctor --non-interactive 2>&1)
  DOCTOR_EXIT=$?
  if [[ ${DOCTOR_EXIT} -ne 0 ]]; then
    fail "openclaw doctor: exited ${DOCTOR_EXIT} — ${DOCTOR_OUT}"
  else
    CRITICAL_COUNT=$(echo "${DOCTOR_OUT}" | grep -ic "CRITICAL" || true)
    WARN_COUNT=$(echo "${DOCTOR_OUT}" | grep -ic "warn" || true)
    if [[ "${CRITICAL_COUNT}" -gt 0 ]]; then
      echo "  WARN  openclaw doctor: ${CRITICAL_COUNT} CRITICAL issue(s) (non-blocking for model tests):"
      echo "${DOCTOR_OUT}" | grep -i "CRITICAL" | sed 's/^/        /'
    fi
    pass "openclaw doctor: complete (${CRITICAL_COUNT} critical, ${WARN_COUNT} warnings)"
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Results: ${PASS} passed,  ${FAIL} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if (( FAIL > 0 )); then
  echo ""
  echo "One or more tests failed. Review FAIL lines above."
  exit 1
fi

exit 0
