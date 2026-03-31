# Kubernetes Deployment

Reference: [docs.openclaw.ai/install/kubernetes](https://docs.openclaw.ai/install/kubernetes)

A minimal starting point — not production-ready. Intended to be adapted to your environment.

## What gets deployed

```
Namespace: openclaw
├── Deployment/openclaw        # Single pod, init container + gateway
├── Service/openclaw           # ClusterIP on port 18789
├── PersistentVolumeClaim      # 10Gi for agent state and config
├── ConfigMap/openclaw-config  # openclaw.json + AGENTS.md
└── Secret/openclaw-secrets    # Gateway token + API keys
```

## Quick start

```bash
export ANTHROPIC_API_KEY="..."
./scripts/k8s/deploy.sh

kubectl port-forward svc/openclaw 18789:18789 -n openclaw

# Retrieve gateway token:
kubectl get secret openclaw-secrets -n openclaw \
  -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' | base64 -d
```

## Key operations

| Task | Command |
|---|---|
| Deploy / re-deploy | `./scripts/k8s/deploy.sh` |
| Teardown (deletes PVC) | `./scripts/k8s/deploy.sh --delete` |
| Custom namespace | `OPENCLAW_NAMESPACE=my-ns ./scripts/k8s/deploy.sh` |
| Add/update provider key | `kubectl patch secret openclaw-secrets -n openclaw -p '{"stringData":{"ANTHROPIC_API_KEY":"..."}}' && kubectl rollout restart deployment/openclaw -n openclaw` |
| Local cluster (Kind) | `./scripts/k8s/create-kind.sh` |

## Config and customization

- **`openclaw.json`** — edit in `scripts/k8s/manifests/configmap.yaml`, then `./scripts/k8s/deploy.sh`
- **Agent instructions** — edit `AGENTS.md` in `configmap.yaml`, then redeploy
- **Pin image version** — edit `image:` field in `scripts/k8s/manifests/deployment.yaml`
- **Expose beyond port-forward** — change `gateway.bind` from `loopback`; keep auth enabled with TLS termination

## Architecture notes

- Gateway binds to loopback inside pod by default; use `kubectl port-forward` for local access
- No cluster-scoped resources — everything in a single namespace
- Security: `readOnlyRootFilesystem`, `drop: ALL` capabilities, non-root UID 1000
- Secrets generated in a temp dir, applied directly to cluster — no secret material in repo
- Kustomize for overlays; Helm optional (can be layered on top)
