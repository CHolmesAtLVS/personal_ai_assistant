---
name: openclaw-troubleshoot
description: "Diagnose OpenClaw pod startup failures and runtime errors on AKS using kubectl and Azure Monitor. WHEN: \"troubleshoot openclaw\", \"diagnose openclaw pod\", \"pod crashing\", \"CrashLoopBackOff\", \"startup failure\", \"openclaw not running\", \"debug aks pod\", \"what's wrong with openclaw\", \"argocd sync failed\"."
license: MIT
metadata:
  author: Platform Engineering
  version: "2.0.0"
  domain: operations
  scope: diagnosis
---

# OpenClaw Troubleshoot

Diagnose OpenClaw pod failures on AKS using `kubectl` commands and Azure Monitor. A `diagnose-aks.sh` script is planned as a replacement for the legacy `diagnose-containerapp.sh`; use the manual commands below in the interim.

> **Legacy:** `scripts/diagnose-containerapp.sh` targets the ACA deployment and is no longer the primary diagnostic path. See the runbook AKS Operations section for current procedures.

## Safety Rule

**Always target dev only.** Never supply production resource names or execute commands against prod during a troubleshooting session. If the target environment is ambiguous, ask explicitly before running any command.

## Quick Start

Run these in order to get a fast snapshot:

```bash
kubectl get pods -n openclaw -o wide
kubectl describe pod -n openclaw <pod-name>
kubectl logs -n openclaw deployment/openclaw --tail=50
```

Review pod STATUS and RESTARTS first. A `CrashLoopBackOff` status means check logs with `--previous` flag. A `Pending` status means check Events for volume mount or scheduling failures.

## Resource Naming

Resource names follow the `paa-<env>-*` pattern for Azure resources. Kubernetes resources use fixed names independent of environment prefix:

| Resource | Name |
|---|---|
| Namespace | `openclaw` |
| Deployment | `openclaw` |
| Service | `openclaw` |
| PVC | `openclaw-state` |
| Secret | `openclaw-env-secret` |
| SecretProviderClass | `openclaw-kv` |
| ArgoCD Application | `openclaw-dev` / `openclaw-prod` |
| Key Vault | `paa-dev-kv` |
| Managed Identity | `paa-dev-id` |
| Container App *(legacy ACA — pending decommission)* | `paa-dev-app` |
| ACA Storage Binding *(legacy ACA — pending decommission)* | `openclaw-state` |

If you need to discover Azure resource names:

```bash
bash scripts/dump-resource-inventory.sh
grep ",dev," scripts/resource-inventory.csv | awk -F',' '{print $1, $2, $3}'
```

## Step-by-Step Diagnostic Procedure

Work through sections in order, stopping when the root cause is found.

### A — Pod list (first stop for any startup failure)

```bash
kubectl get pods -n openclaw -o wide
```

Look for: STATUS (`Running`, `CrashLoopBackOff`, `Pending`, `OOMKilled`), READY column (`1/1` = healthy), RESTARTS count (high = crash loop).

### B — Pod detail

```bash
kubectl describe pod -n openclaw <pod-name>
```

Look for: **Events** section at the bottom (image pull errors, volume mount failures, OOM kills); **Conditions** block (`PodScheduled`, `ContainersReady`). A `FailedMount` event means the PVC or CSI secret volume failed to attach.

### C — Container logs

```bash
kubectl logs -n openclaw deployment/openclaw --tail=100
```

For a previously crashed container (restarts > 0):

```bash
kubectl logs -n openclaw deployment/openclaw --previous --tail=200
```

### D — ArgoCD sync status

```bash
kubectl get application openclaw-<env> -n argocd -o jsonpath='{.status.sync.status}'
kubectl get application openclaw-<env> -n argocd -o jsonpath='{.status.health.status}'
```

Both should be `Synced` and `Healthy`. If `OutOfSync` or `Degraded`, inspect:

```bash
kubectl describe application openclaw-<env> -n argocd
```

### E — CSI and Secret health

```bash
kubectl get secretproviderclass -n openclaw
kubectl get secret openclaw-env-secret -n openclaw
```

If `openclaw-env-secret` is missing, the CSI driver has not yet synced from Key Vault. Check the CSI provider pod:

```bash
kubectl get pods -n kube-system -l app=secrets-store-csi-driver
kubectl logs -n kube-system -l app=secrets-store-csi-driver --tail=50
```

### F — Storage (PVC) mount

```bash
kubectl get pvc -n openclaw
kubectl describe pvc openclaw-state -n openclaw
```

STATUS must be `Bound`. If `Pending`, the Azure Files CSI driver has not provisioned the volume — check the Events section for the failure reason.

### G — Config inspection (pod exec)

Read config values directly from the running pod:

```bash
kubectl exec -n openclaw deployment/openclaw -- node /app/openclaw.mjs config get gateway.mode
kubectl exec -n openclaw deployment/openclaw -- node /app/openclaw.mjs config get gateway.port
kubectl exec -n openclaw deployment/openclaw -- node /app/openclaw.mjs config get gateway.auth.mode
```

Full snapshot (tokens redacted — safe to share):

```bash
kubectl exec -n openclaw deployment/openclaw -- node /app/openclaw.mjs status --all
```

> **SEC**: Never print `auth.token` values. Redact before sharing output.

Valid values: `gateway.mode` must be `"local"` or `"remote"` (`"server"` is **not** valid). Port must be `18789`.

### H — Workload Identity and role assignments

```bash
PRINCIPAL_ID=$(az identity show \
  --name paa-dev-id \
  --resource-group paa-dev-rg \
  --query principalId -o tsv)

az role assignment list \
  --assignee-object-id "$PRINCIPAL_ID" \
  --all -o table
```

Required roles: `Key Vault Secrets User`, `AcrPull`, `Storage File Data NFS Share Contributor`, and any AI/Cognitive Services user role.

Also confirm the Workload Identity federated credential is present:

```bash
az identity federated-credential list \
  --identity-name paa-dev-id \
  --resource-group paa-dev-rg \
  -o table
```

### I — Image schema inspection (no source needed)

When `openclaw.json` config values are uncertain, discover valid schema values directly from the bundled JS:

```bash
docker run --rm ghcr.io/openclaw/openclaw:<tag> \
  sh -c "grep -r 'gateway.mode\|\"local\"\|\"remote\"\|\"server\"' dist/ 2>/dev/null | grep -v '.map' | head -20"
```

## Known Limitations

| Limitation | Workaround |
|------------|------------|
| `kubectl logs` unavailable if pod never started | Use `kubectl describe pod` Events section (section B) |
| CSI secret not synced yet | Check CSI driver pods in `kube-system` (section E) |
| ArgoCD sync pending | Force sync: `argocd app sync openclaw-<env>` or `kubectl rollout restart deployment/openclaw -n openclaw` |
| Log Analytics (`ContainerLogV2`) has ingestion lag | Use `kubectl logs` for real-time; Log Analytics for historical queries via `azure-mcp-server/monitor` |

## Runbook

Full troubleshooting documentation is in the **AKS Operations** section of [docs/openclaw-containerapp-operations.md](../../../docs/openclaw-containerapp-operations.md).

## Tool Reference

See [references/tool-reference.md](references/tool-reference.md) for the full command reference table.
