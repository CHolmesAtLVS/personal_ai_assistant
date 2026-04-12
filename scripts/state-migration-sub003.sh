#!/usr/bin/env bash
# state-migration-sub003.sh — Terraform state migration for SUB-003 multi-instance conversion.
#
# Moves single-instance resource addresses to for_each-keyed addresses so
# Terraform can plan zero destroys for the existing 'ch' instance after the
# for_each refactor is applied.
#
# IMPORTANT: Run this script against the dev Terraform state FIRST.
# Never run against prod state without first verifying a clean plan in dev.
#
# Prerequisites:
#   - Terraform backend must be initialized (terraform init)
#   - Azure CLI authenticated with Storage Blob Data Contributor on the tfstate account
#   - Run from the terraform/ directory (or pass TERRAFORM_DIR)
#
# Usage:
#   INSTANCE=ch ENV=dev bash scripts/state-migration-sub003.sh [--dry-run]
#
# Options:
#   --dry-run   Print state mv commands without executing them.
#
# After the migration, run:
#   terraform plan         # must show 0 destroys for 'ch' resources
#   terraform apply        # creates new 'jh' (dev) or 'jh'+'kjm' (prod) resources
#
# SEC: targets dev by default; prod requires ALLOW_PROD=true.

set -euo pipefail

INSTANCE="${INSTANCE:-ch}"
ENV="${ENV:-dev}"
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${TERRAFORM_DIR:-${SCRIPT_DIR}/../terraform}"

for arg in "$@"; do
  if [[ "${arg}" == "--dry-run" ]]; then
    DRY_RUN=true
  fi
done

if [[ "${ENV}" == "prod" && "${ALLOW_PROD:-}" != "true" ]]; then
  echo "ERROR: Production state migration requires ALLOW_PROD=true to be set explicitly." >&2
  exit 1
fi

cd "${TERRAFORM_DIR}"

echo "State migration: single-instance → for_each[\"${INSTANCE}\"] (env=${ENV}, dry_run=${DRY_RUN})"
echo ""

run_state_mv() {
  local src="$1"
  local dst="$2"
  echo "  terraform state mv '${src}' '${dst}'"
  if [[ "${DRY_RUN}" == "false" ]]; then
    terraform state mv "${src}" "${dst}"
  fi
}

echo "Step 1: Backing up current state list..."
terraform state list > /tmp/state-before-migration-"${ENV}".txt
echo "  Written to /tmp/state-before-migration-${ENV}.txt"
echo ""

echo "Step 2: Migrating per-instance resources to for_each[\"${INSTANCE}\"]..."

# Managed Identity module
run_state_mv \
  "module.identity" \
  "module.identity[\"${INSTANCE}\"]"

# OIDC federated identity credential
run_state_mv \
  "azurerm_federated_identity_credential.openclaw" \
  "azurerm_federated_identity_credential.openclaw[\"${INSTANCE}\"]"

# Storage Account Contributor role assignment
run_state_mv \
  "azurerm_role_assignment.aks_files_contributor" \
  "azurerm_role_assignment.aks_files_contributor[\"${INSTANCE}\"]"

# NFS file share
run_state_mv \
  "azurerm_storage_share.openclaw_nfs" \
  "azurerm_storage_share.openclaw_nfs[\"${INSTANCE}\"]"

# Key Vault gateway token secret
run_state_mv \
  "azurerm_key_vault_secret.openclaw_gateway_token" \
  "azurerm_key_vault_secret.openclaw_gateway_token[\"${INSTANCE}\"]"

# random_id for gateway token
run_state_mv \
  "random_id.openclaw_gateway_token" \
  "random_id.openclaw_gateway_token[\"${INSTANCE}\"]"

# Role assignments — KV Secrets User
run_state_mv \
  "azurerm_role_assignment.mi_kv_secrets_user" \
  "azurerm_role_assignment.mi_kv_secrets_user[\"${INSTANCE}\"]"

# Role assignments — Cognitive Services OpenAI User
run_state_mv \
  "azurerm_role_assignment.mi_ai_openai_user" \
  "azurerm_role_assignment.mi_ai_openai_user[\"${INSTANCE}\"]"

# Role assignments — Cognitive Services User
run_state_mv \
  "azurerm_role_assignment.mi_ai_inference_user" \
  "azurerm_role_assignment.mi_ai_inference_user[\"${INSTANCE}\"]"

# AcrPull (prod only — the count=1 resource becomes for_each["ch"])
if [[ "${ENV}" == "prod" ]]; then
  run_state_mv \
    "azurerm_role_assignment.mi_acr_pull[0]" \
    "azurerm_role_assignment.mi_acr_pull[\"${INSTANCE}\"]"
fi

echo ""
echo "Step 3: Verifying post-migration state list..."
terraform state list > /tmp/state-after-migration-"${ENV}".txt
echo "  Written to /tmp/state-after-migration-${ENV}.txt"

echo ""
echo "Migration complete. Run 'terraform plan' to verify zero destroys for instance '${INSTANCE}'."
echo "Expected: only new (+) resources for additional instances."
