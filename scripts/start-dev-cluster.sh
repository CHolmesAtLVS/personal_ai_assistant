#!/usr/bin/env bash
# start-dev-cluster.sh — Start paa-dev-aks if it is not already Running.
# Safe to run locally or from CI. Exits 0 immediately if already Running.
# Waits up to 10 minutes for the cluster to reach Running state.
#
# Prerequisites: az login (or managed identity in CI), correct subscription set.
# Usage: ./scripts/start-dev-cluster.sh

set -euo pipefail

RG="paa-dev-rg"
CLUSTER="paa-dev-aks"
TIMEOUT=600   # 10 minutes
INTERVAL=30

echo "Checking power state of ${CLUSTER}..."
POWER=$(az aks show --resource-group "${RG}" --name "${CLUSTER}" --query powerState.code -o tsv)

if [[ "${POWER}" == "Running" ]]; then
  echo "${CLUSTER} is already Running — no action needed."
  exit 0
fi

echo "${CLUSTER} is ${POWER} — starting..."
az aks start --resource-group "${RG}" --name "${CLUSTER}" --no-wait

ELAPSED=0
while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
  STATE=$(az aks show --resource-group "${RG}" --name "${CLUSTER}" --query powerState.code -o tsv)
  if [[ "${STATE}" == "Running" ]]; then
    echo "${CLUSTER} is Running (waited ${ELAPSED}s)."
    exit 0
  fi
  echo "  State: ${STATE} — waiting ${INTERVAL}s (${ELAPSED}/${TIMEOUT}s elapsed)..."
  sleep ${INTERVAL}
  ELAPSED=$(( ELAPSED + INTERVAL ))
done

echo "ERROR: ${CLUSTER} did not reach Running state within ${TIMEOUT}s." >&2
exit 1
