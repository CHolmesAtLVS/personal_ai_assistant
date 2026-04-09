#!/usr/bin/env bash
# DEPRECATED: This script seeds config via Azure Container Apps (ACA) exec. ACA has been
# decommissioned for the dev environment (2026-04-09) per feature-aks-decommission-1.md.
# For AKS config updates use: kubectl exec -n openclaw deployment/openclaw -c main --
#   node /app/openclaw.mjs config set <key> <value>
# or update workloads/dev/openclaw/values.yaml and merge to trigger ArgoCD sync.
# Retained for historical reference and rollback scenarios during the prod soak period.
#
# seed-openclaw-config.sh — Seed the OpenClaw gateway config locally via az containerapp exec.
#
# For LOCAL use from an interactive shell (devcontainer, laptop). Requires a TTY.
# For CI (GitHub Actions), use scripts/seed-openclaw-ci.sh instead — it wraps
# az containerapp exec in script(1) to allocate a pseudo-TTY and avoids the
# ENOTTY (errno 25) error that occurs in non-interactive CI runners.
#
# Steps:
#   1. Validate config/openclaw.batch.json (python3 JSON check)
#   2. Upload batch to Azure Files share at .seed/seed.batch.json
#   3. az containerapp exec: node /app/openclaw.mjs config set --batch-file
#   4. Delete staged batch file from share
#   5. az containerapp exec: node /app/openclaw.mjs config validate
#
# No openclaw CLI needed on the local machine — uses node /app/openclaw.mjs
# inside the running container.
#
# Usage:
#   bash scripts/seed-openclaw-config.sh [dev|prod]
#
# Prerequisites:
#   - az login with access to the environment resource group
#   - Container App is running (revision active)
#   - config/openclaw.batch.json is up to date
#   - Interactive TTY (devcontainer shell, not CI)
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
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  echo "ERROR: seed-openclaw-config.sh is for local use only." >&2
  echo "       Use scripts/seed-openclaw-ci.sh in GitHub Actions." >&2
  exit 1
fi

if [[ "${ENV}" == "prod" ]]; then
  echo "⚠  WARNING: You are about to seed PRODUCTION config."
  echo "   This modifies the live gateway config on the prod Azure Files share."
  read -r -p "   Type 'prod' to confirm and continue: " confirmation
  if [[ "${confirmation}" != "prod" ]]; then echo "Aborted."; exit 1; fi
fi

echo "SEED: environment=${ENV}  app=${APP_NAME}  rg=${RG_NAME}"
echo "SEED: batch file=${BATCH_FILE}"

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

# ── Step 3: Apply via exec (exec 1/2) ────────────────────────────────────────────
echo "SEED: applying config (exec 1/2)..."
APPLY_OUT=$(az containerapp exec \
  --name "${APP_NAME}" \
  --resource-group "${RG_NAME}" \
  --command "node /app/openclaw.mjs config set --batch-file ${CONTAINER_PATH}" \
  2>&1 || true)
echo "${APPLY_OUT}" | grep -v "^INFO\|Connecting\|ctrl\|Successfully\|Disconnecting" || true

# ── Step 4: Remove staged file ────────────────────────────────────────────────────
az storage file delete \
  --account-name "${STORAGE_ACCOUNT}" --account-key "${STORAGE_KEY}" \
  --share-name "${SHARE_NAME}" --path "${STAGED_PATH}" --output none 2>&1 || true
echo "SEED: staged file removed"

if echo "${APPLY_OUT}" | grep -iq "429\|rate.limit\|Too Many"; then
  echo "SEED: ❌ exec rate-limited (HTTP 429). Wait 10 minutes and retry." >&2; exit 1
elif echo "${APPLY_OUT}" | grep -q "changedPaths\|Updated.*config path"; then
  echo "SEED: ✅ config applied"
else
  echo "SEED: ⚠  no changedPaths in output — review above"
fi

# ── Step 5: Validate via exec (exec 2/2) ─────────────────────────────────────────
echo ""
echo "SEED: validating config (exec 2/2)..."
VALIDATE_OUT=$(az containerapp exec \
  --name "${APP_NAME}" \
  --resource-group "${RG_NAME}" \
  --command "node /app/openclaw.mjs config validate" \
  2>&1 || true)
echo "${VALIDATE_OUT}" | grep -v "^INFO\|Connecting\|ctrl\|Successfully\|Disconnecting" || true

if echo "${VALIDATE_OUT}" | grep -iq "429\|rate.limit\|Too Many"; then
  echo "SEED: ⚠  exec rate-limited on validate — config was applied; validate manually"
