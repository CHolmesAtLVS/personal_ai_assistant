#!/usr/bin/env bash
# terraform-local.sh — Run Terraform locally using secrets from a .tfvars file.
#
# Usage:
#   ./scripts/terraform-local.sh <env> <command> [extra-terraform-args]
#
#   env:     dev | prod
#   command: plan | apply | destroy | output | validate | fmt
#
# Setup:
#   1. Copy scripts/dev.tfvars.example  -> scripts/dev.tfvars  and fill in values.
#   2. Copy scripts/prod.tfvars.example -> scripts/prod.tfvars and fill in values.
#   scripts/*.tfvars are git-ignored and must never be committed.
#
# Examples:
#   ./scripts/terraform-local.sh prod plan
#   ./scripts/terraform-local.sh prod apply
#   ./scripts/terraform-local.sh dev  plan -target=module.shared_resource_group

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

# ── Argument validation ────────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <env> <command> [extra-terraform-args]"
  echo "  env:     dev | prod"
  echo "  command: plan | apply | destroy | output | validate | fmt"
  exit 1
fi

ENV="${1}"
CMD="${2}"
shift 2
EXTRA_ARGS=("$@")

VARS_FILE="${SCRIPT_DIR}/${ENV}.tfvars"

if [[ ! -f "${VARS_FILE}" ]]; then
  echo "ERROR: secret vars file not found: ${VARS_FILE}"
  echo "Copy scripts/${ENV}.tfvars.example to scripts/${ENV}.tfvars and fill in values."
  exit 1
fi

# ── Load secrets from the vars file ───────────────────────────────────────────
# File format: KEY = "value"  or  KEY = value  (shell-style, no export keyword)
# Values are stripped of surrounding quotes before being exported.
while IFS='=' read -r key value; do
  # Skip blank lines and comments
  [[ -z "${key}" || "${key}" =~ ^[[:space:]]*# ]] && continue
  key="${key// /}"                    # strip spaces from key
  value="${value#"${value%%[![:space:]]*}"}"  # ltrim
  value="${value%"${value##*[![:space:]]}"}"  # rtrim
  value="${value#\"}"                 # strip leading quote
  value="${value%\"}"                 # strip trailing quote
  value="${value#\'}"                 # strip leading single quote
  value="${value%\'}"                 # strip trailing single quote
  export "${key}=${value}"
done < "${VARS_FILE}"

# Verify required Azure credentials were loaded
for required in AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID AZURE_CLIENT_ID AZURE_CLIENT_SECRET \
                TFSTATE_RG TFSTATE_LOCATION TFSTATE_STORAGE_ACCOUNT TFSTATE_CONTAINER TFSTATE_KEY; do
  if [[ -z "${!required:-}" ]]; then
    echo "ERROR: required variable '${required}' is not set in ${VARS_FILE}"
    exit 1
  fi
done

echo "LOCAL-TF: environment=${ENV} command=${CMD}"

# ── Azure login ────────────────────────────────────────────────────────────────
echo "LOCAL-TF: logging in to Azure..."
az login --service-principal \
  --username "${AZURE_CLIENT_ID}" \
  --password "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}" \
  --output none
az account set --subscription "${AZURE_SUBSCRIPTION_ID}"
echo "LOCAL-TF: Azure login successful"

# ── Bootstrap backend (idempotent) ────────────────────────────────────────────
echo "LOCAL-TF: bootstrapping Terraform backend..."
chmod +x "${SCRIPT_DIR}/bootstrap-tfstate.sh"
"${SCRIPT_DIR}/bootstrap-tfstate.sh"

# ── Terraform init ─────────────────────────────────────────────────────────────
echo "LOCAL-TF: running terraform init..."
terraform -chdir="${TF_DIR}" init \
  -backend-config="resource_group_name=${TFSTATE_RG}" \
  -backend-config="storage_account_name=${TFSTATE_STORAGE_ACCOUNT}" \
  -backend-config="container_name=${TFSTATE_CONTAINER}" \
  -backend-config="key=${TFSTATE_KEY}" \
  -reconfigure

# ── Run the requested Terraform command ───────────────────────────────────────
case "${CMD}" in
  fmt)
    terraform -chdir="${TF_DIR}" fmt -recursive "${EXTRA_ARGS[@]}"
    ;;
  validate)
    terraform -chdir="${TF_DIR}" validate "${EXTRA_ARGS[@]}"
    ;;
  plan)
    terraform -chdir="${TF_DIR}" plan -input=false -out="${TF_DIR}/tfplan" "${EXTRA_ARGS[@]}"
    ;;
  apply)
    if [[ -f "${TF_DIR}/tfplan" ]]; then
      echo "LOCAL-TF: applying saved plan ${TF_DIR}/tfplan"
      terraform -chdir="${TF_DIR}" apply -input=false "${TF_DIR}/tfplan" "${EXTRA_ARGS[@]}"
    else
      echo "LOCAL-TF: no saved plan found; running plan then apply"
      terraform -chdir="${TF_DIR}" plan  -input=false -out="${TF_DIR}/tfplan"
      terraform -chdir="${TF_DIR}" apply -input=false "${TF_DIR}/tfplan" "${EXTRA_ARGS[@]}"
    fi
    ;;
  destroy)
    echo "WARNING: this will destroy all ${ENV} resources. Press Ctrl-C within 10s to abort."
    sleep 10
    terraform -chdir="${TF_DIR}" destroy -input=false "${EXTRA_ARGS[@]}"
    ;;
  output)
    terraform -chdir="${TF_DIR}" output "${EXTRA_ARGS[@]}"
    ;;
  *)
    echo "ERROR: unknown command '${CMD}'. Valid: plan | apply | destroy | output | validate | fmt"
    exit 1
    ;;
esac
