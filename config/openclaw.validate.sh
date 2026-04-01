#!/usr/bin/env bash
# openclaw.validate.sh — OpenClaw config validation script.
#
# Uploaded to the Azure Files share and executed inside the container by
# test-openclaw-config.sh via az containerapp exec.
#
# Uses `node /app/openclaw.mjs` (the in-container openclaw binary) directly.
# Do not edit paths — they are container-internal.

set -uo pipefail

PASS=0; FAIL=0; WARN=0
pass() { echo "  PASS  $*"; (( PASS++ )) || true; }
fail() { echo "  FAIL  $*"; (( FAIL++ )) || true; }
warn() { echo "  WARN  $*"; (( WARN++ )) || true; }
section() { echo ""; echo "── $* ────────────────────────────────────────────────"; }

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " OpenClaw config validation  started=${TIMESTAMP}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

OC="node /app/openclaw.mjs"

# ── Config validate ────────────────────────────────────────────────────────────
section "Config validate"
VALIDATE_OUT=$(${OC} config validate 2>&1 || echo "OC_VALIDATE_FAILED")
echo "${VALIDATE_OUT}"
if echo "${VALIDATE_OUT}" | grep -q "OC_VALIDATE_FAILED\|error\|invalid\|Error\|Invalid"; then
  fail "openclaw config validate"
else
  pass "openclaw config validate"
fi

# ── Status summary ─────────────────────────────────────────────────────────────
section "Gateway status"
STATUS_OUT=$(${OC} status 2>&1 || echo "OC_STATUS_FAILED")
echo "${STATUS_OUT}"
if echo "${STATUS_OUT}" | grep -q "OC_STATUS_FAILED"; then
  warn "openclaw status returned non-zero"
else
  pass "openclaw status"
fi

# ── Doctor ─────────────────────────────────────────────────────────────────────
section "Doctor"
DOCTOR_OUT=$(${OC} doctor --non-interactive 2>&1 || echo "OC_DOCTOR_FAILED")
echo "${DOCTOR_OUT}"
if echo "${DOCTOR_OUT}" | grep -q "OC_DOCTOR_FAILED"; then
  warn "openclaw doctor returned non-zero"
elif echo "${DOCTOR_OUT}" | grep -qi "error\|critical\|failed"; then
  fail "openclaw doctor detected issues"
else
  pass "openclaw doctor --non-interactive"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Results: PASS=${PASS}  FAIL=${FAIL}  WARN=${WARN}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ "${FAIL}" -eq 0 ]]