elif echo "${VALIDATE_OUT}" | grep -iq "error\|invalid\|failed"; then
  echo "SEED: ⚠  config validate reported issues — review output above"
else
  echo "SEED: ✅ config validate passed"
fi

echo ""
echo "SEED: done."
if echo "${APPLY_OUT}" | grep -iq "Restart the gateway to apply"; then
  echo "SEED: gateway.* settings changed — restarting revision..."
  REVISION=$(az containerapp revision list \
    --name "${APP_NAME}" \
    --resource-group "${RG_NAME}" \
    --query '[0].name' -o tsv)
  az containerapp revision restart \
    --name "${APP_NAME}" \
    --resource-group "${RG_NAME}" \
    --revision "${REVISION}"
  echo "SEED: ✅ revision restarted"
fi


set -euo pipefail

ENV="${1:-dev}"
USE_EXEC=false
if [[ "${2:-}" == "--exec" ]]; then
  USE_EXEC=true
fi
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
# Staged under a hidden prefix so it is not mistaken for persistent config
STAGED_PATH=".seed/seed.batch.json"
# Path inside the container (share mounted at /home/node/.openclaw)
CONTAINER_PATH="/home/node/.openclaw/.seed/seed.batch.json"
# Live config path on the share
CONFIG_PATH="openclaw.json"

# ── Safety guard ────────────────────────────────────────────────────────────────
if [[ "${ENV}" == "prod" ]]; then
  echo "⚠  WARNING: You are about to seed PRODUCTION config."
  echo "   This modifies the live gateway config on the prod Azure Files share."
  # In CI, hard-fail for prod unless ALLOW_PROD_SEED=true is explicitly set.
  # This prevents automated runs from silently modifying live production config.
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    if [[ "${ALLOW_PROD_SEED:-}" != "true" ]]; then
      echo "ERROR: ENV=prod in CI but ALLOW_PROD_SEED=true is not set — refusing to seed production config." >&2
      exit 1
    fi
    echo "   Running in CI with ALLOW_PROD_SEED=true — skipping interactive prompt."
  else
    read -r -p "   Type 'prod' to confirm and continue: " confirmation
    if [[ "${confirmation}" != "prod" ]]; then
      echo "Aborted."
      exit 1
    fi
  fi
fi

# ── PTY helper (exec method only) ────────────────────────────────────────────────
# Wraps az containerapp exec in script(1) to allocate a pseudo-TTY.
# az containerapp exec calls termios.tcgetattr() during WebSocket setup;
# without a TTY (CI runners) this raises ENOTTY (errno 25).
# script -q -c "<cmd>" /dev/null allocates a pty, discards the typescript,
# and returns the command's exit code. tr -d '\r' strips pty carriage returns.
pty_exec() {
  local oc_cmd="$1"
  script -q -c "az containerapp exec \
    --name ${APP_NAME} \
    --resource-group ${RG_NAME} \
    --command '${oc_cmd}'" /dev/null \
    | tr -d '\r'
}

echo "SEED: environment=${ENV}  app=${APP_NAME}  rg=${RG_NAME}  method=$(${USE_EXEC} && echo exec || echo local-apply)"
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

if [[ "${USE_EXEC}" == "true" ]]; then
  # ── EXEC METHOD (local / interactive only) ─────────────────────────────────────
  # Upload batch to share, apply via az containerapp exec, clean up.
  # Requires TTY — fails in CI with ENOTTY. Use only from an interactive shell.
  echo "SEED: ensuring staging directory exists on share..."
  az storage directory create \
    --account-name "${STORAGE_ACCOUNT}" \
    --account-key "${STORAGE_KEY}" \
    --share-name "${SHARE_NAME}" \
    --name ".seed" \
    --output none 2>&1 || true

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

  echo "SEED: applying config via exec (pty workaround)..."
  APPLY_OUT=$(pty_exec "node /app/openclaw.mjs config set --batch-file ${CONTAINER_PATH}" 2>&1 || true)
  echo "${APPLY_OUT}" | grep -v "^INFO\|Connecting\|ctrl\|Successfully\|Disconnecting" || true

  echo "SEED: removing staged batch file from share..."
  az storage file delete \
    --account-name "${STORAGE_ACCOUNT}" \
    --account-key "${STORAGE_KEY}" \
    --share-name "${SHARE_NAME}" \
    --path "${STAGED_PATH}" \
    --output none 2>&1 || true
  echo "SEED: staged file removed"

  if echo "${APPLY_OUT}" | grep -q "changedPaths\|Updated.*config path"; then
    echo "SEED: ✅ Config applied via exec"
  elif echo "${APPLY_OUT}" | grep -iq "429\|rate.limit\|Too Many"; then
    echo "SEED: ❌ exec rate-limited (HTTP 429). Wait 10 minutes and retry." >&2
    exit 1
  elif echo "${APPLY_OUT}" | grep -iq "ENOTTY\|ioctl\|Inappropriate"; then
    echo "SEED: ❌ exec ENOTTY — script(1) pty workaround failed. Check script is installed (util-linux)." >&2
    exit 1
  else
    echo "SEED: ⚠  No changedPaths in output — review exec output above"
  fi

