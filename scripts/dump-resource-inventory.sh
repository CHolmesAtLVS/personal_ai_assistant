#!/usr/bin/env bash
# dump-resource-inventory.sh — Query Azure Resource Graph for all resources tagged
# as part of this project and write a CSV inventory to scripts/resource-inventory.csv.
#
# Usage:
#   ./scripts/dump-resource-inventory.sh
#
# Output (git-ignored):
#   scripts/resource-inventory.csv
#
# Prerequisites:
#   - Azure CLI logged in with an account that has Reader access to the subscription(s).
#   - jq installed (available in the dev container).
#
# The query returns all resources where the managed_by tag equals
# "CHolmesAtLVS\personal_ai_assistant".  Output columns include resource identity,
# type, location, environment tag, and the full tag bag for reference.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_FILE="${SCRIPT_DIR}/resource-inventory.csv"

MANAGED_BY_VALUE='CHolmesAtLVS\personal_ai_assistant'

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if ! command -v az &>/dev/null; then
  echo "ERROR: Azure CLI (az) not found. Install it and log in before running this script."
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not found. Install jq before running this script."
  exit 1
fi

# Ensure the resource-graph extension is present (safe to run even if already installed).
az extension add --name resource-graph --only-show-errors 2>/dev/null || true

# Verify we have an active login.
if ! az account show &>/dev/null; then
  echo "ERROR: No active Azure login. Run 'az login' first."
  exit 1
fi

# ── Resource Graph query ───────────────────────────────────────────────────────
# KQL notes:
#   - =~  performs a case-insensitive string comparison.
#   - KQL string literals treat \ as an escape character, so a literal backslash
#     in the tag value must be doubled (\\) before embedding it in the KQL string.
#   - Results are capped at 1000 per page; --first 1000 fetches up to the max in one call.
#     For larger environments add pagination logic.

# Escape backslashes for KQL (\ → \\ so KQL interprets it as a literal backslash)
KQL_MANAGED_BY_VALUE="${MANAGED_BY_VALUE//\\/\\\\}"

KQL="Resources
| where tags['managed_by'] =~ '${KQL_MANAGED_BY_VALUE}'
| project
    name,
    type,
    resourceGroup,
    location,
    subscriptionId,
    managed_by     = tostring(tags['managed_by']),
    environment    = tostring(tags['environment']),
    project_tag    = tostring(tags['project']),
    tags_json      = tostring(tags)
| order by type asc, name asc"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "RESOURCE INVENTORY — managed_by=${MANAGED_BY_VALUE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Querying Azure Resource Graph…"

RAW_JSON="$(az graph query \
  --graph-query "${KQL}" \
  --first 1000 \
  --output json)"

TOTAL="$(echo "${RAW_JSON}" | jq '.count')"
echo "Resources found: ${TOTAL}"

if [[ "${TOTAL}" -eq 0 ]]; then
  echo "No resources matched.  Verify the managed_by tag value and your account permissions."
  exit 0
fi

# ── Write CSV ─────────────────────────────────────────────────────────────────
echo "${RAW_JSON}" | jq -r '
  ["name","type","resourceGroup","location","subscriptionId","managed_by","environment","project_tag","tags_json"],
  (.data[] | [.name, .type, .resourceGroup, .location, .subscriptionId,
              .managed_by, .environment, .project_tag, .tags_json])
  | @csv' > "${OUT_FILE}"

echo "CSV written to: ${OUT_FILE}"
echo ""
echo "NOTE: The CSV may contain Azure identifiers (subscription IDs, resource names)."
echo "      This file is git-ignored.  Do not share or commit it."
