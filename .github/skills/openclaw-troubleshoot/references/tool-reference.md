# OpenClaw Troubleshooting — Tool Reference

Full command reference extracted from the 2026-03-30 production incident. All commands target dev.

## Complete Tool Table

| Tool / Command | Purpose | Key Limitation |
|---|---|---|
| `bash scripts/diagnose-containerapp.sh dev` | Single command that runs all sections A–H and writes output to `scripts/diag-dev-<timestamp>.txt` | Requires `az login`; no Terraform state needed |
| `bash scripts/dump-resource-inventory.sh` | Discover all resource names by tag via Log Analytics KQL | Requires Log Analytics access (blocked by NSP in prod) |
| `az containerapp revision list -o table` | See all revisions: health/traffic/replica counts | First stop for any startup failure |
| `az containerapp revision show --query "properties.runningStateDetails"` | Human-readable failure reason (e.g. `"1/1 Container crashing: openclaw"`) | Only meaningful on active revisions |
| `az containerapp replica list` | Get replica name needed for per-replica log retrieval | Returns empty when replicas=0 (crashed container) |
| `az containerapp logs show --revision <r> --replica <n> --follow false` | Pull container stdout/stderr (actual crash output) | Requires a running replica; unavailable at replicas=0 |
| `az containerapp logs show --type system --tail 50` | Stream Container App controller events — **surfaced the `PortMismatch` error** | May be empty for very recent events |
| `az rest GET .../detectors/containerappscontainerexitevents` | Exit code summary, backoff-restart counts, last error type | Undocumented API; time-windowed results |
| `az rest GET .../detectors/containerappsstoragemountfailures` | Confirm whether Azure Files mount failures contributed | Undocumented API; clean result rules out storage mounts |
| `az containerapp env storage show` | Verify Azure Files share binding exists and is configured | — |
| `az storage file list / download` | Inspect `openclaw.json` config on the persistent share | Requires storage account key; delete local copy after use |
| `docker inspect <image>` | Reveal `Entrypoint`, `Cmd`, and env vars baked into the image | Requires docker CLI and image pull access |
| `docker run --rm <image> sh -c "grep -r ..."` | Search bundled JS for valid config schema values | Used to discover `gateway.mode` valid values |
| `az monitor log-analytics query` | Full KQL queries against Container App console logs | **Blocked by prod NSP** — not usable from outside Azure |
| `az monitor activity-log list` / MCP `monitor_activitylog_list` | Activity log for deployment history and provisioning failures | No container-level detail; useful for Terraform apply failures |
| `az role assignment list --assignee-object-id` | Confirm Managed Identity has required roles (KV Secrets User, AcrPull, AI User) | — |

## Diagnostics API URL Template

```
https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.App/containerApps/<app>/detectors/<detector>?api-version=2023-05-01
```

Detectors used in this incident:
- `containerappscontainerexitevents`
- `containerappsstoragemountfailures`

Retrieve the full resource ID with:
```bash
az containerapp show --name paa-dev-app --resource-group paa-dev-rg --query id -o tsv
```

## Common Failure Patterns

| Symptom | Likely Cause | Section to Check |
|---------|--------------|------------------|
| Replicas=0, health=Unhealthy | Container crashing on startup | B (runningStateDetails), then C or D |
| `PortMismatch` in system events | `gateway.port` in config doesn't match Container App ingress port (18789) | D, then G |
| Container exits immediately | Bad `openclaw.json` schema (e.g. invalid `gateway.mode`) | G (config), then I (image schema) |
| App starts but KV secret missing | Managed Identity missing `Key Vault Secrets User` role | H (role assignments) |
| Azure Files not mounted | Storage mount failure, wrong share name, or missing storage account key | F (storage detector), then Terraform `containerapp.tf` |
