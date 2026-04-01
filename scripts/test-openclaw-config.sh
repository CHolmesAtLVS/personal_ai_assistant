#!/usr/bin/env bash
# test-openclaw-config.sh — Validate the live OpenClaw gateway config via exec+PTY.
#
# Runs `node /app/openclaw.mjs config validate` inside the running container
# via az containerapp exec, wrapped in script(1) to allocate a pseudo-TTY.
#
# This validates what the gateway process actually has in memory — more
# meaningful than validating the file on disk. No openclaw CLI on the runner,
# no npm install needed.
#
# script(1) PTY workaround: az containerapp exec calls termios.tcgetattr()
# during WebSocket setup. Without a TTY (CI runners) this raises ENOTTY.
# script -q -c "..." /dev/null allocates a pty via openpty(), satisfying
# tcgetattr(). Available on all ubuntu-latest runners (util-linux).
#
# Usage:
#   bash scripts/test-openclaw-config.sh [dev|prod]
#
# Prerequisites:
#   - az login with access to the environment resource group
#   - Container App is running (revision active)
#   - script(1) available (util-linux; present on ubuntu-latest and devcontainer)
#
# Constraints:
#   - az containerapp exec is rate-limited (~5 sessions per 10 min; HTTP 429 = wait 10 min)
#   - This script uses 1 exec session.
#   - SEC-001: targets dev only unless explicitly confirmed.

set -euo pipefail

ENV="${1:-dev}"

PROJECT="${TF_VAR_project:-${TF_VAR_PROJECT:-paa}}"
APP_NAME="${PROJECT}-${ENV}-app"
RG_NAME="${PROJECT}-${ENV}-rg"

# ── Safety guard ────────────────────────────────────────────────────────────────
if [[ "${ENV}" == "prod" ]]; then
  echo "⚠  WARNING: You are about to validate PRODUCTION config."
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

echo "VALIDATE: environment=${ENV}  app=${APP_NAME}  rg=${RG_NAME}"
echo "VALIDATE: running openclaw config validate via exec+PTY..."

VALIDATE_OUT=$(script -q -c "az containerapp exec \
  --name ${APP_NAME} \
  --resource-group ${RG_NAME} \
  --command 'node /app/openclaw.mjs config validate'" /dev/null \
  | tr -d '\r' 2>&1 || true)

echo "${VALIDATE_OUT}" | grep -v "^INFO\|Connecting\|ctrl\|Successfully\|Disconnecting" || true

if echo "${VALIDATE_OUT}" | grep -iq "429\|rate.limit\|Too Many"; then
  echo "VALIDATE: ❌ exec rate-limited (HTTP 429). Wait 10 minutes and retry." >&2; exit 1
elif echo "${VALIDATE_OUT}" | grep -iq "ENOTTY\|ioctl\|Inappropriate"; then
  echo "VALIDATE: ❌ ENOTTY — ensure script(1) (util-linux) is installed." >&2; exit 1
elif echo "${VALIDATE_OUT}" | grep -iq "Config valid\|validation passed"; then
  echo "VALIDATE: ✅ config validate passed"
else
  echo "VALIDATE: ⚠  unexpected output — review above"
fi


set -euo pipefail

ENV="${1:-dev}"

PROJECT="${TF_VAR_project:-${TF_VAR_PROJECT:-paa}}"
APP_NAME="${PROJECT}-${ENV}-app"
RG_NAME="${PROJECT}-${ENV}-rg"
STORAGE_ACCOUNT="${PROJECT}${ENV}ocstate"
SHARE_NAME="openclaw-state"
# Live gateway config path on the share (mounted at /home/node/.openclaw in the container)
CONFIG_ON_SHARE="openclaw.json"
TMP_CONFIG="$(mktemp /tmp/openclaw-validate-XXXXXX.json)"

# ── Safety guard ────────────────────────────────────────────────────────────────
if [[ "${ENV}" == "prod" ]]; then
  echo "⚠  WARNING: You are about to validate PRODUCTION config."
  # In CI, hard-fail for prod unless ALLOW_PROD_SEED=true is explicitly set.
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    if [[ "${ALLOW_PROD_SEED:-}" != "true" ]]; then
      echo "ERROR: ENV=prod in CI but ALLOW_PROD_SEED=true is not set — refusing to validate production config." >&2
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

echo "VALIDATE: environment=${ENV}  app=${APP_NAME}  rg=${RG_NAME}"

cleanup() { rm -f "${TMP_CONFIG}" 2>/dev/null || true; }
trap cleanup EXIT

# ── Step 1: Fetch storage key ────────────────────────────────────────────────────────
STORAGE_KEY=$(az storage account keys list \
  --account-name "${STORAGE_ACCOUNT}" \
  --resource-group "${RG_NAME}" \
  --query "[0].value" -o tsv 2>/dev/null)
