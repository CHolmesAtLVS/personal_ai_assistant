---
goal: Bootstrap Kubernetes platform tools on AKS — ArgoCD, NGINX Gateway Fabric, cert-manager, and Secrets Store CSI driver
plan_type: standalone
version: 1.0
date_created: 2026-04-08
last_updated: 2026-04-08
owner: Platform
status: 'In Progress'
tags: [feature, migration, aks, platform, argocd, cert-manager, gateway-api, secrets-csi, gitops]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

Install and configure the cluster-level platform tools onto the AKS cluster provisioned in SUB-001. These tools form the foundation for all workload delivery. Installation order: Secrets Store CSI Driver → NGINX Gateway Fabric → cert-manager → ArgoCD. All installs use Helm and are driven by a GitHub Actions bootstrap job that runs after `terraform apply` succeeds. Once ArgoCD is operational, subsequent platform updates are managed via ArgoCD Applications.

## 1. Requirements & Constraints

- **REQ-001**: All platform tools installed via Helm from their official chart repositories.
- **REQ-002**: ArgoCD version pinned (no `latest`); refer to the latest stable release at time of implementation.
- **REQ-003**: NGINX Gateway Fabric deployed as the Gateway API controller; deploys a `GatewayClass` named `nginx`.
- **REQ-004**: cert-manager deployed with CRDs installed; `ClusterIssuer` resources created for Let's Encrypt staging and production.
- **REQ-005**: Secrets Store CSI Driver + Azure Key Vault Provider installed; no `VaultStaticSecret` (requires Vault/OpenBao); CSI sync model used exclusively.
- **REQ-006**: Network policy on the `argocd` namespace: allow ingress from `gateway-system` on port 443 (ArgoCD UI exposed via Gateway); allow egress to GitHub (port 443, `0.0.0.0/0` public IPs) for GitOps repo sync.
- **REQ-007**: A shared `Gateway` resource in namespace `gateway-system` is created as a Terraform-output-driven Kubernetes manifest (not via ArgoCD to avoid bootstrapping deadlock). It uses `GatewayClass: nginx` and listens on ports 80 and 443.
- **CON-001**: ArgoCD does not manage itself in its initial installation (bootstrap via Helm avoids circular dependency).
- **CON-002**: `ClusterIssuer` names are `letsencrypt-staging` and `letsencrypt-prod`; these names are referenced by annotations in the OCpenclaw umbrella chart values.
- **CON-003**: Let's Encrypt `letsencrypt-prod` issuer must only be used after HTTP-01 challenge is confirmed working with `letsencrypt-staging` to avoid rate limiting.

## 2. Implementation Steps

### Implementation Phase 1 — Secrets Store CSI Driver + Azure Key Vault Provider

- GOAL-001: Install the Secrets Store CSI Driver and Azure Key Vault Provider on the cluster so pods can consume Key Vault secrets as environment variables.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                             | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-001 | Add a GitHub Actions bootstrap job (runs after `terraform apply`). Step 1: `helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts && helm repo update`. Step 2: `helm upgrade --install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver --namespace kube-system --set syncSecret.enabled=true --set enableSecretRotation=true --wait`. | ✅        | 2026-04-08 |
| TASK-002 | In the same bootstrap job, install the Azure provider: `helm repo add csi-secrets-store-provider-azure https://azure.github.io/secrets-store-csi-driver-provider-azure/charts && helm upgrade --install azure-csi-provider csi-secrets-store-provider-azure/csi-secrets-store-provider-azure --namespace kube-system --set workloadIdentity.subscriptionId=${ARM_SUBSCRIPTION_ID} --wait`.                 | ✅        | 2026-04-08 |
| TASK-003 | Create `workloads/bootstrap/csi-versions.yaml` pinning chart versions used in TASK-001 and TASK-002. Record the full Helm chart version strings (e.g., `secrets-store-csi-driver: 1.4.7`, `csi-secrets-store-provider-azure: 1.5.3`) at the time of implementation. This file is documentation only; bootstrap uses the `--version` flag in Helm commands.                                              | ✅        | 2026-04-08 |

