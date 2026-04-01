#!/usr/bin/env bash
# seed-openclaw-ci.sh — Seed OpenClaw gateway config in CI via Azure Files + exec+PTY.
#
# Designed for GitHub Actions (ubuntu-latest). Uses az containerapp exec wrapped
# in script(1) to allocate a pseudo-TTY, bypassing the ENOTTY (errno 25) error
# that az containerapp exec raises in CI when no TTY is attached.
#
# Does NOT require the openclaw CLI on the runner — uses node /app/openclaw.mjs
# inside the running container directly.
#
# Steps:
#   1. Validate config/openclaw.batch.json locally (python3 JSON check)
#   2. Upload batch to Azure Files share at .seed/seed.batch.json
#   3. exec+PTY: node /app/openclaw.mjs config set --batch-file <path>  (apply)
#   4. Delete staged batch file from share
#   5. exec+PTY: node /app/openclaw.mjs config validate                   (verify)
#
# script(1) PTY workaround:
#   script -q -c "<cmd>" /dev/null
#   Allocates a pseudo-TTY via openpty(), satisfying termios.tcgetattr().
#   Available on all ubuntu-latest runners (util-linux package).
#   Output is piped through tr -d '\r' to strip PTY carriage returns.
#
# Usage:
#   bash scripts/seed-openclaw-ci.sh [dev|prod]
#
# Prerequisites:
#   - az login with access to the environment resource group
#   - Container App is running (revision active)
#   - config/openclaw.batch.json is up to date and valid JSON
#   - script(1) available (util-linux; present on ubuntu-latest)
#
# Constraints:
#   - az containerapp exec is rate-limited (~5 sessions per 10 min; HTTP 429 = wait 10 min)
#   - This script uses 2 exec sessions (apply + validate).
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

PROJECT="${TF_VAR_project:-${TF_VAR_PROJECT:-paa}}"
APP_NAME="${PROJECT}-${ENV}-app"
RG_NAME="${PROJECT}-${ENV}-rg"
STORAGE_ACCOUNT="${PROJECT}${ENV}ocstate"
SHARE_NAME="openclaw-state"
STAGED_PATH=".seed/seed.batch.json"
CONTAINER_PATH="/home/node/.openclaw/.seed/seed.batch.json"

# ── Safety guard ────────────────────────────────────────────────────────────────
if [[ "${ENV}" == "prod" ]]; then
  echo "⚠  WARNING: You are about to seed PRODUCTION config."
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    if [[ "${ALLOW_PROD_SEED:-}" != "true" ]]; then
      echo "ERROR: ENV=prod in CI but ALLOW_PROD_SEED=true is not set — refusing." >&2
      exit 1
    fi
    echo "   Running in CI with ALLOW_PROD_SEED=true — skipping interactive prompt."
  else
    read -r -p "   Type 'prod' to confirm and continue: " confirmation
    if [[ "${confirmation}" != "prod" ]]; then echo "Aborted."; exit 1; fi
  fi
fi

echo "SEED: environment=${ENV}  app=${APP_NAME}  rg=${RG_NAME}"
echo "SEED: batch file=${BATCH_FILE}"

# ── PTY wrapper ──────────────────────────────────────────────────────────────────
# Wraps az containerapp exec in script(1) so it gets a pseudo-TTY.
# az containerapp exec calls termios.tcgetattr() during WebSocket setup;
# CI runners have no TTY, causing ENOTTY. script(1) (util-linux) allocates
# a pty via openpty(), satisfying tcgetattr(). tr -d '\r' strips pty CR bytes.
pty_exec() {
  local oc_cmd="$1"
  script -q -c "az containerapp exec \
    --name ${APP_NAME} \
    --resource-group ${RG_NAME} \
    --command '${oc_cmd}'" /dev/null \
    | tr -d '\r'
}

# ── Step 1: Validate batch JSON locally ──────────────────────────────────────────
if ! python3 -c "import json, sys; json.load(sys.stdin)" < "${BATCH_FILE}" 2>/dev/null; then
  echo "ERROR: ${BATCH_FILE} is not valid JSON — aborting" >&2
  exit 1
