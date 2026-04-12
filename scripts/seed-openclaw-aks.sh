#!/usr/bin/env bash
# seed-openclaw-aks.sh — Seed one OpenClaw instance on AKS before ArgoCD sync.
#
# Applies shared templates from workloads/templates/ via envsubst, substituting
# instance-specific variables. Must run before ArgoCD syncs so that the
# SecretProviderClass, ServiceAccount, ConfigMap, HTTPRoute, Certificate, and
# PersistentVolume exist before the first pod start.
#
# Usage:
#   ./scripts/seed-openclaw-aks.sh <dev|prod> <inst>
#
# Example (all dev instances, from CI):
#   MI_IDS=$(terraform output -json instance_mi_client_ids)
#   for inst in ch jh; do
#     export OPENCLAW_MI_CLIENT_ID
#     OPENCLAW_MI_CLIENT_ID=$(echo "${MI_IDS}" | jq -r ".${inst}")
#     ./scripts/seed-openclaw-aks.sh dev "${inst}"
#   done
#
# Required env vars:
#   OPENCLAW_MI_CLIENT_ID    — instance Managed Identity client ID (Terraform output)
#   KEY_VAULT_NAME           — Key Vault name (Terraform output)
#   AZURE_TENANT_ID          — Azure tenant ID (GitHub Secret)
#   AZURE_OPENAI_ENDPOINT    — Azure AI Services endpoint URL (Terraform output)
#
# Optional env vars:
#   CERT_ISSUER  — cert-manager ClusterIssuer name (default: letsencrypt-staging)
#   ALLOW_PROD   — must be "true" to allow prod operations (safety guard)
#
# SEC-001: Never commit files with real substituted values.

set -euo pipefail

ENV="${1:?ENV is required — pass 'dev' or 'prod' as first argument}"
INST="${2:?INST is required — pass instance name as second argument (e.g. ch, jh, kjm)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ "${ENV}" != "dev" && "${ENV}" != "prod" ]]; then
  echo "ERROR: env must be 'dev' or 'prod'" >&2
  exit 1
fi

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

# Compute instance-specific variables
case "${ENV}" in
  dev)  BASE_DOMAIN="paa-dev.acmeadventure.ca" ;;
  prod) BASE_DOMAIN="paa.acmeadventure.ca" ;;
esac

export INST
export ENV
export INST_FQDN="${INST}.${BASE_DOMAIN}"
export CERT_SECRET_NAME="${INST}-${ENV}-tls"
export CERT_ISSUER="${CERT_ISSUER:-letsencrypt-staging}"

BOOTSTRAP_TMPL="${REPO_ROOT}/workloads/templates/bootstrap"
NAMESPACE="openclaw-${INST}"

echo "Seeding instance '${INST}' in environment '${ENV}' (namespace: ${NAMESPACE})"

echo "Ensuring namespace '${NAMESPACE}' exists..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "Applying bootstrap templates..."
for f in "${BOOTSTRAP_TMPL}"/*.yaml; do
  echo "  Applying: $(basename "${f}")"
  envsubst < "${f}" | kubectl apply -f -
done

ARGOCD_APP="${REPO_ROOT}/argocd/apps/${ENV}-openclaw-${INST}.yaml"
if [[ ! -f "${ARGOCD_APP}" ]]; then
  echo "ERROR: ArgoCD Application manifest not found: ${ARGOCD_APP}" >&2
  exit 1
fi

echo "Applying ArgoCD Application: ${INST}-openclaw-${ENV}..."
kubectl apply -f "${ARGOCD_APP}"

echo "Waiting for ArgoCD Application to sync (timeout 300s)..."
argocd app wait "${INST}-openclaw-${ENV}" --sync --timeout 300

echo "Done. Instance '${INST}' seeded successfully."