### Implementation Phase 2 — NGINX Gateway Fabric

- GOAL-002: Deploy NGINX Gateway Fabric as the Kubernetes Gateway API controller; creates `GatewayClass` and exposes a LoadBalancer service for external traffic.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                     | Completed | Date |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-004 | Install Gateway API CRDs before NGINX Gateway Fabric: `kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml`. Pin the CRD version at `v1.2.1` (Standard channel); update comment in bootstrap script when upgrading.                                                                                                                                                                                  | ✅        | 2026-04-08 |
| TASK-005 | Install NGINX Gateway Fabric: `helm repo add nginx-gateway-fabric oci://ghcr.io/nginx/charts && helm upgrade --install ngf nginx-gateway-fabric/nginx-gateway-fabric --namespace gateway-system --create-namespace --set service.type=LoadBalancer --set nginxGateway.gwAPIExperimentalFeatures.enable=false --version <pinned-version> --wait`. Pin the version. After install, capture the LoadBalancer external IP: `kubectl get svc -n gateway-system ngf-nginx-gateway-fabric`. | ✅        | 2026-04-08 |
| TASK-006 | Create `workloads/bootstrap/gateway.yaml`: a `Gateway` manifest in namespace `gateway-system` with `gatewayClassName: nginx`. Define two listeners: `http` (port 80, `AllowedRoutes.namespaces.from: All`) for HTTP-01 ACME challenge and HTTP-to-HTTPS redirect; `https` (port 443, protocol: HTTPS, `tls.mode: Terminate`, `tls.certificateRefs` pointing to per-env cert secrets). Apply via `kubectl apply -f workloads/bootstrap/gateway.yaml` in the bootstrap job. | ✅        | 2026-04-08 |
| TASK-007 | Record the Gateway LoadBalancer IP in `workloads/bootstrap/README.md`. Provide instruction: "Set DNS A records for `paa-dev.acmeadventure.ca` → `<dev-lb-ip>` and `paa.acmeadventure.ca` → `<prod-lb-ip>`. Wait for DNS propagation before proceeding to cert-manager ClusterIssuer validation."                                                                                                                                                                 | ✅        | 2026-04-08 |

### Implementation Phase 3 — cert-manager

- GOAL-003: Install cert-manager and configure Let's Encrypt staging and production ClusterIssuers using HTTP-01 ACME challenges.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                            | Completed | Date |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------- | ---- |
| TASK-008 | Install cert-manager with Gateway API feature gate enabled: `helm repo add jetstack https://charts.jetstack.io && helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set installCRDs=true --set "featureGates=ExperimentalGatewayAPISupport=true" --version <pinned-version> --wait`. Pin version at the latest stable v1.x release.              | ✅        | 2026-04-08 |
| TASK-009 | Create `workloads/bootstrap/cluster-issuers.yaml` with two `ClusterIssuer` resources: (1) `letsencrypt-staging`: `server: https://acme-staging-v02.api.letsencrypt.org/directory`, `email: <admin-email-from-variable>`, `privateKeySecretRef.name: letsencrypt-staging-key`, `solvers[0].http01.gatewayHTTPRoute.parentRefs[0]` targeting the `main-gateway` in `gateway-system`. (2) `letsencrypt-prod`: identical structure but `server: https://acme-v02.api.letsencrypt.org/directory` and `privateKeySecretRef.name: letsencrypt-prod-key`. Apply via `kubectl apply -f workloads/bootstrap/cluster-issuers.yaml` in the bootstrap job. | ✅        | 2026-04-08 |
| TASK-010 | Add GitHub secret `TF_VAR_LETSENCRYPT_EMAIL` to both environments. The bootstrap step uses this value as the ACME email contact: `sed -i "s/<admin-email>/${LETSENCRYPT_EMAIL}/" workloads/bootstrap/cluster-issuers.yaml` (or use `envsubst`) before `kubectl apply`. Never hardcode the email in committed manifests.                                                                                  | ✅        | 2026-04-08 |

### Implementation Phase 4 — ArgoCD

