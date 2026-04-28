#!/usr/bin/env bash
# openclaw-connect.sh — Fetch the OpenClaw gateway URL + token from Key Vault
# and set up the local openclaw CLI to target the remote gateway.
#
# Each OpenClaw instance has its own DNS hostname and Key Vault token secret.
# FQDN pattern:
#   dev:  {inst}-paa-dev.acmeadventure.ca
#   prod: {inst}-paa.acmeadventure.ca
#
# Key Vault secret:  {inst}-openclaw-gateway-token
# Kubernetes:        namespace openclaw-{inst}, deployment openclaw
#
# Usage:
#   ./scripts/openclaw-connect.sh <inst> [env] [--export] [--install]
#
#   inst      instance slug, e.g. ch | jh | kjm (required)
#   env       dev | prod  (default: dev)
#   --export  Emit eval-able export lines for OPENCLAW_GATEWAY_URL and OPENCLAW_GATEWAY_TOKEN.
#             Source into current shell:
#               source <(./scripts/openclaw-connect.sh ch dev --export)
#   --install Install the openclaw CLI globally via npm if not already present.
#   --help    Show this help message and exit.
#
# Once OPENCLAW_GATEWAY_URL and OPENCLAW_GATEWAY_TOKEN are exported, all
# openclaw CLI commands target the remote gateway automatically:
#   openclaw devices list
#   openclaw devices approve <requestId>
#   openclaw status --all
#   openclaw channels status --probe
#
# Prerequisites:
#   - Logged in with `az login` and the correct subscription set.
#   - Key Vault Secrets User role on the target Key Vault.
#   - node / npm installed (for --install or local CLI use).

set -euo pipefail

ENV="dev"
INST=""
EXPORT_MODE=false
INSTALL_MODE=false

for arg in "$@"; do
  case "${arg}" in
    --help|-h)
      echo "Usage: ./scripts/openclaw-connect.sh <inst> [env] [--export] [--install]"
      echo ""
      echo "  inst      instance slug, e.g. ch | jh | kjm (required)"
      echo "  env       dev | prod  (default: dev)"
      echo "  --export  Emit eval-able export lines for OPENCLAW_GATEWAY_URL and OPENCLAW_GATEWAY_TOKEN."
      echo "            Source into current shell: source <(./scripts/openclaw-connect.sh ch dev --export)"
      echo "  --install Install the openclaw CLI globally via npm if not already present."
      echo "  --help    Show this help message and exit."
      echo ""
      echo "Prerequisites: az login, Key Vault Secrets User role on the target Key Vault."
      exit 0
      ;;
    --export)  EXPORT_MODE=true ;;
    --install) INSTALL_MODE=true ;;
    dev|prod)  ENV="${arg}" ;;
    *)
      # Accept 2-3 lowercase letters as the instance slug
      if [[ "${arg}" =~ ^[a-z]{2,3}$ ]]; then
        INST="${arg}"
      fi
      ;;
  esac
done

if [[ -z "${INST}" ]]; then
  echo "ERROR: instance slug is required (e.g. ch, jh, kjm)" >&2
  echo "Usage: ./scripts/openclaw-connect.sh <inst> [env] [--export] [--install]" >&2
  exit 1
fi

PROJECT="paa"

# ── Resolve Key Vault name from cached Terraform outputs ──────────────────────
OUTPUTS_FILE="$(dirname "${BASH_SOURCE[0]}")/${ENV}.tfoutputs"
KV_NAME_CONVENTION="${PROJECT}-${ENV}-kv"
if [[ -f "${OUTPUTS_FILE}" ]]; then
  KV_NAME=$(grep -E '^kv_name \(sensitive\) = ' "${OUTPUTS_FILE}" | awk '{print $NF}')
  KV_NAME="${KV_NAME:-${KV_NAME_CONVENTION}}"
else
  KV_NAME="${KV_NAME_CONVENTION}"
fi

# ── openclaw CLI detection + optional install ─────────────────────────────────
OPENCLAW_CMD=""
if command -v openclaw &>/dev/null; then
  OPENCLAW_CMD="openclaw"
elif command -v npx &>/dev/null; then
  OPENCLAW_CMD="npx openclaw"
fi

if [[ -z "${OPENCLAW_CMD}" ]] || [[ "${INSTALL_MODE}" == "true" ]]; then
  if [[ "${INSTALL_MODE}" == "true" ]] && command -v npm &>/dev/null; then
    echo "Installing openclaw CLI globally..."
    npm install -g openclaw
    OPENCLAW_CMD="openclaw"
  elif [[ -z "${OPENCLAW_CMD}" ]] && [[ "${EXPORT_MODE}" == "false" ]]; then
    echo "⚠  openclaw CLI not found. Install it with:"
    echo "     npm install -g openclaw"
    echo "   or re-run with --install:"
    echo "     ./scripts/openclaw-connect.sh ${INST} ${ENV} --install"
    echo ""
  fi
fi

# ── Retrieve token from Key Vault ─────────────────────────────────────────────
TOKEN=$(az keyvault secret show \
  --vault-name "${KV_NAME}" \
  --name "${INST}-openclaw-gateway-token" \
  --query "value" \
  -o tsv)

# ── Derive FQDN from instance + environment ───────────────────────────────────
case "${ENV}" in
  dev)  BASE_DOMAIN="paa-dev.acmeadventure.ca" ;;
  prod) BASE_DOMAIN="paa.acmeadventure.ca" ;;
esac
FQDN="${INST}-${BASE_DOMAIN}"
URL="https://${FQDN}"
NAMESPACE="openclaw-${INST}"

# ── Output ────────────────────────────────────────────────────────────────────
if [[ "${EXPORT_MODE}" == "true" ]]; then
  echo "export OPENCLAW_GATEWAY_URL=${URL}"
  echo "export OPENCLAW_GATEWAY_TOKEN=${TOKEN}"
else
  CLI_STATUS="${OPENCLAW_CMD:-not installed}"

  echo "Instance       : ${INST}"
  echo "Environment    : ${ENV}"
  echo "Key Vault      : ${KV_NAME}"
  echo "Namespace      : ${NAMESPACE}"
  echo "openclaw CLI   : ${CLI_STATUS}"
  echo ""
  echo "Control UI URL : ${URL}"
  echo "Gateway token  : ${TOKEN}"
  echo ""
  echo "── Connect local CLI to remote gateway ──────────────────────────"
  echo ""
  echo "Once per shell session (source into current shell):"
  echo "  source <(./scripts/openclaw-connect.sh ${INST} ${ENV} --export)"
  echo ""
  echo "To avoid typing this every time, add to ~/.bashrc or ~/.zshrc:"
  echo "  alias ocl-${INST}-${ENV}='source <($(pwd)/scripts/openclaw-connect.sh ${INST} ${ENV} --export)'"
  echo ""
  echo "Then use openclaw CLI directly:"
  echo "  openclaw devices list"
  echo "  openclaw devices approve <requestId>"
  echo "  openclaw status --all"
  echo "  openclaw channels status --probe"
  echo ""
  if [[ -z "${OPENCLAW_CMD}" ]]; then
    echo "── Install openclaw CLI ─────────────────────────────────────────"
    echo "  ./scripts/openclaw-connect.sh ${INST} ${ENV} --install"
    echo ""
  fi
  echo "── Container exec fallback (no local CLI needed) ────────────────"
  echo "  kubectl exec -n ${NAMESPACE} deployment/openclaw -- \\"
  echo "    node /app/openclaw.mjs devices list"
fi
