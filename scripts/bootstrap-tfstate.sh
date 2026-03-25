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

echo "BOOTSTRAP-STATE:DONE"
