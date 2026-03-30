---
name: openclaw-troubleshoot
description: "Troubleshoot OpenClaw Container App startup failures and runtime errors using Azure CLI and diagnostics tools. WHEN: \"troubleshoot openclaw\", \"diagnose container app\", \"container app crashing\", \"container won't start\", \"startup failure\", \"openclaw not running\", \"debug containerapp\", \"what's wrong with openclaw\"."
license: MIT
metadata:
  author: Platform Engineering
  version: "1.1.0"
  domain: operations
  scope: diagnosis
---

# OpenClaw Troubleshoot

Diagnose OpenClaw Container App failures using the `diagnose-containerapp.sh` script and Azure CLI diagnostics. Works around the Log Analytics NSP block by using direct Container App CLI methods.

## Safety Rule

**Always target dev only.** Never supply production resource names or execute commands against prod during a troubleshooting session. If the target environment is ambiguous, ask explicitly before running any command.

## Quick Start

Run the diagnostic script — it captures a full snapshot (sections A–H) and derives all resource names from the `env` argument with no Terraform state or `.tfvars` files required:

```bash
bash scripts/diagnose-containerapp.sh dev
# Output written to: scripts/diag-dev-<timestamp>.txt  (git-ignored)
```

The script always exits 0. Treat its output file as a report. Review sections A and B first for the failure reason, then D for infrastructure events.

## Resource Naming

Resource names follow the `paa-<env>-*` pattern derived from Terraform locals. For `dev`:

| Resource | Name |
|---|---|
| Container App | `paa-dev-app` |
| Resource Group | `paa-dev-rg` |
| Storage Account | `paadevocstate` |
| Key Vault | `paa-dev-kv` |
| Managed Identity | `paa-dev-id` |
| Azure Files Share | `openclaw-state` |

If you need to discover names from tags:

```bash
bash scripts/dump-resource-inventory.sh
grep ",dev," scripts/resource-inventory.csv | awk -F',' '{print $1, $2, $3}'
```

## Step-by-Step Diagnostic Procedure

The `diagnose-containerapp.sh` script runs all sections automatically. Use these manual commands when you need to re-run a specific section or when the script output needs clarification. Substitute `paa-dev-app` and `paa-dev-rg` with the appropriate environment names.

### A — Revision list (first stop for any startup failure)

```bash
az containerapp revision list \
  --name paa-dev-app \
  --resource-group paa-dev-rg \
  -o table
```

Look for: `runningState`, `healthState`, replica count (0 = crashed), traffic weight.

### B — Active revision detail

```bash
az containerapp revision show \
  --name paa-dev-app \
  --resource-group paa-dev-rg \
  --revision <revision-name> \
  --query "properties.{runningState:runningState, healthState:healthState, details:runningStateDetails}" \
  -o json
```

`runningStateDetails` contains the human-readable failure reason (e.g. `"1/1 Container crashing: openclaw"`).

### C — Container console logs

```bash
# Get replica name first
az containerapp replica list \
  --name paa-dev-app \
  --resource-group paa-dev-rg \
  --revision <revision-name> \
  -o table

# Then pull stdout/stderr
az containerapp logs show \
  --name paa-dev-app \
  --resource-group paa-dev-rg \
  --revision <revision-name> \
  --replica <replica-name> \
  --tail 100 --follow false
```

If `replica list` returns empty, replicas=0 (container crashed before replicas formed). Skip to section D.

### D — System event stream (surfaced `PortMismatch` in the 2026-03-30 incident)

```bash
az containerapp logs show \
  --name paa-dev-app \
  --resource-group paa-dev-rg \
  --type system \
  --tail 50 --follow false
```

Sample `PortMismatch` event pattern:
```
{"reason":"PortMismatch","message":"Container port 18789 does not match ingress port 80"}
```

### E — Container exit events (diagnostics API)

```bash
RESOURCE_ID=$(az containerapp show \
  --name paa-dev-app --resource-group paa-dev-rg \
  --query id -o tsv)

az rest --method GET \
  --url "https://management.azure.com${RESOURCE_ID}/detectors/containerappscontainerexitevents?api-version=2023-05-01"
```

Yields exit code summary and backoff-restart counts. Note: results are time-windowed; may be sparse for very recent events.

### F — Storage mount failures (diagnostics API)

```bash
az rest --method GET \
  --url "https://management.azure.com${RESOURCE_ID}/detectors/containerappsstoragemountfailures?api-version=2023-05-01"
```

A non-clean status here means the Azure Files share failed to mount — the container will not start.

### G — Config file inspection (Azure Files)

```bash
STORAGE_KEY=$(az storage account keys list \
  --account-name paadevocstate \
  --resource-group paa-dev-rg \
  --query "[0].value" -o tsv)

az storage file download \
  --account-name paadevocstate \
  --account-key "$STORAGE_KEY" \
  --share-name openclaw-state \
  --path "openclaw.json" \
  --dest /tmp/openclaw.json

cat /tmp/openclaw.json   # Check gateway.mode, port, auth.mode
rm /tmp/openclaw.json    # Delete immediately — never leave on disk
```

> **SEC**: Never print `auth.token` values. Redact before sharing output.

Valid values: `gateway.mode` = `"remote"` | `"local"`. Port must match ingress (18789). `"server"` is **not** a valid value.

### H — Identity role assignments

```bash
PRINCIPAL_ID=$(az identity show \
  --name paa-dev-id \
  --resource-group paa-dev-rg \
  --query principalId -o tsv)

az role assignment list \
  --assignee-object-id "$PRINCIPAL_ID" \
  --all -o table
```

Required roles: `Key Vault Secrets User`, `AcrPull`, and any AI/Cognitive Services user role.

### I — Image schema inspection (no source needed)

When `openclaw.json` config values are uncertain, discover valid schema values directly from the bundled JS:

```bash
docker run --rm ghcr.io/openclaw/openclaw:<tag> \
  sh -c "grep -r 'gateway.mode\|\"local\"\|\"remote\"\|\"server\"' dist/ 2>/dev/null | grep -v '.map' | head -20"
```

## Known Limitations

| Limitation | Workaround |
|------------|------------|
| `az monitor log-analytics query` blocked by prod NSP | Use `az containerapp logs show` (sections C, D) |
| `az containerapp logs show` returns nothing when replicas=0 | Use sections D (system events) and E (exit codes) |
| `az containerapp exec` unreliable against crashing containers | Use `docker run` for image inspection instead (section I) |
| Diagnostics API (sections E, F) is time-windowed | Wait ~5 min after a crash; retry if results are empty |

## Runbook

Full troubleshooting documentation with a tool reference table and common failure patterns is in **Section 7** of [docs/openclaw-containerapp-operations.md](../../../docs/openclaw-containerapp-operations.md).

## Tool Reference

See [references/tool-reference.md](references/tool-reference.md) for the full command reference table used during the 2026-03-30 incident.
