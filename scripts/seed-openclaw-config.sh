#!/usr/bin/env bash
# seed-openclaw-config.sh — Seed the OpenClaw gateway config via Azure Files + exec.
#
# Uploads config/openclaw.batch.json directly to the Azure Files share that is
# mounted at /home/node/.openclaw inside the container, then applies it with
# `openclaw config set --batch-file` via az containerapp exec.
#
# Uploading to the share avoids the exec command-length limit (az containerapp exec
# passes the command as a URL parameter; embedding 2 KB of base64 inline causes HTTP 404).
# The batch file is staged at a fixed path on the share and removed after apply.
#
# No envsubst — secret ${VAR} refs are passed as literals and resolved by the
# gateway process at runtime.
#
# Usage:
#   bash scripts/seed-openclaw-config.sh [dev|prod]
#
# Prerequisites:
#   - az login with access to the environment resource group
#   - Container App is running (revision active)
#   - config/openclaw.batch.json is up to date
#
# Constraints:
#   - az containerapp exec is rate-limited (~5 sessions per 10 min; HTTP 429 = wait 10 min)
#   - Each run uses 2 exec sessions (apply, verify). Budget accordingly.
#   - Never expand ${VAR} refs before seeding — leave them as literals in the batch file.
#   - SEC-001: target dev only unless explicitly confirmed.

set -euo pipefail

ENV="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BATCH_FILE="${REPO_ROOT}/config/openclaw.batch.json"

if [[ ! -f "${BATCH_FILE}" ]]; then
  echo "ERROR: batch file not found: ${BATCH_FILE}" >&2
  exit 1
fi

PROJECT="paa"
APP_NAME="${PROJECT}-${ENV}-app"
RG_NAME="${PROJECT}-${ENV}-rg"
STORAGE_ACCOUNT="${PROJECT}${ENV}ocstate"
SHARE_NAME="openclaw-state"
# Staged under a hidden prefix so it is not mistaken for persistent config
STAGED_PATH=".seed/seed.batch.json"
# Path inside the container (share mounted at /home/node/.openclaw)
CONTAINER_PATH="/home/node/.openclaw/.seed/seed.batch.json"

# ── Safety guard ────────────────────────────────────────────────────────────────
if [[ "${ENV}" == "prod" ]]; then
  echo "⚠  WARNING: You are about to seed PRODUCTION config."
  echo "   This modifies the live gateway config on the prod Azure Files share."
  # Skip interactive prompt when running in CI (GitHub Actions sets GITHUB_ACTIONS=true).
  if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
    read -r -p "   Type 'prod' to confirm and continue: " confirmation
    if [[ "${confirmation}" != "prod" ]]; then
      echo "Aborted."
      exit 1
    fi
  else
    echo "   Running in CI — skipping interactive prompt."
  fi
fi

echo "SEED: environment=${ENV}  app=${APP_NAME}  rg=${RG_NAME}"
echo "SEED: batch file=${BATCH_FILE}"

# ── Validate JSON locally before sending ────────────────────────────────────────
if ! python3 -c "import json, sys; json.load(sys.stdin)" < "${BATCH_FILE}" 2>/dev/null; then
  echo "ERROR: ${BATCH_FILE} is not valid JSON — aborting" >&2
  exit 1
fi
echo "SEED: batch JSON is valid"

# ── Get storage key ──────────────────────────────────────────────────────────────
echo "SEED: fetching storage key..."
STORAGE_KEY=$(az storage account keys list \
  --account-name "${STORAGE_ACCOUNT}" \
  --resource-group "${RG_NAME}" \
  --query "[0].value" -o tsv 2>/dev/null)
if [[ -z "${STORAGE_KEY}" ]]; then
  echo "ERROR: could not retrieve storage key for ${STORAGE_ACCOUNT}" >&2
  exit 1
fi
echo "SEED: storage key retrieved"

# ── Step 1: Upload batch file to Azure Files share ───────────────────────────────
# The share is mounted read-write at /home/node/.openclaw inside the container.
# Uploading here avoids the exec command-length limit entirely.
echo "SEED: ensuring staging directory exists on share..."
az storage directory create \
  --account-name "${STORAGE_ACCOUNT}" \
  --account-key "${STORAGE_KEY}" \
  --share-name "${SHARE_NAME}" \
  --name ".seed" \
  --output none 2>&1 || true  # idempotent — ok if already exists

