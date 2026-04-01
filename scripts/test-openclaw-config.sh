#!/usr/bin/env bash
# test-openclaw-config.sh — Validate OpenClaw gateway config via az containerapp exec.
#
# Runs openclaw commands directly inside the container using
# `az containerapp exec --command "node /app/openclaw.mjs ..."`, the same
# pattern used by seed-openclaw-config.sh for its verify step.
#
# Note: az containerapp exec calls termios.tcgetattr() to set up a TTY, which
# raises ENOTTY (errno 25) in CI when the command interpreter is `bash`. Running
# `node /app/openclaw.mjs` directly avoids this — node does not trigger TTY
# detection. No file upload is required.
#
# Usage:
#   bash scripts/test-openclaw-config.sh [dev|prod]
#
# Prerequisites:
#   - az login with access to the environment resource group
#   - Container App is running (revision active)
#
# Constraints:
#   - az containerapp exec is rate-limited (~5 sessions per 10 min; HTTP 429 = wait 10 min)
#   - This script uses 2 exec sessions (config validate, doctor).
#   - SEC-001: targets dev only unless explicitly confirmed.

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
