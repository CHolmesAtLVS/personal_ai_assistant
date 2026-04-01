#!/usr/bin/env bash
# test-openclaw-config.sh — Validate OpenClaw gateway config via Azure Files + exec.
#
# Uploads config/openclaw.validate.sh to the Azure Files share mounted at
# /home/node/.openclaw inside the container, then runs it with
# `az containerapp exec bash`.
#
# Same upload-then-exec pattern as seed-openclaw-config.sh.
# Uploading to the share avoids the exec command-length limit (az containerapp exec
# passes the command as a URL parameter; embedding script content inline causes HTTP 404).
# The script is staged at a fixed path on the share and removed after execution.
#
# Usage:
#   bash scripts/test-openclaw-config.sh [dev|prod]
#
# Prerequisites:
#   - az login with access to the environment resource group
#   - Container App is running (revision active)
#   - config/openclaw.validate.sh is up to date
#
# Constraints:
#   - az containerapp exec is rate-limited (~5 sessions per 10 min; HTTP 429 = wait 10 min)
#   - This script uses 1 exec session.
#   - SEC-001: targets dev only unless explicitly confirmed.

set -euo pipefail

ENV="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALIDATE_SCRIPT="${REPO_ROOT}/config/openclaw.validate.sh"

if [[ ! -f "${VALIDATE_SCRIPT}" ]]; then
  echo "ERROR: validation script not found: ${VALIDATE_SCRIPT}" >&2
  exit 1
fi

PROJECT="paa"
APP_NAME="${PROJECT}-${ENV}-app"
RG_NAME="${PROJECT}-${ENV}-rg"
STORAGE_ACCOUNT="${PROJECT}${ENV}ocstate"
SHARE_NAME="openclaw-state"
# Staged under a hidden prefix so it is not mistaken for persistent config
STAGED_PATH=".seed/validate.sh"
# Path inside the container (share mounted at /home/node/.openclaw)
CONTAINER_PATH="/home/node/.openclaw/.seed/validate.sh"

# ── Safety guard ────────────────────────────────────────────────────────────────
if [[ "${ENV}" == "prod" ]]; then
  echo "⚠  WARNING: You are about to run config validation against PRODUCTION."
  echo "   This script is intended for dev by default."
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

echo "VALIDATE: environment=${ENV}  app=${APP_NAME}  rg=${RG_NAME}"
echo "VALIDATE: script=${VALIDATE_SCRIPT}"

# ── Get storage key ──────────────────────────────────────────────────────────────
echo "VALIDATE: fetching storage key..."
STORAGE_KEY=$(az storage account keys list \
  --account-name "${STORAGE_ACCOUNT}" \
  --resource-group "${RG_NAME}" \
  --query "[0].value" -o tsv 2>/dev/null)
if [[ -z "${STORAGE_KEY}" ]]; then
  echo "ERROR: could not retrieve storage key for ${STORAGE_ACCOUNT}" >&2
  exit 1
fi
echo "VALIDATE: storage key retrieved"

# ── Step 1: Upload validation script to Azure Files share ────────────────────────
# The share is mounted read-write at /home/node/.openclaw inside the container.
echo "VALIDATE: ensuring staging directory exists on share..."
az storage directory create \
  --account-name "${STORAGE_ACCOUNT}" \
  --account-key "${STORAGE_KEY}" \
  --share-name "${SHARE_NAME}" \
  --name ".seed" \
  --output none 2>&1 || true  # idempotent — ok if already exists

echo "VALIDATE: uploading script to share ${STORAGE_ACCOUNT}/${SHARE_NAME}/${STAGED_PATH}..."
az storage file upload \
  --account-name "${STORAGE_ACCOUNT}" \
  --account-key "${STORAGE_KEY}" \
  --share-name "${SHARE_NAME}" \
  --source "${VALIDATE_SCRIPT}" \
  --path "${STAGED_PATH}" \
  --no-progress \
  --output none 2>&1
echo "VALIDATE: script uploaded to share"

# ── Step 2: Run validation script via exec (exec 1/1) ───────────────────────────
echo "VALIDATE: running validation (exec 1/1)..."
VALIDATE_OUT=$(az containerapp exec \
  --name "${APP_NAME}" \
  --resource-group "${RG_NAME}" \
  --command "bash ${CONTAINER_PATH}" \
  2>&1 || true)

echo "${VALIDATE_OUT}" | grep -v "^INFO\|Connecting\|ctrl\|Successfully\|Disconnecting" || true

# ── Clean up staged file from share ─────────────────────────────────────────────
echo "VALIDATE: removing staged script from share..."
az storage file delete \
  --account-name "${STORAGE_ACCOUNT}" \
  --account-key "${STORAGE_KEY}" \
  --share-name "${SHARE_NAME}" \
  --path "${STAGED_PATH}" \
  --output none 2>&1 || true
echo "VALIDATE: staged file removed"

# ── Evaluate result ──────────────────────────────────────────────────────────────
if echo "${VALIDATE_OUT}" | grep -iq "429\|rate.limit\|Too Many"; then
  echo ""
  echo "VALIDATE: ❌ exec rate-limited (HTTP 429). Wait 10 minutes and retry." >&2
  exit 1
elif echo "${VALIDATE_OUT}" | grep -q "FAIL"; then
  echo ""
  echo "VALIDATE: ❌ config validation found failures — review output above"
  exit 1
else
  echo ""
  echo "VALIDATE: ✅ config validation passed"
fi