echo "SEED: uploading batch to share ${STORAGE_ACCOUNT}/${SHARE_NAME}/${STAGED_PATH}..."
az storage file upload \
  --account-name "${STORAGE_ACCOUNT}" \
  --account-key "${STORAGE_KEY}" \
  --share-name "${SHARE_NAME}" \
  --source "${BATCH_FILE}" \
  --path "${STAGED_PATH}" \
  --no-progress \
  --output none 2>&1
echo "SEED: batch uploaded to share"

# ── Step 2: Apply batch via exec (exec 1/2) ──────────────────────────────────────
echo "SEED: applying config (exec 1/2)..."
APPLY_OUT=$(az containerapp exec \
  --name "${APP_NAME}" \
  --resource-group "${RG_NAME}" \
  --command "node /app/openclaw.mjs config set --batch-file ${CONTAINER_PATH}" \
  2>&1 || true)

echo "${APPLY_OUT}" | grep -v "^INFO\|Connecting\|ctrl\|Successfully\|Disconnecting" || true

# ── Step 2 result check ──────────────────────────────────────────────────────────
if echo "${APPLY_OUT}" | grep -q "changedPaths"; then
  CHANGED=$(echo "${APPLY_OUT}" | grep -oE "changedPaths=[0-9]+" | head -1)
  echo ""
  echo "SEED: ✅ Config applied — ${CHANGED}"
elif echo "${APPLY_OUT}" | grep -q "Updated.*config path"; then
  echo ""
  echo "SEED: ✅ Config applied"
elif echo "${APPLY_OUT}" | grep -iq "429\|rate.limit\|Too Many"; then
  echo ""
  echo "SEED: ❌ exec rate-limited (HTTP 429). Wait 10 minutes and retry." >&2
  # Clean up staged file before exit
  az storage file delete \
    --account-name "${STORAGE_ACCOUNT}" \
    --account-key "${STORAGE_KEY}" \
    --share-name "${SHARE_NAME}" \
    --path "${STAGED_PATH}" --output none 2>/dev/null || true
  exit 1
else
  echo ""
  echo "SEED: ⚠  No changedPaths in output — verify manually with:" >&2
  echo "       az containerapp exec --name ${APP_NAME} --resource-group ${RG_NAME} \\" >&2
  echo "         --command \"node /app/openclaw.mjs config get agents.defaults.model.primary\"" >&2
fi

# ── Clean up staged file from share ─────────────────────────────────────────────
echo "SEED: removing staged batch file from share..."
az storage file delete \
  --account-name "${STORAGE_ACCOUNT}" \
  --account-key "${STORAGE_KEY}" \
  --share-name "${SHARE_NAME}" \
  --path "${STAGED_PATH}" \
  --output none 2>&1 || true
echo "SEED: staged file removed"

# ── Step 3: Verify primary model (exec 2/2) ──────────────────────────────────────
echo ""
echo "SEED: verifying primary model (reading config)..."
VERIFY_OUT=$(az containerapp exec \
  --name "${APP_NAME}" \
  --resource-group "${RG_NAME}" \
  --command "node /app/openclaw.mjs config get agents.defaults.model.primary" \
  2>&1 || true)
# Strip Azure CLI noise lines; the value is the last non-empty line of openclaw output
PRIMARY=$(echo "${VERIFY_OUT}" | grep -v "^INFO\|Connecting\|ctrl\|Successfully\|Disconnecting\|WARNING" | grep -Eo 'azure-openai/[^ ]+|text-embedding[^ ]+|[a-z][-a-z0-9]+/[a-z][-a-z0-9.]+' | tail -1)
if [[ -n "${PRIMARY}" ]]; then
  echo "SEED: ✅ agents.defaults.model.primary = ${PRIMARY}"
else
  echo "SEED: ⚠  Could not read back primary model — verify manually:"
  echo "       az containerapp exec --name ${APP_NAME} --resource-group ${RG_NAME} \\"
  echo "         --command 'node /app/openclaw.mjs config get agents.defaults.model.primary'"
fi

echo ""
echo "SEED: done. Gateway config updated on Azure Files share."
echo "SEED: Changes to gateway.* settings require a revision restart:"
echo "       REVISION=\$(az containerapp revision list --name ${APP_NAME} --resource-group ${RG_NAME} --query '[0].name' -o tsv)"
echo "       az containerapp revision restart --name ${APP_NAME} --resource-group ${RG_NAME} --revision \"\${REVISION}\""
