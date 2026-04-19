# argocd/apps/

ArgoCD manifests for OpenClaw instance deployments.

## Structure

| File | Kind | Cluster | Purpose |
|------|------|---------|---------|
| `openclaw-appset-dev.yaml` | `ApplicationSet` | dev | Generates one `Application` per dev instance (`ch`, `jh`); tracks `dev` branch |
| `openclaw-appset-prod.yaml` | `ApplicationSet` | prod | Generates one `Application` per prod instance (`ch`, `jh`, `kjm`); tracks `HEAD` |
| `dev-openclaw.yaml` | `Application` | dev | **Deprecated** — legacy single-instance dev deployment; retained until `openclaw` namespace is confirmed decommissioned |
| `prod-openclaw.yaml` | `Application` | prod | **Deprecated** — legacy single-instance prod deployment; retained until `openclaw` namespace is confirmed decommissioned |

Each ApplicationSet is applied to its own cluster. Both dev and prod instances share the same per-instance namespace name (`openclaw-{inst}`), so they must never run on the same cluster simultaneously.

## Adding a new instance

**Dev:** edit `spec.generators[0].list.elements` in `openclaw-appset-dev.yaml` and add `- inst: <name>`. Ensure `workloads/dev/openclaw-<name>/` exists.

**Prod:** edit `spec.generators[0].list.elements` in `openclaw-appset-prod.yaml` and add `- inst: <name>`. Ensure `workloads/prod/openclaw-<name>/` exists.

No other files need to be created. ArgoCD will expand a new `Application` named `<inst>-openclaw-<env>` targeting `workloads/<env>/openclaw-<inst>` in namespace `openclaw-<inst>`.

## Naming conventions

- Application name: `{inst}-openclaw-{env}`
- Helm chart path: `workloads/{env}/openclaw-{inst}`
- Destination namespace: `openclaw-{inst}`
- `targetRevision`: `dev` (dev instances) / `HEAD` (prod instances)

## Apply

```bash
# Dev cluster
kubectl apply -f argocd/apps/openclaw-appset-dev.yaml

# Prod cluster
kubectl apply -f argocd/apps/openclaw-appset-prod.yaml
```

To verify expansion:

```bash
kubectl get applications -n argocd
```
