---
goal: Migrate OpenClaw from Azure Container Apps to AKS with Helm, ArgoCD, Gateway API, cert-manager, and Let's Encrypt
plan_type: parent
version: 1.0
date_created: 2026-04-08
last_updated: 2026-04-11
owner: Platform
status: 'Completed'
progress: 'SUB-001 ✅ SUB-002 ✅ SUB-003 ✅ SUB-004 ✅'
tags: [feature, migration, aks, kubernetes, helm, argocd, gitops, infrastructure]
---

# Introduction

![Status: Completed](https://img.shields.io/badge/status-Completed-brightgreen) — SUB-001 ✅ SUB-002 ✅ SUB-003 ✅ SUB-004 ✅

Migrate the OpenClaw personal AI assistant from Azure Container Apps (ACA) to Azure Kubernetes Service (AKS). The migration introduces a GitOps delivery model via ArgoCD, Helm-based application packaging using the [serhanekicii/openclaw-helm](https://github.com/serhanekicii/openclaw-helm) chart, Kubernetes Gateway API for ingress, Let's Encrypt + cert-manager for TLS, and Workload Identity + Azure Key Vault CSI for secrets. The ACA instance remains live throughout until AKS is fully validated. ACA decommission is a discrete, final phase.

Target DNS:
- Dev: `paa-dev.acmeadventure.ca`
- Prod: `paa.acmeadventure.ca`

## 1. Requirements & Constraints

- **REQ-001**: AKS free tier; control plane has no additional charge.
- **REQ-002**: 2 worker nodes, VM SKU `Standard_B2s` (2 vCPU, 4 GiB RAM) per node. Note: platform overhead is ~1.5 vCPU / 3 GiB; production workloads may warrant `Standard_B4ms` upgrade post-migration.
- **REQ-003**: ACA instance must remain operational until AKS is fully validated and traffic is confirmed healthy.
- **REQ-004**: Secrets (gateway token, Azure AI API key) remain in Azure Key Vault; no secrets in Git, Helm values, or Kubernetes manifests.
- **REQ-005**: ArgoCD is the sole deployment operator for application workloads on AKS.
- **REQ-006**: Kubernetes Gateway API (not Ingress) for all HTTP/HTTPS routing. No Cloudflare Tunnel.
- **REQ-007**: TLS via cert-manager with Let's Encrypt ACME (HTTP-01 challenge).
- **REQ-008**: DNS hostnames: `paa-dev.acmeadventure.ca` (dev) and `paa.acmeadventure.ca` (prod).
- **REQ-009**: Infrastructure provisioned entirely by Terraform using AVM modules where available.
- **REQ-010**: Workload Identity replaces the Container Apps Managed Identity binding for Key Vault and AI Services access within AKS pods.
- **REQ-011**: Azure Files persistent share (`/home/node/.openclaw`) reused from existing storage account; mounted via Azure Files CSI driver.
- **SEC-001**: Workload Identity with OIDC federation; no static credentials in pods or config.
- **SEC-002**: Azure Key Vault CSI Driver with SecretProviderClass syncs secrets to Kubernetes Secrets. Secrets are never written to Git.
- **SEC-003**: Network policies enabled on all namespaces; ingress restricted via Gateway API network policy allowing only `gateway-system` namespace on port 18789.
- **SEC-004**: AKS control plane access restricted; no public API server endpoint beyond what is required for GitHub Actions CI.
- **CON-001**: Single AKS cluster per environment (dev/prod); no multi-cluster at this stage.
- **CON-002**: `configMode: merge` for the Helm chart (ArgoCD ignores ConfigMap diffs to prevent fight with runtime state).
- **CON-003**: OpenClaw cannot scale horizontally; Deployment replica count is fixed at 1.
- **GUD-001**: All Kubernetes manifests (umbrella charts, ArgoCD Applications, SecretProviderClass) live in `workloads/` directory in Git.
- **GUD-002**: Platform-level tools (ArgoCD, cert-manager, NGINX Gateway Fabric, CSI driver) are bootstrapped via a separate `bootstrap/` Terraform + Helm pipeline, not through an ArgoCD Application managing itself.
- **PAT-001**: Umbrella chart pattern: each environment has its own `workloads/<env>/openclaw/` directory with `Chart.yaml`, `values.yaml`, `crds/`.

## 2. Subplans

| ID      | Subplan File                                                                      | Goal                                                        | Status  |
| ------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------- | ------- |
| SUB-001 | [feature-aks-infra-1.md](../plan/feature-aks-infra-1.md)                         | Terraform: AKS cluster, Workload Identity, AVM modules      | Completed |
| SUB-002 | [feature-aks-platform-1.md](../plan/feature-aks-platform-1.md)                   | K8s platform: ArgoCD, cert-manager, Gateway Fabric, CSI     | Completed |
| SUB-003 | [feature-aks-application-1.md](../plan/feature-aks-application-1.md)             | OpenClaw: umbrella chart, SecretProviderClass, HTTPRoute     | Completed |
| SUB-004 | [feature-aks-decommission-1.md](../plan/feature-aks-decommission-1.md)           | ACA decommission after AKS validation                       | Completed |

## 3. Alternatives

- **ALT-001**: Azure Application Gateway for Containers (AG4C) as Gateway API controller — rejected; more expensive (dedicated gateway resource), AVM module support still maturing, overkill for single-service deployment.
- **ALT-002**: Cloudflare Tunnel for ingress — explicitly excluded per user requirement.
- **ALT-003**: ingress-nginx — rejected; Kubernetes project announced retirement; Gateway API is the forward path.
- **ALT-004**: HashiCorp Vault / OpenBao for secrets — rejected; Azure Key Vault is already deployed and used; the Azure Key Vault CSI Provider integrates directly without introducing a new dependency or additional cost.
- **ALT-005**: DNS-01 ACME challenge — not required since these are non-wildcard hostnames and the cluster will have a publicly routable LoadBalancer IP; HTTP-01 is simpler and more operationally transparent.
- **ALT-006**: `Standard_B4ms` nodes (4 vCPU, 16 GiB) — deferred; user requested small nodes; `Standard_B2s` × 2 provides 4 vCPU / 8 GiB aggregate which is sufficient; upgrade is a one-line Terraform change.
- **ALT-007**: Azure CNI Overlay as AKS network plugin — selected in preference to Kubenet (deprecated) and full Azure CNI (consumes more subnet IPs); supports network policies via Azure Network Policy Manager or Cilium.
- **ALT-008**: Keep ACA and run both ACA + AKS permanently — rejected; the goal is full migration; ACA decommission follows validation.

## 4. Dependencies

- **DEP-001**: Existing Azure Key Vault with `openclaw-gateway-token` and `azure-ai-api-key` secrets — consumed in SUB-001 and SUB-003.
- **DEP-002**: Existing Azure Storage Account + Azure Files share — reused in SUB-001 (RBAC grants) and SUB-003 (CSI mount).
- **DEP-003**: Existing Azure AI Services account — referenced by Workload Identity role assignments in SUB-001.
- **DEP-004**: Existing Managed Identity — extended with OIDC federated credentials in SUB-001.
- **DEP-005**: `acmeadventure.ca` DNS zone — DNS A record for `paa-dev` and `paa` must point to AKS Gateway LoadBalancer IP before Let's Encrypt HTTP-01 challenge can succeed (SUB-002 / SUB-003).
- **DEP-006**: GitHub Actions CI — must have `kubectl` access to AKS cluster for Terraform-driven bootstrap steps.

## 5. Execution Order

- **ORD-001**: SUB-001 (Infra) must complete before SUB-002 (Platform) — AKS cluster must exist before Helm installs.
- **ORD-002**: SUB-002 (Platform) must complete before SUB-003 (Application) — GatewayClass, cert-manager ClusterIssuer, and CSI driver must be present before the OpenClaw ArgoCD Application syncs.
- **ORD-003**: SUB-003 (Application) must be fully validated (pod healthy, HTTPS accessible, AI responses working) before SUB-004 (Decommission) begins.
- **ORD-004**: SUB-001 through SUB-003 may be executed for `dev` first, then repeated for `prod`. Do not decommission prod ACA until prod AKS is validated.

## 6. Risks & Assumptions

- **RISK-001**: `Standard_B2s` nodes may be resource-constrained when running ArgoCD + cert-manager + NGINX Gateway Fabric + OpenClaw + system pods concurrently. Mitigation: monitor node utilization; scale to `Standard_B4ms` if needed (one-line Terraform change).
- **RISK-002**: HTTP-01 Let's Encrypt challenge requires the LoadBalancer IP to be publicly routable and DNS to resolve before cert issuance. Mitigation: use staging Let's Encrypt issuer during dev validation, switch to production issuer for prod.
- **RISK-003**: Azure Files CSI driver must be available on AKS free tier with the configured node pools. Mitigation: Azure Files CSI is built into AKS; validate mount in SUB-003 smoke test.
- **RISK-004**: Workload Identity OIDC token projection may not work correctly if OIDC issuer URL is not properly referenced in the federated credential. Mitigation: validate with `kubectl describe secretproviderclass` and `az keyvault secret show` test in SUB-003.
- **RISK-005**: ACA decommission removes one environment's routing. There is no automatic rollback path once ACA Terraform resources are destroyed. Mitigation: block SUB-004 behind explicit validation gate; keep ACA alive for at least 7 days post-AKS cutover.
- **ASSUMPTION-001**: The `acmeadventure.ca` DNS zone is manageable (records can be added/modified) by the maintainer.
- **ASSUMPTION-002**: The pre-built GHCR image (`ghcr.io/openclaw/openclaw`) runs correctly on AKS nodes; no OS-level or security context blockers.
- **ASSUMPTION-003**: The existing Azure resource group, Key Vault, and storage account are retained and reused; Terraform does not need to destroy and re-create them.

## 7. Related Specifications / Further Reading

- [Serhan Ekici — Deploying OpenClaw on Kubernetes with Helm](https://serhanekici.com/openclaw-helm.html)
- [serhanekicii/openclaw-helm Helm Chart](https://github.com/serhanekicii/openclaw-helm)
- [bjw-s app-template Helm chart](https://github.com/bjw-s/helm-charts)
- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)
- [cert-manager Gateway API integration](https://cert-manager.io/docs/usage/gateway/)
- [Azure Key Vault Provider for Secrets Store CSI Driver](https://azure.github.io/secrets-store-csi-driver-provider-azure/)
- [AKS Workload Identity](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview)
- [AVM AKS module](https://registry.terraform.io/modules/Azure/avm-res-containerservice-managedcluster/azurerm/latest)
- [NGINX Gateway Fabric](https://docs.nginx.com/nginx-gateway-fabric/)
- [ArgoCD Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/)