fi
echo "SEED: batch JSON is valid"

# ── Step 2: Get storage key + upload batch to share ──────────────────────────────
echo "SEED: fetching storage key..."
STORAGE_KEY=$(az storage account keys list \
  --account-name "${STORAGE_ACCOUNT}" \
  --resource-group "${RG_NAME}" \
  --query "[0].value" -o tsv 2>/dev/null)
if [[ -z "${STORAGE_KEY}" ]]; then
  echo "ERROR: could not retrieve storage key for ${STORAGE_ACCOUNT}" >&2; exit 1
fi

az storage directory create \
  --account-name "${STORAGE_ACCOUNT}" --account-key "${STORAGE_KEY}" \
  --share-name "${SHARE_NAME}" --name ".seed" --output none 2>&1 || true

echo "SEED: uploading batch to share..."
az storage file upload \
  --account-name "${STORAGE_ACCOUNT}" --account-key "${STORAGE_KEY}" \
  --share-name "${SHARE_NAME}" --source "${BATCH_FILE}" \
  --path "${STAGED_PATH}" --no-progress --output none 2>&1
echo "SEED: batch uploaded"

# ── Step 3: Apply via exec+PTY (exec 1/2) ────────────────────────────────────────
echo "SEED: applying config (exec 1/2)..."
APPLY_OUT=$(pty_exec "node /app/openclaw.mjs config set --batch-file ${CONTAINER_PATH}" 2>&1 || true)
echo "${APPLY_OUT}" | grep -v "^INFO\|Connecting\|ctrl\|Successfully\|Disconnecting" || true

# ── Step 4: Remove staged file ────────────────────────────────────────────────────
az storage file delete \
  --account-name "${STORAGE_ACCOUNT}" --account-key "${STORAGE_KEY}" \
  --share-name "${SHARE_NAME}" --path "${STAGED_PATH}" --output none 2>&1 || true
echo "SEED: staged file removed"

if echo "${APPLY_OUT}" | grep -iq "429\|rate.limit\|Too Many"; then
  echo "SEED: ❌ exec rate-limited (HTTP 429). Wait 10 minutes and retry." >&2; exit 1
elif echo "${APPLY_OUT}" | grep -iq "ENOTTY\|ioctl\|Inappropriate"; then
  echo "SEED: ❌ ENOTTY — script(1) PTY workaround failed. Ensure util-linux is installed." >&2; exit 1
elif echo "${APPLY_OUT}" | grep -q "changedPaths\|Updated.*config path"; then
  echo "SEED: ✅ config applied"
else
  echo "SEED: ⚠  no changedPaths in output — review above"
fi

# ── Step 5: Validate via exec+PTY (exec 2/2) ─────────────────────────────────────
echo ""
echo "SEED: validating config (exec 2/2)..."
VALIDATE_OUT=$(pty_exec "node /app/openclaw.mjs config validate" 2>&1 || true)
echo "${VALIDATE_OUT}" | grep -v "^INFO\|Connecting\|ctrl\|Successfully\|Disconnecting" || true

if echo "${VALIDATE_OUT}" | grep -iq "429\|rate.limit\|Too Many"; then
  echo "SEED: ⚠  exec rate-limited on validate (HTTP 429) — config was applied; validate manually"
elif echo "${VALIDATE_OUT}" | grep -iq "error\|invalid\|failed"; then
  echo "SEED: ⚠  config validate reported issues — review output above"
else
  echo "SEED: ✅ config validate passed"
fi

echo ""
echo "SEED: done."
echo "SEED: Changes to gateway.* settings require a revision restart:"
echo "       REVISION=\$(az containerapp revision list --name ${APP_NAME} --resource-group ${RG_NAME} --query '[0].name' -o tsv)"
echo "       az containerapp revision restart --name ${APP_NAME} --resource-group ${RG_NAME} --revision \"\${REVISION}\""
