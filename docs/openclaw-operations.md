# OpenClaw Operations Runbook

> **Historical note:** Azure Container Apps (ACA) was decommissioned 2026-04-09 (dev) as part of the AKS migration. All ACA-specific procedures have been removed from this document.

This document covers operational procedures for the OpenClaw gateway runtime: first-time bootstrap, gateway token management, config updates, storage backup/restore, and image upgrades.

## Prerequisites

- Azure CLI authenticated with sufficient permissions on the environment resource group
- Access to the Key Vault in the environment resource group
- Terraform state is healthy and `terraform plan` shows no unexpected drift

> **Environment safety:** Unless performing an authorized production incident response, always execute these procedures against the **dev** environment first. Validate the outcome in dev before applying to prod. AI agents must only be directed to operate against dev resources; do not supply production resource names to an AI agent during a troubleshooting or debugging session.

---

## AKS Operations

> **Dev cluster is stopped by default.** The dev AKS cluster stops automatically each night and does not start automatically. Before running any procedure below against the dev environment, confirm the cluster is running (`az aks show ... --query powerState.code`) and start it if needed. See the [Troubleshooting: Cluster Stopped](../readme.md#troubleshooting-cluster-stopped) section in `readme.md` for the full startup sequence.

### Prerequisites

- `kubectl` and `argocd` CLI installed
- Kubeconfig obtained: `az aks get-credentials --name paa-<env>-aks --resource-group paa-<env>-rg`
- ArgoCD accessed via port-forward: `kubectl port-forward svc/argocd-server -n argocd 8080:80` → `http://localhost:8080`

### AKS.1 First-Time Bootstrap

1. AKS cluster and platform bootstrap complete (SUB-001 + SUB-002 per `plan/feature-aks-migration-1.md`).
2. Obtain kubeconfig:
   ```bash
   az aks get-credentials --name paa-<env>-aks --resource-group paa-<env>-rg
   ```
3. Apply CRDs (SecretProviderClass and supporting manifests):
   ```bash
   envsubst < workloads/<env>/openclaw/crds/secretproviderclass.yaml | kubectl apply -f -
   ```
4. Apply the ArgoCD Application to deploy OpenClaw:
   ```bash
   kubectl apply -f argocd/apps/openclaw-<env>.yaml
   ```
5. Monitor pod startup:
   ```bash
   kubectl get pods -n openclaw -w
   ```
6. Load remote credentials and approve device:
   ```bash
   source <(./scripts/openclaw-connect.sh <env> --export)
   openclaw devices list
   openclaw devices approve <requestId>
   ```
7. Validate:
   ```bash
   openclaw status --all
   openclaw doctor
   ```

### AKS.2 Gateway Token Rotation

1. Generate a new token:
   ```bash
   NEW_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(24))")
   ```
2. Update the Key Vault secret:
   ```bash
   az keyvault secret set \
     --vault-name "<kv-name>" \
     --name "openclaw-gateway-token" \
     --value "$NEW_TOKEN"
   ```
3. The CSI driver rotates the Kubernetes Secret automatically at the configured 2-minute interval. To force immediate refresh:
   ```bash
   kubectl rollout restart deployment/openclaw -n openclaw
   ```
   > **Confirm with the user before restarting.** The rollout briefly interrupts gateway availability.
4. Confirm:
   ```bash
   kubectl rollout status deployment/openclaw -n openclaw
   openclaw status
   ```

### AKS.3 Configuration Updates

**Bulk updates (primary path):** Update `workloads/<env>/openclaw/values.yaml` in Git, open a pull request, and merge. ArgoCD syncs automatically. `configMode: merge` means runtime state (paired devices, UI changes) is preserved across syncs.

For an immediate forced sync without waiting for Git merge:
```bash
argocd app sync openclaw-<env>
```

**Individual key (immediate in-place change):**
```bash
kubectl exec -n openclaw deployment/openclaw -- node /app/openclaw.mjs config set <key> <value>
```

If `gateway.*` was changed, restart the pod (confirm with user first):
```bash
kubectl rollout restart deployment/openclaw -n openclaw
```

> **Note:** `openclaw config set` writes to the local shell's `~/.openclaw`, not the gateway pod. Always use `kubectl exec` for gateway config changes.

### AKS.4 Logs and Diagnostics

```bash
# Live logs
kubectl logs -n openclaw deployment/openclaw --follow --tail=100

# Pod status
kubectl get pods -n openclaw -o wide

# Describe pod (events, volume mounts)
kubectl describe pod -n openclaw <pod-name>

# ArgoCD sync status
kubectl get application openclaw-<env> -n argocd

# CSI secret health
kubectl get secret openclaw-env-secret -n openclaw
kubectl get secretproviderclass -n openclaw
```

Log Analytics (AKS diagnostics) — use `azure-mcp-server/monitor` with KQL:
```kql
ContainerLogV2
| where ContainerName == "openclaw"
| order by TimeGenerated desc
| take 100
```

### AKS.5 Image Upgrades

1. Identify the new pinned tag from the [OpenClaw GHCR release page](https://github.com/openclaw/openclaw/pkgs/container/openclaw).
2. Update `appVersion` in `workloads/<env>/openclaw/Chart.yaml` to the new tag.
3. Open a pull request — review the ArgoCD diff confirming only the image tag changes.
4. Merge to apply. ArgoCD rolls out the new pod. The Azure Disk PVC (`managed-csi-premium`) is unaffected by the rollout.

**Rollback:** Revert `appVersion` in `Chart.yaml` and merge. ArgoCD rolls back to the previous image.

### AKS.6 ArgoCD Administration

ArgoCD is not exposed via the Gateway. Access the UI and API server with `kubectl port-forward`:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:80
# Then open: http://localhost:8080
```

Use the `argocd` CLI via the forwarded port:

```bash
argocd login localhost:8080 --username admin --password <password> --plaintext
```

#### Retrieve the Initial Admin Password

On first bootstrap, ArgoCD's initial admin password is stored in a Kubernetes Secret:

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

Log in at `http://localhost:8080` (port-forward active) with user `admin` and the password above.

> **Rotate the password immediately after first login.** The initial secret is deleted after the password is changed via the UI or CLI.

#### Rotate the Admin Password via CLI

```bash
argocd login localhost:8080 --username admin --password <current-password> --plaintext
argocd account update-password \
  --current-password <current-password> \
  --new-password <new-strong-password>
```

#### Rotate the Redis Secret

If the ArgoCD Redis auth secret needs rotation:

```bash
kubectl delete secret argocd-redis -n argocd
helm upgrade argocd argo/argo-cd --reuse-values --wait --namespace argocd
kubectl rollout restart deployment argocd-redis -n argocd
kubectl rollout restart deployment argocd-server argocd-repo-server -n argocd
kubectl rollout restart statefulset argocd-application-controller -n argocd
```

#### Force a Full Sync

```bash
argocd login localhost:8080 --username admin --password <password> --plaintext
argocd app sync --all
# or for a specific app:
argocd app sync openclaw-<env>
```

