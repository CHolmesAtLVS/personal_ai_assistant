#!/usr/bin/env bash
set -euo pipefail

required_vars=(
  TFSTATE_RG
  TFSTATE_LOCATION
  TFSTATE_STORAGE_ACCOUNT
  TFSTATE_CONTAINER
  AZURE_SUBSCRIPTION_ID
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "BOOTSTRAP-STATE:ERROR missing required environment variable: ${var_name}"
    exit 1
  fi
done

az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

if [[ "$(az group exists --name "${TFSTATE_RG}" -o tsv)" == "true" ]]; then
  echo "BOOTSTRAP-STATE:RG_EXISTS ${TFSTATE_RG}"
else
  az group create \
    --name "${TFSTATE_RG}" \
    --location "${TFSTATE_LOCATION}" \
    --output none
  echo "BOOTSTRAP-STATE:RG_CREATED ${TFSTATE_RG}"
fi

if az storage account show --name "${TFSTATE_STORAGE_ACCOUNT}" --resource-group "${TFSTATE_RG}" --output none 2>/dev/null; then
  echo "BOOTSTRAP-STATE:SA_EXISTS ${TFSTATE_STORAGE_ACCOUNT}"
else
  az storage account create \
    --name "${TFSTATE_STORAGE_ACCOUNT}" \
    --resource-group "${TFSTATE_RG}" \
    --location "${TFSTATE_LOCATION}" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --https-only true \
    --allow-blob-public-access false \
    --min-tls-version TLS1_2 \
    --output none
  echo "BOOTSTRAP-STATE:SA_CREATED ${TFSTATE_STORAGE_ACCOUNT}"
fi

az storage account blob-service-properties update \
  --account-name "${TFSTATE_STORAGE_ACCOUNT}" \
  --resource-group "${TFSTATE_RG}" \
  --enable-versioning true \
  --output none
echo "BOOTSTRAP-STATE:VERSIONING_ENABLED ${TFSTATE_STORAGE_ACCOUNT}"

if az storage container show \
  --name "${TFSTATE_CONTAINER}" \
  --account-name "${TFSTATE_STORAGE_ACCOUNT}" \
  --auth-mode login \
  --output none 2>/dev/null; then
  echo "BOOTSTRAP-STATE:CONTAINER_EXISTS ${TFSTATE_CONTAINER}"
else
  az storage container create \
    --name "${TFSTATE_CONTAINER}" \
    --account-name "${TFSTATE_STORAGE_ACCOUNT}" \
    --auth-mode login \
    --output none
  echo "BOOTSTRAP-STATE:CONTAINER_CREATED ${TFSTATE_CONTAINER}"
fi

# Grant the CI service principal Storage Blob Data Reader on the tfstate storage
# account so it can download central tfvars with --auth-mode login.
# Skipped when AZURE_CLIENT_ID is unset (local dev runs without a service principal).
if [[ -n "${AZURE_CLIENT_ID:-}" ]]; then
  SA_RESOURCE_ID="$(az storage account show \
    --name "${TFSTATE_STORAGE_ACCOUNT}" \
    --resource-group "${TFSTATE_RG}" \
    --query id -o tsv)"
  SP_OBJECT_ID="$(az ad sp show --id "${AZURE_CLIENT_ID}" --query id -o tsv)"
  if az role assignment list \
    --assignee "${SP_OBJECT_ID}" \
    --role "Storage Blob Data Reader" \
    --scope "${SA_RESOURCE_ID}" \
    --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
    echo "BOOTSTRAP-STATE:SP_ROLE_EXISTS Storage Blob Data Reader on ${TFSTATE_STORAGE_ACCOUNT}"
  else
    az role assignment create \
      --assignee "${SP_OBJECT_ID}" \
      --role "Storage Blob Data Reader" \
      --scope "${SA_RESOURCE_ID}" \
      --output none
    echo "BOOTSTRAP-STATE:SP_ROLE_CREATED Storage Blob Data Reader on ${TFSTATE_STORAGE_ACCOUNT}"
  fi
fi

echo "BOOTSTRAP-STATE:DONE"
