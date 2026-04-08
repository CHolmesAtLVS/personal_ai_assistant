#!/usr/bin/env bash
# seed-openclaw-aks.sh — Apply OpenClaw CRDs to AKS via envsubst before ArgoCD sync.
#
# Applies all YAML files in workloads/<env>/openclaw/crds/ after substituting
# ${VAR} placeholders using environment variables. Must be run before applying the
# ArgoCD Application (TASK-020) so the SecretProviderClass and PV/PVC exist before
# the first pod start.
#
# Usage:
#   ./scripts/seed-openclaw-aks.sh [dev|prod]
#
# Required env vars (set from GitHub Secrets + Terraform outputs in CI):
#   OPENCLAW_MI_CLIENT_ID    — Managed Identity client ID (terraform output openclaw_mi_client_id)
#   KEY_VAULT_NAME           — Key Vault name (terraform output kv_name)
#   AZURE_TENANT_ID          — Azure tenant ID (GitHub Secret)
#   AZURE_OPENAI_ENDPOINT    — Azure AI Services endpoint URL (terraform output azure_openai_endpoint)
#   NFS_STORAGE_ACCOUNT_NAME — NFS premium storage account name (terraform output openclaw_nfs_storage_account_name)
#   AKS_NODE_RESOURCE_GROUP  — AKS node resource group (terraform output aks_node_resource_group)
#
# SEC-001: Targets dev by default. Pass 'prod' explicitly and set ALLOW_PROD=true.
# Never commit files with real substituted values.

set -euo pipefail

ENV="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ "${ENV}" != "dev" && "${ENV}" != "prod" ]]; then
  echo "ERROR: env must be 'dev' or 'prod'" >&2
  exit 1
fi

# Safety guard — require explicit opt-in for production
if [[ "${ENV}" == "prod" ]]; then
  if [[ "${ALLOW_PROD:-}" != "true" ]]; then
    echo "ERROR: Production deploy requires ALLOW_PROD=true to be set explicitly." >&2
    exit 1
  fi
fi

: "${OPENCLAW_MI_CLIENT_ID:?OPENCLAW_MI_CLIENT_ID must be set}"
: "${KEY_VAULT_NAME:?KEY_VAULT_NAME must be set}"
: "${AZURE_TENANT_ID:?AZURE_TENANT_ID must be set}"
: "${AZURE_OPENAI_ENDPOINT:?AZURE_OPENAI_ENDPOINT must be set}"
: "${NFS_STORAGE_ACCOUNT_NAME:?NFS_STORAGE_ACCOUNT_NAME must be set}"
: "${AKS_NODE_RESOURCE_GROUP:?AKS_NODE_RESOURCE_GROUP must be set}"

CRD_DIR="${REPO_ROOT}/workloads/${ENV}/openclaw/crds"

if [[ ! -d "${CRD_DIR}" ]]; then
  echo "ERROR: CRD directory not found: ${CRD_DIR}" >&2
  exit 1
fi

YAML_FILES=("${CRD_DIR}"/*.yaml)
if [[ ! -e "${YAML_FILES[0]}" ]]; then
  echo "No YAML files found in ${CRD_DIR}. Nothing to apply." >&2
  exit 0
fi

echo "Applying OpenClaw CRDs for environment: ${ENV}"
for f in "${YAML_FILES[@]}"; do
  echo "  Applying: $(basename "${f}")"
  envsubst < "${f}" | kubectl apply -f -
done

echo "Done. CRDs applied to AKS for environment: ${ENV}."

# TASK-020: Apply ArgoCD Application manifest for the target environment.
# This must run after CRDs are applied so the SecretProviderClass and PV/PVC
# exist before the first pod start triggered by ArgoCD sync.
ARGOCD_APP="${REPO_ROOT}/argocd/apps/${ENV}-openclaw.yaml"
if [[ ! -f "${ARGOCD_APP}" ]]; then
  echo "ERROR: ArgoCD Application manifest not found: ${ARGOCD_APP}" >&2
  exit 1
fi

echo "Applying ArgoCD Application for environment: ${ENV}"
kubectl apply -f "${ARGOCD_APP}"

echo "Waiting for ArgoCD Application openclaw-${ENV} to sync (timeout 300s)..."
argocd app wait "openclaw-${ENV}" --sync --timeout 300

echo "ArgoCD Application openclaw-${ENV} is synced."
