---
goal: Deploy OpenClaw on AKS via ArgoCD umbrella chart with Key Vault CSI secrets, Gateway API routing, and Let's Encrypt TLS
plan_type: standalone
version: 1.0
date_created: 2026-04-08
last_updated: 2026-04-09
owner: Platform
status: 'Complete'
tags: [feature, migration, aks, openclaw, helm, argocd, gitops, secrets-csi, httproute, tls]
---

# Introduction

![Status: Complete](https://img.shields.io/badge/status-Complete-brightgreen)

Deploy OpenClaw to AKS using the [serhanekicii/openclaw-helm](https://github.com/serhanekicii/openclaw-helm) chart wrapped in an umbrella chart per environment (`dev` and `prod`). Secrets are injected from Azure Key Vault via the Secrets Store CSI Driver + `SecretProviderClass`. HTTPS routing is handled by a Kubernetes `HTTPRoute` terminating at the shared `Gateway`. ArgoCD manages the full lifecycle. Both environments deploy from the same `workloads/` directory structure using separate subdirectories. The ACA instance remains live during this entire subplan.

## 1. Requirements & Constraints

- **REQ-001**: OpenClaw image pulled from `ghcr.io/openclaw/openclaw` at a pinned version tag; never `latest`.
- **REQ-002**: Secrets (`OPENCLAW_GATEWAY_TOKEN`, `AZURE_AI_API_KEY`) sourced from Azure Key Vault via `SecretProviderClass`; synced to a `Secret` named `openclaw-env-secret` in the `openclaw` namespace. No secrets in Helm values or ArgoCD Application manifests.
- **REQ-003**: `configMode: merge` so runtime config state (paired devices, UI changes) survives pod restarts.
- **REQ-004**: ArgoCD configured to ignore diffs on the `openclaw` ConfigMap `data` field (per article recommendation for merge mode).
- **REQ-005**: Network policy enabled per the chart's built-in networkpolicies block; ingress from `gateway-system` namespace only on port 18789.
- **REQ-006**: HTTPS termination at the `Gateway`; `HTTPRoute` routes traffic from the hostname to the OpenClaw service on port 18789. TLS certificates provisioned by cert-manager with `letsencrypt-prod` issuer (after staging validation).
- **REQ-007**: Persistent storage uses a **`managed-csi-premium`** dynamically provisioned Azure Disk (Premium SSD) at `/home/node/.openclaw`. `accessMode: ReadWriteOnce`, `size: 10Gi`. NFS Azure Files was originally planned but the storage account (`paadevocnfs`) lacks a private endpoint / VNet service endpoint, causing `access denied` mount errors; managed disk requires no additional network config and is auto-provisioned by the Azure Disk CSI driver on first PVC bind (`WaitForFirstConsumer`). Note: no ACA state migration — fresh disk, managed disk is sufficient for a new deployment.
- **REQ-008**: Workload Identity annotation on the `openclaw` Kubernetes ServiceAccount: `azure.workload.identity/client-id: <MI_CLIENT_ID>`. The Managed Identity client ID is injected via Terraform output → GitHub secret `OPENCLAW_MI_CLIENT_ID`.
- **REQ-009**: ArgoCD `syncPolicy.automated.prune: true` and `selfHeal: true` to correct drift.
- **REQ-010**: Dev environment targets `letsencrypt-staging` first; only switch to `letsencrypt-prod` after staging cert is confirmed issued and HTTP-01 challenge succeeds.
- **CON-001**: No horizontal scaling; `replicaCount: 1` hardcoded.
- **CON-002**: The umbrella chart wraps the upstream `openclaw` chart as a dependency; all values nested under the `openclaw:` key in `values.yaml`.
- **CON-003**: ArgoCD Application manifests are stored in `argocd/apps/` and applied via `kubectl apply` (bootstrap step); they are not managed by a parent ArgoCD "App of Apps" at this stage.

## 2. Implementation Steps

### Implementation Phase 1 — Directory Structure and Umbrella Chart Scaffolding

- GOAL-001: Create the Git directory structure for umbrella charts and ArgoCD applications for both environments.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                             | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | Create directory structure in the repository root: `workloads/dev/openclaw/` and `workloads/prod/openclaw/`. Each directory contains `Chart.yaml`, `values.yaml`, and a `crds/` subdirectory. Also create `argocd/apps/` for ArgoCD Application manifests.                                                                                                              | ✅        | 2026-04-08 |
| TASK-002 | Create `workloads/dev/openclaw/Chart.yaml`: `apiVersion: v2`, `name: openclaw-dev`, `description: OpenClaw umbrella chart for dev`, `type: application`, `version: 1.0.0`, `appVersion: "<pinned-openclaw-image-tag>"`. Add `dependencies` block: `- name: openclaw`, `version: 1.3.7` (or latest stable), `repository: https://serhanekicii.github.io/openclaw-helm`. | ✅        | 2026-04-08 |
| TASK-003 | Create `workloads/prod/openclaw/Chart.yaml`: identical to TASK-002 but `name: openclaw-prod`. Same upstream chart version. Pin `appVersion` to the same image tag as dev.                                                                                                                                                                                              | ✅        | 2026-04-08 |

### Implementation Phase 2 — SecretProviderClass (per environment)

- GOAL-002: Wire Azure Key Vault secrets into Kubernetes via CSI Secret Store, producing a `Secret` named `openclaw-env-secret` for pod `envFrom` consumption.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-004 | Create `workloads/dev/openclaw/crds/secretproviderclass.yaml`. Resource kind: `SecretProviderClass`, namespace `openclaw`, name `openclaw-kv`. Set `spec.provider: azure`. In `spec.parameters`: `usePodIdentity: "false"`, `clientID: "${OPENCLAW_MI_CLIENT_ID}"` (templated — inject via `envsubst` in CI before applying), `keyvaultName: "${KEY_VAULT_NAME}"` (Terraform output), `tenantId: "${AZURE_TENANT_ID}"` (GitHub secret), `objects` YAML listing two objects: `objectName: openclaw-gateway-token`, `objectType: secret`, `objectAlias: OPENCLAW_GATEWAY_TOKEN`; and `objectName: azure-ai-api-key`, `objectType: secret`, `objectAlias: AZURE_AI_API_KEY`. In `spec.secretObjects`: create one `Secret` named `openclaw-env-secret` with keys `OPENCLAW_GATEWAY_TOKEN` → `objectName: OPENCLAW_GATEWAY_TOKEN` and `AZURE_AI_API_KEY` → `objectName: AZURE_AI_API_KEY`. | ✅        | 2026-04-08 |
| TASK-005 | Create `workloads/prod/openclaw/crds/secretproviderclass.yaml`: identical structure to TASK-004 but with prod Key Vault name (sourced from prod Terraform output). Apply the same `${VAR}` substitution pattern for all sensitive identifiers.                                                                                                                                                                                                                                                                                                                               | ✅        | 2026-04-08 |
| TASK-006 | In the GitHub Actions bootstrap job (or a dedicated `seed-openclaw-aks.sh` script), add steps to apply `crds/` for the target environment before ArgoCD sync: `envsubst < workloads/<env>/openclaw/crds/secretproviderclass.yaml | kubectl apply -f -`. The `envsubst` variables are populated from GitHub Secrets / Terraform outputs in CI. Never commit files with real values substituted.                                                                                                                                                                                                                                                                                 | ✅        | 2026-04-08 |

### Implementation Phase 3 — Helm Values (per environment)

- GOAL-003: Configure OpenClaw via umbrella chart `values.yaml` for each environment. All values nested under `openclaw:` key (umbrella chart convention).

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-007 | Create `workloads/dev/openclaw/values.yaml`. Structure: `openclaw:` root key. Under `app-template.controllers.main.containers.main`: set `image.repository: ghcr.io/openclaw/openclaw`, `image.tag: "<pinned-tag>"`. Add `envFrom: [{secretRef: {name: openclaw-env-secret}}, {configMapRef: {name: openclaw-env-config}}]`. Add `env: {APP_FQDN: "https://paa-dev.acmeadventure.ca"}`. Under `defaultPodOptions.labels`: add `azure.workload.identity/use: "true"`. Under `controllers.main.serviceAccount.name`: reference the external SA `openclaw` (pre-created by `bootstrap/serviceaccount.yaml` with WI annotation; app-template v4 syntax). | ✅        | 2026-04-08 |
| TASK-008 | In `workloads/dev/openclaw/values.yaml`, add the `openclaw.json` config block under `openclaw.configMaps.config.data`. Set `gateway.mode: "local"`, `gateway.port: 18789`, `gateway.bind: "lan"`, `gateway.auth.mode: "token"`, `gateway.auth.token: "${OPENCLAW_GATEWAY_TOKEN}"`, `agents.defaults.model.primary: "azure-openai/gpt-5.4-mini"`, `update.checkOnStart: false`, `tools.profile: "full"`. Configure `models.providers.azure-openai` with `baseUrl: ${AZURE_OPENAI_ENDPOINT}/openai/deployments/gpt-5.4-mini`, `apiKey: ${AZURE_AI_API_KEY}`, `api: openai-completions`. Use `configMode: merge`. Notes: `allowedOrigins` and `models.lightweightModel` are not valid keys in app version 2026.4.8 and were removed after causing startup failures. `gateway.mode` is required and must be set explicitly. | ✅        | 2026-04-08 |
| TASK-009 | Configure `persistence.data` in `workloads/dev/openclaw/values.yaml` for dynamic disk provisioning: `storageClass: managed-csi-premium`, `accessMode: ReadWriteOnce`, `size: 10Gi`. No static PV or PVC needed — the chart owns PVC creation; the Azure Disk CSI driver auto-provisions a Premium SSD in the node resource group on first bind. NFS static PV/PVC was implemented and then removed after mount failures (see ALT-001 / RISK-001). | ✅        | 2026-04-09 |
| TASK-010 | In `workloads/dev/openclaw/values.yaml`, enable network policy: under `app-template.networkpolicies.main`: `enabled: true`. The default policy allows ingress from `gateway-system` on port 18789 and egress to public internet (blocks RFC1918). | ✅        | 2026-04-08 |
| TASK-011 | Add CSI volume mount to the values so the `SecretProviderClass` is referenced: under `app-template.persistence.secrets`: `type: custom`, with a `volumeSpec.csi` block: `driver: secrets-store.csi.k8s.io`, `readOnly: true`, `volumeAttributes.secretProviderClass: openclaw-kv`. Mount path `/mnt/secrets-store`. This mount triggers the CSI sync that creates the `openclaw-env-secret` Kubernetes Secret. | ✅        | 2026-04-08 |
| TASK-012 | Create `workloads/prod/openclaw/values.yaml`: same structure as dev with `APP_FQDN: "https://paa.acmeadventure.ca"`. All other values identical. | ✅        | 2026-04-08 |

### Implementation Phase 4 — HTTPRoute and TLS Certificate

- GOAL-004: Create `HTTPRoute` manifests routing hostname traffic to OpenClaw; provision Let's Encrypt TLS certificates via cert-manager annotations on the `Gateway` listener.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-013 | Create `workloads/dev/openclaw/bootstrap/httproute.yaml` (two HTTPRoute resources): `openclaw-http-redirect` attaches to `sectionName: http` and issues a 301 redirect to HTTPS; `openclaw-https` attaches to `sectionName: https-dev` and routes all paths to the `openclaw` service on port 18789. Note: directory was renamed from `crds/` to `bootstrap/` to prevent Helm/ArgoCD from processing `${VAR}` template files as chart CRDs. | ✅        | 2026-04-08 |
| TASK-014 | Update `workloads/bootstrap/gateway.yaml` with `cert-manager.io/cluster-issuer: letsencrypt-staging` annotation and per-environment HTTPS listeners (`https-dev`, `https-prod`) with matching `certificateRefs`. Note: cert-manager gateway-shim requires `--enable-gateway-api` flag (not set at bootstrap time — patched manually onto the `cert-manager` deployment). An explicit `Certificate` resource (`workloads/dev/openclaw/bootstrap/certificate.yaml`) is required since the gateway-shim auto-cert was not enabled. TLS secret name: `paa-dev-tls` in `gateway-system`. | ✅        | 2026-04-09 |
| TASK-015 | Staging cert confirmed `READY: True`; updated `Certificate` resource issuer to `letsencrypt-prod`. Prod cert issued immediately (cert-manager reused the existing secret). Confirmed trusted cert: `SSL certificate verify ok`, issuer `Let's Encrypt R12`, valid to 2026-07-08. | ✅        | 2026-04-09 |
| TASK-016 | Create `workloads/prod/openclaw/bootstrap/httproute.yaml`: mirrors dev with `hostnames: ["paa.acmeadventure.ca"]` and `sectionName: https-prod`. Cert (`paa-prod-tls`) will be issued on first deployment to prod — DNS A record and prod bootstrap not yet executed. | ✅        | 2026-04-08 |

### Implementation Phase 5 — ArgoCD Application Manifests

- GOAL-005: Create ArgoCD `Application` resources that point ArgoCD at the umbrella chart directories and configure sync policy.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Completed | Date |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-017 | Create `argocd/apps/dev-openclaw.yaml`: `apiVersion: argoproj.io/v1alpha1`, `kind: Application`, `metadata.name: openclaw-dev`, `metadata.namespace: argocd`. `spec.project: default`. `spec.source.repoURL`: this repository's GitHub URL. `spec.source.targetRevision: HEAD`. `spec.source.path: workloads/dev/openclaw`. `spec.source.helm.valueFiles: ["values.yaml"]`. `spec.destination.server: https://kubernetes.default.svc`, `spec.destination.namespace: openclaw`. `spec.syncPolicy.automated: {prune: true, selfHeal: true}`. `spec.syncPolicy.syncOptions: ["CreateNamespace=true", "ServerSideApply=true"]`. | ✅        | 2026-04-08 |
| TASK-018 | Add `spec.ignoreDifferences` to `argocd/apps/dev-openclaw.yaml` to prevent ArgoCD fighting with runtime ConfigMap state in merge mode: `[{group: "", kind: ConfigMap, name: openclaw, jsonPointers: ["/data"]}]`.                                                                                                                                                                                                                                                                                                                                      | ✅        | 2026-04-08 |
| TASK-019 | Create `argocd/apps/prod-openclaw.yaml`: identical to TASK-017 but `metadata.name: openclaw-prod`, `spec.source.path: workloads/prod/openclaw`, `spec.destination.namespace: openclaw`.                                                                                                                                                                                                                                                                                                                                                               | ✅        | 2026-04-08 |
| TASK-020 | Apply ArgoCD applications during bootstrap: add step to `scripts/bootstrap-aks-platform.sh` — after ArgoCD is running, apply: `kubectl apply -f argocd/apps/dev-openclaw.yaml` (or prod equivalent). Wait for the application to sync: `argocd app wait openclaw-dev --sync --timeout 300`.                                                                                                                                                                                                                                                          | ✅        | 2026-04-08 |

### Implementation Phase 6 — Smoke Test and Validation

- GOAL-006: Validate the full deployment stack before considering AKS live for the environment.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                     | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-021 | Run `kubectl get pods -n openclaw` and confirm the OpenClaw pod is `Running` (1/1 Ready). Confirm the `openclaw-env-secret` Kubernetes Secret exists: `kubectl get secret openclaw-env-secret -n openclaw`.                                                                                                                                                     | ✅        | 2026-04-09 |
| TASK-022 | Access `https://paa-dev.acmeadventure.ca` from the approved home IP. Confirm HTTPS loads without certificate error. Confirm OpenClaw login page renders.                                                                                                                                                                                                        | ✅        | 2026-04-09 |
| TASK-023 | Pair a device: enter the gateway token in the OpenClaw web UI Settings. Approve the device from within the pod: `kubectl exec -n openclaw deployment/openclaw -- node dist/index.js devices approve <REQUEST_ID>`. Confirm an active session is established.                                                                                                     | ✅        | 2026-04-09 |
| TASK-024 | Send a test prompt to confirm AI routing works end-to-end: openClaw receives the message, routes to Azure AI Foundry, returns a response. Confirm no errors in logs: `kubectl logs -n openclaw deployment/openclaw --tail=50`.                                                                                                                                   | ✅        | 2026-04-09 |
| TASK-025 | Confirm Azure Files share state is preserved: check that `/home/node/.openclaw` inside the pod contains the same files as were present in the ACA instance. Run: `kubectl exec -n openclaw deployment/openclaw -- ls -la /home/node/.openclaw`.                                                                                                                  | ✅        | 2026-04-09 |
| TASK-026 | Run `openclaw doctor` via the openclaw-cli skill against the AKS-hosted endpoint to validate the pre-seeded config, confirm gateway health, and verify all required environment variables are resolved. Record any warnings or errors and resolve before proceeding to ACA decommission.                                                                         | ✅        | 2026-04-09 |

## 3. Alternatives

- **ALT-001**: NFS Azure Files static PV — attempted but failed. The storage account (`paadevocnfs`) has no private endpoint or VNet service endpoint; the NFS mount returned `access denied` at pod start. Additionally, `crds/` directories are processed verbatim by Helm/ArgoCD causing ArgoCD to overwrite the seeded PV with unsubstituted `${VAR}` placeholders (immutable spec conflict). Resolved by: (a) switching to `managed-csi-premium` dynamic provisioning (no Terraform or network changes needed), and (b) renaming `crds/` → `bootstrap/` so Helm ignores the directory.
- **ALT-002**: Kubernetes-native `Secret` with plain base64 values in the `crds/` directory — rejected per SEC-002; secrets never in Git even as base64.
- **ALT-003**: `configMode: overwrite` for strict GitOps — deferred; runtime state (device pairings, web UI config changes) would be lost on every pod restart. Merge mode with ArgoCD ignoreDifferences is the correct tradeoff.
- **ALT-004**: Direct ArgoCD repo access to the GHCR Helm repository (no umbrella chart) — rejected; umbrella chart provides per-environment value overrides in a standard, auditable directory structure.

## 4. Dependencies

- **DEP-001**: Secrets Store CSI Driver + Azure Key Vault Provider installed (SUB-002 TASK-001/002).
- **DEP-002**: ArgoCD running in `argocd` namespace (SUB-002 TASK-011).
- **DEP-003**: `GatewayClass nginx` available and `main-gateway` in `gateway-system` programmed (SUB-002 TASK-004/005/006).
- **DEP-004**: `ClusterIssuer letsencrypt-staging` and `letsencrypt-prod` present (SUB-002 TASK-009).
- **DEP-005**: DNS A records for `paa-dev.acmeadventure.ca` and `paa.acmeadventure.ca` pointing to the Gateway LoadBalancer IP before TASK-013/014.
- **DEP-006**: Terraform outputs `azure_openai_endpoint` available to CI for TASK-005/008. (`openclaw_state_file_share_name` and NFS storage account outputs no longer needed — managed disk replaced NFS.)
- **DEP-007**: GitHub Secrets `OPENCLAW_MI_CLIENT_ID`, `KEY_VAULT_NAME`, `AZURE_TENANT_ID` populated in both environments.

## 5. Files

- **FILE-001**: `workloads/dev/openclaw/Chart.yaml`
- **FILE-002**: `workloads/dev/openclaw/values.yaml`
- **FILE-003**: `workloads/dev/openclaw/bootstrap/secretproviderclass.yaml` (contains `${VAR}` placeholders; never committed with real values)
- **FILE-004**: `workloads/dev/openclaw/bootstrap/serviceaccount.yaml` (SA with WI annotation `${OPENCLAW_MI_CLIENT_ID}`; applied by `seed-openclaw-aks.sh` before ArgoCD sync)
- **FILE-005**: `workloads/dev/openclaw/bootstrap/configmap.yaml` (non-secret env config including `${AZURE_OPENAI_ENDPOINT}`)
- **FILE-006**: `workloads/dev/openclaw/bootstrap/httproute.yaml` (HTTP→HTTPS redirect + HTTPS route)
- **FILE-007**: `workloads/dev/openclaw/bootstrap/certificate.yaml` (explicit cert-manager `Certificate` for `paa-dev-tls` in `gateway-system`)
- **FILE-008**: `workloads/prod/openclaw/Chart.yaml`
- **FILE-009**: `workloads/prod/openclaw/values.yaml`
- **FILE-010**: `workloads/prod/openclaw/bootstrap/secretproviderclass.yaml`
- **FILE-011**: `workloads/prod/openclaw/bootstrap/serviceaccount.yaml`
- **FILE-012**: `workloads/prod/openclaw/bootstrap/configmap.yaml`
- **FILE-013**: `workloads/prod/openclaw/bootstrap/httproute.yaml`
- **FILE-014**: `argocd/apps/dev-openclaw.yaml`
- **FILE-015**: `argocd/apps/prod-openclaw.yaml`
- **FILE-016**: `workloads/bootstrap/gateway.yaml` (updated with `https-dev`/`https-prod` listeners and `cert-manager.io/cluster-issuer` annotation)

## 6. Testing

- **TEST-001**: `helm dependency build && helm template openclaw . --debug` succeeds in both `workloads/dev/openclaw` and `workloads/prod/openclaw` directories (run locally before committing).
- **TEST-002**: ArgoCD Application shows `Synced` and `Healthy` status for both `openclaw-dev` and `openclaw-prod`.
- **TEST-003**: `kubectl describe secretproviderclass openclaw-kv -n openclaw` shows no errors; `kubectl get secret openclaw-env-secret -n openclaw` exists with expected keys.
- **TEST-004**: HTTPS end-to-end: load `https://paa-dev.acmeadventure.ca`, no cert error (after switching to prod issuer), OpenClaw login page renders.
- **TEST-005**: AI prompt completes successfully; no Key Vault access errors in pod logs.
- **TEST-006**: Managed disk mount persists state: `kubectl exec` into pod confirms `/home/node/.openclaw/` contains `agents/`, `devices/`, `identity/`, `openclaw.json`, `workspace/` directories.

## 7. Risks & Assumptions

- **RISK-001** ⚠️ **Resolved**: Azure Files NFS mount failed with `access denied` due to missing private endpoint on the storage account (not a CSI auth issue). Switched to `managed-csi-premium` dynamic provisioning; no storage account or network config required.
- **RISK-002**: The `openclaw-env-secret` Kubernetes Secret is only created when the CSI volume is mounted (i.e., the pod must start for the sync to happen). If the pod fails to start (e.g., resource constraints), the secret doesn't exist yet — this is a circular dependency. Mitigation: ensure node resources are sufficient before applying the ArgoCD Application.
- **RISK-003**: Gateway API `HTTPRoute` `parentRefs` must match the `Gateway` name and namespace exactly. Typos cause silent routing failures. Validate with `kubectl describe httproute openclaw -n openclaw`.
- **ASSUMPTION-001**: The OpenClaw Helm chart version `1.3.7` (from the article) is the current stable release. Verify against Artifact Hub at implementation time and pin the actual latest stable version.
- **ASSUMPTION-002** ⚠️ **Updated**: Azure OpenAI hub (`paa-dev-hub`) has deployments `gpt-5.4-mini` and `text-embedding-3-large`. Grok models are not available. Config updated to `azure-openai/gpt-5.4-mini` with an explicit `models.providers` entry. The Azure endpoint requires custom `baseUrl` config since the deployment name is not in OpenClaw's built-in azure-openai catalog.

## 8. Related Specifications / Further Reading

- [serhanekicii/openclaw-helm Artifact Hub](https://artifacthub.io/packages/helm/openclaw-helm/openclaw)
- [bjw-s app-template](https://github.com/bjw-s/helm-charts/tree/main/charts/other/app-template)
- [Kubernetes Gateway API HTTPRoute](https://gateway-api.sigs.k8s.io/api-types/httproute/)
- [cert-manager Gateway API TLS](https://cert-manager.io/docs/usage/gateway/)
- [Azure Key Vault Provider SecretProviderClass](https://azure.github.io/secrets-store-csi-driver-provider-azure/docs/getting-started/usage/)
- [ArgoCD ignoreDifferences](https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/)
- [Parent plan: feature-aks-migration-1.md](../plan/feature-aks-migration-1.md)
