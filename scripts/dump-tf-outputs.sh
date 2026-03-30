#!/usr/bin/env bash
# dump-tf-outputs.sh — Dump Terraform outputs to local files for troubleshooting.
#
# Usage:
#   ./scripts/dump-tf-outputs.sh [env]
#
#   env: dev | prod | both  (default: both)
#
# Output files (git-ignored, never commit):
#   scripts/dev.tfoutputs   — JSON  + human-readable text for dev
#   scripts/prod.tfoutputs  — JSON  + human-readable text for prod
#
# Sensitive values are written in plain text — treat the output files as secrets.
#
# Prerequisites:
#   scripts/dev.tfvars and/or scripts/prod.tfvars must exist and be populated.
#   See scripts/dev.tfvars.example for the expected format.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

ENV="${1:-both}"

if [[ "${ENV}" != "dev" && "${ENV}" != "prod" && "${ENV}" != "both" ]]; then
  echo "Usage: $0 [dev|prod|both]"
  exit 1
fi

# ── Dump outputs for one environment ──────────────────────────────────────────
dump_env() {
  local env="${1}"
  local vars_file="${SCRIPT_DIR}/${env}.tfvars"
  local out_file="${SCRIPT_DIR}/${env}.tfoutputs"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "DUMP-OUTPUTS: environment=${env}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [[ ! -f "${vars_file}" ]]; then
    echo "SKIP: vars file not found: ${vars_file}"
    echo "      Copy scripts/${env}.tfvars.example to scripts/${env}.tfvars and fill in values."
    return 0
  fi

  # ── Load secrets from vars file ─────────────────────────────────────────────
  # Format: KEY = "value"  (same as terraform-local.sh)
  while IFS='=' read -r key value; do
    [[ -z "${key}" || "${key}" =~ ^[[:space:]]*# ]] && continue
    key="${key// /}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    export "${key}=${value}"
  done < "${vars_file}"

  for required in TFSTATE_RG TFSTATE_STORAGE_ACCOUNT TFSTATE_CONTAINER TFSTATE_KEY; do
    if [[ -z "${!required:-}" ]]; then
      echo "ERROR: required variable '${required}' is not set in ${vars_file}"
      return 1
    fi
  done

  # ── Azure auth ───────────────────────────────────────────────────────────────
  if [[ -n "${AZURE_CLIENT_SECRET:-}" ]]; then
    for required in AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_CLIENT_ID; do
      if [[ -z "${!required:-}" ]]; then
        echo "ERROR: AZURE_CLIENT_SECRET is set but '${required}' is missing in ${vars_file}"
        return 1
      fi
    done
    echo "DUMP-OUTPUTS: authenticating as Service Principal..."
    az login --service-principal \
      --username "${AZURE_CLIENT_ID}" \
      --password "${AZURE_CLIENT_SECRET}" \
      --tenant "${AZURE_TENANT_ID}" \
      --output none
  else
    echo "DUMP-OUTPUTS: AZURE_CLIENT_SECRET not set — using existing Azure CLI session"
    if ! az account show --output none 2>/dev/null; then
      echo "ERROR: no active Azure CLI session. Run 'az login' first or add SP credentials to ${vars_file}"
      return 1
    fi
  fi

  if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
    az account set --subscription "${AZURE_SUBSCRIPTION_ID}"
  fi
  echo "DUMP-OUTPUTS: Azure auth OK (subscription: $(az account show --query id -o tsv))"

  # ── Bootstrap backend ────────────────────────────────────────────────────────
  echo "DUMP-OUTPUTS: bootstrapping Terraform backend..."
  chmod +x "${SCRIPT_DIR}/bootstrap-tfstate.sh"
  "${SCRIPT_DIR}/bootstrap-tfstate.sh"

  # ── Terraform init ───────────────────────────────────────────────────────────
  echo "DUMP-OUTPUTS: running terraform init..."
  terraform -chdir="${TF_DIR}" init \
    -backend-config="resource_group_name=${TFSTATE_RG}" \
    -backend-config="storage_account_name=${TFSTATE_STORAGE_ACCOUNT}" \
    -backend-config="container_name=${TFSTATE_CONTAINER}" \
    -backend-config="key=${TFSTATE_KEY}" \
    -reconfigure \
    -input=false

  # ── Capture outputs ──────────────────────────────────────────────────────────
  echo "DUMP-OUTPUTS: collecting terraform outputs..."

  # JSON: includes all values (sensitive included) in machine-readable form
  local json_output
  json_output="$(terraform -chdir="${TF_DIR}" output -json)"

  # Human-readable: terraform output without -json still redacts sensitive values,
  # so we derive plain-text lines from the JSON instead.
  local text_output
  text_output="$(echo "${json_output}" | \
    python3 -c "
import json, sys
data = json.load(sys.stdin)
lines = []
for k, v in sorted(data.items()):
    val = v.get('value')
    sensitive = v.get('sensitive', False)
    tag = ' (sensitive)' if sensitive else ''
    if val is None:
        lines.append(f'{k}{tag} = null')
    elif isinstance(val, str):
        lines.append(f'{k}{tag} = {val}')
    else:
        lines.append(f'{k}{tag} = {json.dumps(val)}')
print('\n'.join(lines))
")"

  # ── Write output file ────────────────────────────────────────────────────────
  {
    echo "# Terraform outputs — ${env}"
    echo "# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "# WARNING: this file contains sensitive values in plain text."
    echo "# It is git-ignored and must never be committed."
    echo ""
    echo "## Human-readable"
    echo ""
    echo "${text_output}"
    echo ""
    echo "## JSON (full)"
    echo ""
    echo "${json_output}"
  } > "${out_file}"

  echo "DUMP-OUTPUTS: outputs written to ${out_file}"
}

# ── Main ───────────────────────────────────────────────────────────────────────
if [[ "${ENV}" == "both" ]]; then
  dump_env dev
  dump_env prod
else
  dump_env "${ENV}"
fi

echo ""
echo "Done. Output files are git-ignored — treat them as secrets."