if [[ -z "${STORAGE_KEY}" ]]; then
  echo "ERROR: could not retrieve storage key for ${STORAGE_ACCOUNT}" >&2
  exit 1
fi
echo "VALIDATE: storage key retrieved"

# ── Step 2: Download live openclaw.json from Azure Files ──────────────────────────
echo "VALIDATE: downloading ${CONFIG_ON_SHARE} from share..."
if ! az storage file download \
  --account-name "${STORAGE_ACCOUNT}" \
  --account-key "${STORAGE_KEY}" \
  --share-name "${SHARE_NAME}" \
  --path "${CONFIG_ON_SHARE}" \
  --dest "${TMP_CONFIG}" \
  --no-progress \
  --output none 2>&1; then
  echo "VALIDATE: ⚠  ${CONFIG_ON_SHARE} not found on share — config not yet seeded; skipping validate"
  exit 0
fi
echo "VALIDATE: config downloaded to ${TMP_CONFIG}"

# ── Step 3: Install openclaw CLI ────────────────────────────────────────────────────────
if ! command -v openclaw &>/dev/null; then
  echo "VALIDATE: installing openclaw CLI..."
  npm install -g openclaw 2>&1
  NPM_BIN="$(npm prefix -g)/bin"
  export PATH="${NPM_BIN}:${PATH}"
fi
if ! command -v openclaw &>/dev/null; then
  echo "ERROR: openclaw not found after npm install — npm prefix -g = $(npm prefix -g)" >&2
  exit 1
fi
echo "VALIDATE: openclaw $(openclaw --version 2>/dev/null | head -1 || echo 'unknown')"

# ── Step 4: Run config validate locally ───────────────────────────────────────────────
echo "VALIDATE: running openclaw config validate..."
VALIDATE_OUT=$(OPENCLAW_CONFIG_PATH="${TMP_CONFIG}" openclaw config validate 2>&1 || echo "OC_VALIDATE_FAILED")
echo "${VALIDATE_OUT}"

if echo "${VALIDATE_OUT}" | grep -q "OC_VALIDATE_FAILED"; then
  echo ""
  echo "VALIDATE: ❌ config validate failed — review output above"
  exit 1
else
  echo ""
  echo "VALIDATE: ✅ config validate passed"
fi

set -euo pipefail

ENV="${1:-dev}"

PROJECT="paa"
APP_NAME="${PROJECT}-${ENV}-app"
RG_NAME="${PROJECT}-${ENV}-rg"

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

OC="node /app/openclaw.mjs"
FAIL=0

# Helper: strip Azure CLI noise lines from exec output.
strip_noise() { grep -v "^INFO\|Connecting\|ctrl\|Successfully\|Disconnecting\|WARNING" || true; }

# ── Step 1: openclaw config validate (exec 1/2) ──────────────────────────────────
echo "VALIDATE: running config validate (exec 1/2)..."
VALIDATE_OUT=$(az containerapp exec \
  --name "${APP_NAME}" \
  --resource-group "${RG_NAME}" \
  --command "${OC} config validate" \
  2>&1 || true)
echo "${VALIDATE_OUT}" | strip_noise

if echo "${VALIDATE_OUT}" | grep -iq "429\|rate.limit\|Too Many"; then
  echo "VALIDATE: ❌ exec rate-limited (HTTP 429). Wait 10 minutes and retry." >&2
  exit 1
elif echo "${VALIDATE_OUT}" | grep -qi "error\|invalid\|Error\|Invalid\|failed"; then
  echo "VALIDATE: ❌ config validate — errors detected"
  FAIL=1
else
  echo "VALIDATE: ✅ config validate"
fi

# ── Step 2: openclaw doctor (exec 2/2) ──────────────────────────────────────────
echo ""
echo "VALIDATE: running doctor (exec 2/2)..."
DOCTOR_OUT=$(az containerapp exec \
  --name "${APP_NAME}" \
  --resource-group "${RG_NAME}" \
  --command "${OC} doctor --non-interactive" \
  2>&1 || true)
echo "${DOCTOR_OUT}" | strip_noise

if echo "${DOCTOR_OUT}" | grep -iq "429\|rate.limit\|Too Many"; then
  echo "VALIDATE: ❌ exec rate-limited (HTTP 429). Wait 10 minutes and retry." >&2
  exit 1
elif echo "${DOCTOR_OUT}" | grep -qi "critical\|failed"; then
  echo "VALIDATE: ❌ doctor — critical issues detected"
  FAIL=1
else
  echo "VALIDATE: ✅ doctor"
fi

# ── Summary ──────────────────────────────────────────────────────────────────────
echo ""
if [[ "${FAIL}" -ne 0 ]]; then
  echo "VALIDATE: ❌ config validation failed — review output above"
  exit 1
else
  echo "VALIDATE: ✅ all checks passed"
fi