- GOAL-004: Install ArgoCD and expose it via the shared Gateway so the UI is accessible at a sub-path. Configure it for GitOps sync of the `workloads/` directory.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                                                                                          | Completed | Date |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-011 | Install ArgoCD: `helm repo add argo https://argoproj.github.io/argo-helm && helm upgrade --install argocd argo/argo-cd --namespace argocd --create-namespace --set server.insecure=true --set "server.extraArgs[0]=--rootpath=/argocd" --version <pinned-version> --wait`. `server.insecure=true` because TLS is terminated at the Gateway; `rootpath=/argocd` to serve the UI under `https://paa-dev.acmeadventure.ca/argocd`.                      | ✅        | 2026-04-08 |
| TASK-012 | Create `workloads/bootstrap/argocd-httproute.yaml`: an `HTTPRoute` in namespace `argocd` routing `paa-dev.acmeadventure.ca/argocd` (and `paa.acmeadventure.ca/argocd` for prod) to the `argocd-server` service on port 80. Set `parentRefs` to the `main-gateway` in `gateway-system`. Apply via `kubectl apply -f workloads/bootstrap/argocd-httproute.yaml` in the bootstrap job.                                                                   | ✅        | 2026-04-08 |
| TASK-013 | Retrieve the initial ArgoCD admin password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`. Store this in the operator's password manager; do not commit it. Immediately rotate via `argocd account update-password` after first login and delete the `argocd-initial-admin-secret`. Document this step in `docs/openclaw-containerapp-operations.md` under a new "AKS Operations" section. | ✅        | 2026-04-08 |
| TASK-014 | Add a `namespace` label to the `argocd` namespace: `kubernetes.io/metadata.name: argocd`. Required for network policy selectors. Create and apply `workloads/bootstrap/argocd-netpol.yaml`: allow ingress from `gateway-system` namespace on port 80 (HTTP from Gateway); allow egress to `0.0.0.0/0` port 443 (GitHub sync) and to `kube-dns` (UDP 53). Block all other ingress.                                                                   | ✅        | 2026-04-08 |

### Implementation Phase 5 — Bootstrap Script Consolidation

- GOAL-005: Consolidate all bootstrap steps into a single idempotent script and integrate with GitHub Actions.

| Task     | Description                                                                                                                                                                                                                                                                                                                                                                            | Completed | Date |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ---- |
| TASK-015 | Create `scripts/bootstrap-aks-platform.sh`. This script accepts `dev` or `prod` as the first argument and executes Phase 1–4 tasks in order using Helm and kubectl commands. The script is idempotent (`helm upgrade --install` is re-runnable). It reads `AKS_CLUSTER_NAME`, `AKS_RESOURCE_GROUP`, `ARM_SUBSCRIPTION_ID`, and `LETSENCRYPT_EMAIL` from environment variables. Never hardcode resource names in the script body; source them from env vars. |           |      |
| TASK-016 | Add a GitHub Actions job `bootstrap-aks-platform` that runs after `terraform apply` in the `terraform-dev` / `terraform-prod` CI jobs. It calls `scripts/bootstrap-aks-platform.sh <env>` after fetching AKS credentials. Gate the job with `needs: [terraform-dev]` (or prod equivalent).                                                                                             |           |      |

## 3. Alternatives

- **ALT-001**: Cilium as CNI + Gateway API control plane — provides richer network policy (BPF-based) but increases cluster complexity significantly; deferred for future enhancement.
- **ALT-002**: Envoy Gateway as Gateway API controller — reference implementation but less mature Helm operability than NGINX Gateway Fabric at time of writing; revisit in H2 2026.
- **ALT-003**: Manage platform tools (ArgoCD, cert-manager) via ArgoCD "App of Apps" — creates a bootstrapping chicken-and-egg problem; initial Helm install avoids this; subsequent updates can be migrated to ArgoCD Applications post-bootstrap.
- **ALT-004**: Separate namespaces per tool vs. shared namespace — each tool gets its own namespace for isolation; `kube-system` reserved for CSI drivers.

## 4. Dependencies

- **DEP-001**: AKS cluster from SUB-001 (feature-aks-infra-1.md) with OIDC issuer enabled and workload identity enabled.
- **DEP-002**: `kubectl` and `helm` CLI available in GitHub Actions runner. Both are pre-installed in the dev container.
- **DEP-003**: `workloads/bootstrap/` directory created in the Git repository to hold manifests.
- **DEP-004**: DNS A records for `paa-dev.acmeadventure.ca` and `paa.acmeadventure.ca` pointing to the Gateway LoadBalancer IP before ClusterIssuer validation (TASK-009 cannot succeed without DNS resolution).

## 5. Files

- **FILE-001**: `scripts/bootstrap-aks-platform.sh` — idempotent bootstrap script
- **FILE-002**: `workloads/bootstrap/gateway.yaml` — shared `Gateway` manifest
- **FILE-003**: `workloads/bootstrap/cluster-issuers.yaml` — Let's Encrypt `ClusterIssuer` manifests (email templated; not-committed with real value)
- **FILE-004**: `workloads/bootstrap/argocd-httproute.yaml` — ArgoCD UI routing
- **FILE-005**: `workloads/bootstrap/argocd-netpol.yaml` — ArgoCD network policy
- **FILE-006**: `workloads/bootstrap/csi-versions.yaml` — pinned chart version reference
- **FILE-007**: `workloads/bootstrap/README.md` — operator step notes including DNS record instruction and initial ArgoCD password procedure
- **FILE-008**: `.github/workflows/terraform.yml` — add `bootstrap-aks-platform` job

## 6. Testing

- **TEST-001**: After TASK-002, run `kubectl get pods -n kube-system -l app=secrets-store-csi-driver` and confirm all pods `Running`.
- **TEST-002**: After TASK-005, run `kubectl get gateway -n gateway-system` and confirm `PROGRAMMED: True`. Run `kubectl get svc -n gateway-system` and confirm an external IP is assigned.
- **TEST-003**: After TASK-008, run `kubectl get pods -n cert-manager` and confirm 3 pods `Running` (cert-manager, cainjector, webhook).
- **TEST-004**: After TASK-009 and DNS propagation, create a test `Certificate` resource targeting `letsencrypt-staging` for `paa-dev.acmeadventure.ca` and confirm `READY: True` within 90 seconds. Delete the test cert after confirmation.
- **TEST-005**: After TASK-011, run `kubectl get pods -n argocd` and confirm all pods `Running`. Access `https://paa-dev.acmeadventure.ca/argocd` and confirm the login page loads (HTTPS, no cert error — staging cert may require browser exception; acceptable at this phase).

