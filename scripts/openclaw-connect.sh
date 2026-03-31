#!/usr/bin/env bash
# openclaw-connect.sh — Fetch the OpenClaw gateway URL + token from Key Vault
# and set up the local openclaw CLI to target the remote Azure Container App.
#
# Usage:
#   ./scripts/openclaw-connect.sh [env] [--export] [--install]
#
#   env       dev | prod  (default: dev)
#   --export  Emit eval-able export lines for use in a shell alias or CI.
#             To avoid typing eval every time, add this to ~/.bashrc or ~/.zshrc:
#               alias openclaw-dev='eval "$(~/path/to/openclaw-connect.sh dev --export)" && openclaw'
#             Or source the script once per session:
#               source <(./scripts/openclaw-connect.sh dev --export)
#   --install Install the openclaw CLI globally via npm if not already present.
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
EXPORT_MODE=false
INSTALL_MODE=false

for arg in "$@"; do
  case "${arg}" in
    --export)  EXPORT_MODE=true ;;
    --install) INSTALL_MODE=true ;;
    dev|prod)  ENV="${arg}" ;;
  esac
done

PROJECT="paa"
KV_NAME="${PROJECT}-${ENV}-kv"

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
    echo "     ./scripts/openclaw-connect.sh ${ENV} --install"
    echo ""
  fi
fi

# ── Retrieve token from Key Vault ─────────────────────────────────────────────
TOKEN=$(az keyvault secret show \
  --vault-name "${KV_NAME}" \
  --name "openclaw-gateway-token" \
  --query "value" \
  -o tsv)

# ── Derive FQDN: Terraform outputs → az containerapp show ────────────────────
TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
VARS_FILE="$(dirname "${BASH_SOURCE[0]}")/${ENV}.tfvars"

FQDN=""
if [[ -f "${VARS_FILE}" ]]; then
  FQDN=$(terraform -chdir="${TF_DIR}" \
    output -raw container_app_fqdn 2>/dev/null || true)
fi

if [[ -z "${FQDN}" ]]; then
  FQDN=$(az containerapp show \
    --name "${PROJECT}-${ENV}-app" \
    --resource-group "${PROJECT}-${ENV}-rg" \
    --query "properties.configuration.ingress.fqdn" \
    -o tsv 2>/dev/null || true)
fi

FQDN="${FQDN#https://}"
FQDN="${FQDN#http://}"
URL="https://${FQDN}"

# ── Output ────────────────────────────────────────────────────────────────────
if [[ "${EXPORT_MODE}" == "true" ]]; then
  echo "export OPENCLAW_GATEWAY_URL=${URL}"
  echo "export OPENCLAW_GATEWAY_TOKEN=${TOKEN}"
else
  CLI_STATUS="${OPENCLAW_CMD:-not installed}"

  echo "Environment    : ${ENV}"
  echo "Key Vault      : ${KV_NAME}"
  echo "openclaw CLI   : ${CLI_STATUS}"
  echo ""
  echo "Control UI URL : ${URL}"
  echo "Gateway token  : ${TOKEN}"
  echo ""
  echo "── Connect local CLI to remote gateway ──────────────────────────"
  echo ""
  echo "Once per shell session (source into current shell):"
  echo "  source <(./scripts/openclaw-connect.sh ${ENV} --export)"
  echo ""
  echo "To avoid typing this every time, add to ~/.bashrc or ~/.zshrc:"
  echo "  alias ocl-${ENV}='source <($(pwd)/scripts/openclaw-connect.sh ${ENV} --export)'"
  echo ""
  echo "Then use openclaw CLI directly:"
  echo "  openclaw devices list"
  echo "  openclaw devices approve <requestId>"
  echo "  openclaw status --all"
  echo "  openclaw channels status --probe"
  echo ""
  if [[ -z "${OPENCLAW_CMD}" ]]; then
    echo "── Install openclaw CLI ─────────────────────────────────────────"
    echo "  ./scripts/openclaw-connect.sh ${ENV} --install"
    echo ""
  fi
  echo "── Container exec fallback (no local CLI needed) ────────────────"
  echo "  az containerapp exec --name ${PROJECT}-${ENV}-app \\"
  echo "    --resource-group ${PROJECT}-${ENV}-rg \\"
  echo "    --command 'node /app/openclaw.mjs devices list'"
fi