else
  # ── LOCAL-APPLY METHOD (CI-compatible, default) ────────────────────────────────
  # Download openclaw.json from the share, apply the batch locally using the
  # openclaw CLI, validate, then upload the result back to the share.
  # The gateway hot-reloads from the Azure Files mount — no exec required.
  TMP_CONFIG="$(mktemp /tmp/openclaw-seed-XXXXXX.json)"
  cleanup() { rm -f "${TMP_CONFIG}" 2>/dev/null || true; }
  trap cleanup EXIT

  echo "SEED: downloading current config from share (if exists)..."
  if ! az storage file download \
    --account-name "${STORAGE_ACCOUNT}" \
    --account-key "${STORAGE_KEY}" \
    --share-name "${SHARE_NAME}" \
    --path "${CONFIG_PATH}" \
    --dest "${TMP_CONFIG}" \
    --no-progress \
    --output none 2>/dev/null; then
    echo "SEED: no existing config on share — starting from empty config"
    echo '{}' > "${TMP_CONFIG}"
  fi

  if ! command -v openclaw &>/dev/null; then
    echo "SEED: installing openclaw CLI..."
    npm install -g openclaw 2>&1
    # npm install -g puts binaries in $(npm prefix -g)/bin which may not be on PATH in CI.
    NPM_BIN="$(npm prefix -g)/bin"
    export PATH="${NPM_BIN}:${PATH}"
  fi
  if ! command -v openclaw &>/dev/null; then
    echo "ERROR: openclaw not found after npm install — check npm global bin path" >&2
    echo "SEED: npm prefix -g = $(npm prefix -g)" >&2
    echo "SEED: PATH = ${PATH}" >&2
    exit 1
  fi
  echo "SEED: openclaw $(openclaw --version 2>/dev/null | head -1 || echo 'unknown')"

  echo "SEED: applying batch locally..."
  APPLY_OUT=$(OPENCLAW_CONFIG_PATH="${TMP_CONFIG}" openclaw config set --batch-file "${BATCH_FILE}" 2>&1 || echo "OC_APPLY_FAILED")
  echo "${APPLY_OUT}"

  if echo "${APPLY_OUT}" | grep -q "OC_APPLY_FAILED"; then
    echo "SEED: ❌ local apply failed — aborting, not uploading" >&2
    exit 1
  fi

  echo "SEED: validating..."
  VALIDATE_OUT=$(OPENCLAW_CONFIG_PATH="${TMP_CONFIG}" openclaw config validate 2>&1 || echo "OC_VALIDATE_FAILED")
  echo "${VALIDATE_OUT}"
  if echo "${VALIDATE_OUT}" | grep -q "OC_VALIDATE_FAILED"; then
    echo "SEED: ❌ config validate failed — aborting, not uploading" >&2
    exit 1
  fi

  echo "SEED: uploading updated config to share..."
  az storage file upload \
    --account-name "${STORAGE_ACCOUNT}" \
    --account-key "${STORAGE_KEY}" \
    --share-name "${SHARE_NAME}" \
    --source "${TMP_CONFIG}" \
    --path "${CONFIG_PATH}" \
    --no-progress \
    --output none 2>&1
  echo "SEED: ✅ Config applied and uploaded (gateway hot-reloads from share)"
fi

echo ""
echo "SEED: done. Gateway config updated on Azure Files share."
if echo "${APPLY_OUT}" | grep -iq "Restart the gateway to apply"; then
  echo "SEED: gateway.* settings changed — restarting revision..."
  REVISION=$(az containerapp revision list \
    --name "${APP_NAME}" \
    --resource-group "${RG_NAME}" \
    --query '[0].name' -o tsv)
  az containerapp revision restart \
    --name "${APP_NAME}" \
    --resource-group "${RG_NAME}" \
    --revision "${REVISION}"
  echo "SEED: ✅ revision restarted"
fi