## 7. Risks & Assumptions

- **RISK-001**: `featureGates=ExperimentalGatewayAPISupport=true` in cert-manager may change name in future cert-manager versions. Pin cert-manager version; validate gate name against release notes before upgrading.
- **RISK-002**: NGINX Gateway Fabric load balancer provisioning may be slow (Azure public IP allocation). The bootstrap script should include a `--wait` with an adequate timeout (300s) or poll until IP is assigned before proceeding to DNS record creation.
- **RISK-003**: Let's Encrypt staging certs are not trusted by browsers; this is expected. Confirm ACME challenge succeeds before switching to production issuer to avoid rate limiting.
- **ASSUMPTION-001**: The operator has write access to the `acmeadventure.ca` DNS zone to create A records for the subdomain.
- **ASSUMPTION-002**: The AKS cluster's outbound IP is unrestricted (or a known CIDR); required for Let's Encrypt's ACME validation server to reach the cluster's HTTP-01 challenge endpoint on port 80.

## 8. Related Specifications / Further Reading

- [NGINX Gateway Fabric docs](https://docs.nginx.com/nginx-gateway-fabric/)
- [cert-manager Gateway API documentation](https://cert-manager.io/docs/usage/gateway/)
- [Secrets Store CSI Driver](https://secrets-store-csi-driver.sigs.k8s.io/)
- [Azure Key Vault Provider](https://azure.github.io/secrets-store-csi-driver-provider-azure/docs/)
- [ArgoCD Helm chart](https://artifacthub.io/packages/helm/argo/argo-cd)
- [Parent plan: feature-aks-migration-1.md](../plan/feature-aks-migration-1.md)
