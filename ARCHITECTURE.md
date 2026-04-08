# OpenClaw Architecture

## System Overview

This project deploys OpenClaw from a public GitHub repository into Azure Kubernetes Service (AKS) in a private Azure environment. The runtime is the pre-built Ubuntu-based container image from GHCR. Infrastructure is defined and managed through Terraform. The application's LLM backend is Azure AI Foundry. Application delivery uses a GitOps model via ArgoCD and the [serhanekicii/openclaw-helm](https://github.com/serhanekicii/openclaw-helm) Helm chart.

> **Migration status:** The target runtime is AKS. The Azure Container Apps (ACA) runtime is being retired. See [plan/feature-aks-migration-1.md](plan/feature-aks-migration-1.md) for the phased migration plan.

Core architecture goals:

- Keep deployment repeatable and auditable through Infrastructure as Code
- Keep credentials out of source control
- Use managed Azure identity where possible
- Limit application exposure via HTTPS and DNS-scoped ingress through Kubernetes Gateway API
- Maintain GitOps delivery: all application state declared in Git, reconciled by ArgoCD

## Logical Components

### Source and Build

- Public GitHub repository
- OpenClaw runtime sourced from the pre-built public image at `ghcr.io/openclaw/openclaw`, pinned to an explicit version tag
- Terraform configuration for Azure resources
- GitHub Actions for CI/CD orchestration (Terraform-only; no container build step)

Image versioning is controlled by the `openclaw_image_tag` Terraform variable. The `latest` tag is explicitly rejected by a Terraform variable validation rule.

### Terraform Delivery Path

- GitHub Actions authenticates to Azure with a Service Principal provided through GitHub environment secrets
- Terraform deploy workflow is split into explicit `dev` and `prod` jobs mapped to GitHub Environments with independent approvals and secret scopes
- The `terraform-dev` job triggers on pull request events (opened, synchronize, reopened) targeting `main`; the `terraform-prod` job triggers on pull request merged to `main`
- Azure CLI bootstraps Terraform remote state infrastructure (Resource Group, Storage Account, Blob Container) before Terraform backend initialization
- Terraform uses Azure Blob remote state for shared, auditable infrastructure state
- Resource naming and required tags are centralized in Terraform locals for consistent policy enforcement
- After `terraform apply`, CI runs `az aks get-credentials` and the `scripts/bootstrap-aks-platform.sh` script to install cluster-level platform tools

### Azure Runtime Platform

- **AKS cluster** (free tier, 2 × `Standard_B2s` nodes, Azure CNI Overlay): runtime environment for all containerized workloads. One system node pool and one workload node pool.
- **OpenClaw Deployment**: single-replica pod running the pre-built image `ghcr.io/openclaw/openclaw` at the pinned version tag. Managed by ArgoCD via the umbrella Helm chart in `workloads/<env>/openclaw/`.
- **NGINX Gateway Fabric**: implements Kubernetes Gateway API (`GatewayClass: nginx`); provides a shared external LoadBalancer for HTTPS routing to all workloads including OpenClaw.
- **Kubernetes Gateway API `HTTPRoute`**: routes `paa-dev.acmeadventure.ca` (dev) and `paa.acmeadventure.ca` (prod) to the OpenClaw service on port 18789.
- **cert-manager + Let's Encrypt**: TLS certificates issued via HTTP-01 ACME challenge; `letsencrypt-staging` used during dev validation, `letsencrypt-prod` for trusted certs.
- **ArgoCD**: GitOps operator running in the `argocd` namespace; continuously reconciles `workloads/<env>/openclaw/` from this repository to the cluster. `configMode: merge` preserves runtime config state across pod restarts.
- **Azure Files NFS share** (Premium FileStorage storage account) mounted at `/home/node/.openclaw`: persists all long-lived OpenClaw state (config, auth profiles, skills state, workspace files) across pod restarts and redeployments. NFS protocol required for POSIX `chmod`/`chown` semantics.
- **Secrets Store CSI Driver + Azure Key Vault Provider**: syncs `openclaw-gateway-token` and `azure-ai-api-key` from Key Vault into a Kubernetes `Secret` (`openclaw-env-secret`) via `SecretProviderClass`. No secret material in Git or Helm values.
- **Workload Identity**: the OpenClaw pod's Kubernetes ServiceAccount is annotated with the Managed Identity client ID; OIDC federation allows the pod to exchange a projected token for the MI token, enabling Key Vault and AI Services access without static credentials.
- **Gateway token auth**: OpenClaw gateway runs with `bind=lan` (required for Gateway API routing — loopback is incompatible with Service/HTTPRoute access) and token authentication. Token sourced from Key Vault via CSI sync.
- **Network policies**: enabled per the Helm chart's built-in network policy block; ingress from `gateway-system` namespace on port 18789 only; egress to public internet for AI API calls; internal RFC1918 egress blocked.
- **Log Analytics Workspace**: centralized telemetry sink for the AKS cluster diagnostics and Key Vault diagnostics.
- **Azure Monitor Action Group + Consumption Budget**: cost alerts at 50 %, 80 %, 100 % actual, and 110 % forecasted thresholds against the environment resource group.

### Resource Group Topology

- **Environment resource group** (`${project}-${environment}-rg`): deployed in every environment; holds Key Vault, AI platform, AKS cluster, Managed Identity, Log Analytics Workspace, Premium storage account (NFS share), and budget resources.
- **Shared resource group** (`${project}-shared-rg`): deployed in prod only; holds the single Azure Container Registry shared across the project.

### Security and Configuration

- Managed Identity: preferred authentication path to Azure services; a single User-Assigned Managed Identity is attached to the AKS cluster and federated via OIDC to the `openclaw` Kubernetes ServiceAccount (Workload Identity)
- Azure Key Vault (RBAC mode, admin-disabled): secret values outside code; legacy access policies disabled; secrets accessed from pods via Secrets Store CSI Driver without static credentials
- Runtime configuration: non-secret settings (e.g. `AZURE_OPENAI_ENDPOINT`, `APP_FQDN`) injected as container environment variables via Helm values; secrets injected via `SecretProviderClass` CSI sync → Kubernetes Secret → pod `envFrom`
- AI authentication: Managed Identity is used where supported (Azure OpenAI embedding endpoint via `Cognitive Services OpenAI User` role). The Azure AI Model Inference endpoint (used for Grok/xAI MaaS models) does not yet support Managed Identity in OpenClaw's `azure-foundry` provider; it uses an API key stored in Key Vault (`azure-ai-api-key`) and injected at runtime via CSI secret sync. Managed Identity coverage for that endpoint is a planned improvement.
- The Azure AI Foundry API key must be provided on every Terraform apply via `TF_VAR_azure_ai_api_key` (GitHub Secret: `TF_VAR_AZURE_AI_API_KEY`); the `lifecycle { ignore_changes = [value] }` rule prevents the Key Vault secret value from being overwritten, but Terraform variable validation still runs and will reject an empty value.

#### Managed Identity Role Assignments

| Role | Scope | Environment |
| ---- | ----- | ----------- |
| AcrPull | Shared ACR | prod only |
| Key Vault Secrets User | Environment Key Vault | all |
| Cognitive Services OpenAI User | AI Services account | all |
| Cognitive Services User | AI Services account | all |
| Storage File Data NFS Share Contributor | Premium NFS Azure Files share | all |

### AI and Observability

- Azure AI Services account (Cognitive Services) with an AI Foundry Hub and Project: provides the LLM model deployment endpoint consumed by OpenClaw
- Model deployments: `text-embedding-3-large` (embeddings, Azure OpenAI endpoint); `gpt-5.4-mini` (primary chat, version `2026-03-17`) via the Azure OpenAI endpoint.
- Primary chat model: `gpt-5.4-mini` — set via `agents.defaults.model.primary` in openclaw config; no fallback configured
- Log Analytics Workspace (`${project}-${environment}-law`): 30-day retention; receives diagnostics from Key Vault, ACR (prod), and the AKS cluster

### Resource Inventory

#### Environment resource group (`${project}-${environment}-rg`) — all environments

| Resource | AVM Module | Notes |
| -------- | ---------- | ----- |
| Resource Group | `avm-res-resources-resourcegroup` | |
| Log Analytics Workspace | `avm-res-operationalinsights-workspace` | 30-day retention |
| User-Assigned Managed Identity | `avm-res-managedidentity-userassignedidentity` | OIDC federated to `system:serviceaccount:openclaw:openclaw` |
| Key Vault (standard, RBAC mode) | `avm-res-keyvault-vault` | Diagnostics → LAW; holds `openclaw-gateway-token` and `azure-ai-api-key` |
| AI Services / AI Foundry Hub + Project + model deployment | `avm-ptn-aiml-ai-foundry` | Uses existing Key Vault |
| AKS Cluster (free tier, 2 × `Standard_B2s`) | `avm-res-containerservice-managedcluster ~> 0.5` | Azure CNI Overlay; OIDC issuer; Workload Identity; KV Secrets Provider add-on |
| Premium Storage Account (FileStorage) + NFS Azure Files share | `azurerm_storage_account` / `azurerm_storage_share` | NFS protocol; persists `/home/node/.openclaw`; POSIX chmod/chown support |
| OIDC Federated Identity Credential | `azurerm_federated_identity_credential` | Binds MI to `openclaw` K8s ServiceAccount for Workload Identity |
| Monitor Action Group | `azurerm_monitor_action_group` | Budget email alerts |
| Consumption Budget | `azurerm_consumption_budget_resource_group` | Monthly cap on env RG |

#### Shared resource group (`${project}-shared-rg`) — prod only

| Resource | AVM Module | Notes |
| -------- | ---------- | ----- |
| Shared Resource Group | `avm-res-resources-resourcegroup` | |
| Azure Container Registry (Standard) | `avm-res-containerregistry-registry` | Admin disabled; Diagnostics → LAW |

### Terraform Outputs

| Output | Description | Sensitive |
| ------ | ----------- | --------- |
| `aks_cluster_name` | Name of the deployed AKS cluster | no |
| `aks_oidc_issuer_url` | OIDC issuer URL for Workload Identity federation | yes |
| `aks_node_resource_group` | Node resource group created by AKS | no |
| `ai_services_endpoint` | Endpoint URL of the AI Services account | yes |
| `acr_login_server` | ACR login server (null in non-prod) | yes |
| `openclaw_state_storage_account_name` | Premium storage account name hosting the NFS Azure Files share | no |
| `openclaw_state_file_share_name` | NFS Azure Files share name mounted to `/home/node/.openclaw` | no |

## End-to-End Deployment and Runtime Flow

1. A change is pushed to the public GitHub repository (Terraform or Helm values/charts).
2. GitHub Actions applies Terraform to provision or update Azure resources: AKS cluster, Key Vault, AI Services, storage, Managed Identity, OIDC federation.
3. CI fetches AKS credentials and runs `scripts/bootstrap-aks-platform.sh` to install/upgrade platform tools: Secrets Store CSI Driver, Azure Key Vault Provider, NGINX Gateway Fabric, cert-manager (with ClusterIssuers), ArgoCD.
4. ArgoCD detects the updated `workloads/<env>/openclaw/` directory in Git and syncs the umbrella Helm chart.
5. The Helm chart deploys the OpenClaw `Deployment`, `Service`, `ConfigMap`, `PVC`, `ServiceAccount`, and network policies.
6. The Secrets Store CSI volume mount triggers Key Vault secret sync → `openclaw-env-secret` Kubernetes Secret is created/updated.
7. The NFS Azure Files share is mounted at `/home/node/.openclaw`, restoring all persistent state.
8. OpenClaw starts with `gateway.bind=lan`, reads `OPENCLAW_GATEWAY_TOKEN` from the synced secret, and begins accepting connections.
9. A user connects over HTTPS from `paa-dev.acmeadventure.ca` or `paa.acmeadventure.ca`; the NGINX Gateway Fabric routes the request via `HTTPRoute` to the OpenClaw service on port 18789.
10. OpenClaw authenticates to Azure AI Foundry via Workload Identity (Managed Identity OIDC token exchange) where supported; the Grok inference endpoint uses the CSI-synced API key.
11. Operational telemetry flows to Log Analytics Workspace; cost alerts fire via the Consumption Budget.

Terraform workflow details:

1. CI selects the environment job: `terraform-dev` on PR opened/synchronize/reopened targeting `main`; `terraform-prod` on PR merged to `main`.
2. CI runs an idempotent Azure CLI bootstrap script for backend state resources.
3. CI runs `terraform fmt -check`, `terraform init`, `terraform validate`, `terraform plan`.
4. CI uploads the environment-specific plan artifact (both jobs).
5. CI auto-applies in the `terraform-dev` job after plan succeeds; fetches AKS kubeconfig; runs platform bootstrap.
6. CI applies in the `terraform-prod` job only on merge to `main`, subject to GitHub Environment protection controls.

## Trust Boundaries and Access Model

- Public boundary: GitHub repository and the public HTTPS endpoint
- Controlled ingress boundary: `HTTPRoute` allows all source IPs but TLS-terminates at the Gateway; the gateway token provides authentication at the application layer
- Cloud identity boundary: Workload Identity through Managed Identity OIDC federation; no static credentials in pods
- Secret boundary: sensitive values stored in Azure Key Vault, synced to Kubernetes Secrets via CSI Driver only at pod runtime; never committed to Git or Helm values

This model intentionally reduces blast radius for a public codebase deployment while preserving a straightforward operational path.

## Infrastructure Ownership and Change Model

- Terraform is the authoritative mechanism for provisioning and infrastructure updates.
- GitHub Actions is the deployment entry point for infrastructure changes and platform bootstrap.
- ArgoCD is the authoritative GitOps operator for application workloads on AKS.
- AKS is the authoritative runtime for serving OpenClaw.

This gives a single declarative infrastructure source (Terraform), a single CI/CD execution layer (GitHub Actions), a GitOps application delivery layer (ArgoCD), and a managed container runtime (AKS).

## Security Principles Applied

- No secrets committed to source control
- Secrets managed in Azure-hosted secret services
- Managed Identity favored over embedded credentials
- Public ingress restricted to one approved source IP
- HTTPS used for encrypted client access
- Terraform-based deployments for consistency and traceability
- Azure deployment identifiers such as tenant names, subscription names or IDs, Entra object names, and DNS names are treated as secret operational metadata

## Assumptions and Constraints

- OpenClaw runs correctly on AKS with `gateway.bind=lan` and the official security context (UID 1000, `readOnlyRootFilesystem`, drop ALL capabilities)
- Azure AI Foundry is the selected LLM platform
- DNS for `paa-dev.acmeadventure.ca` and `paa.acmeadventure.ca` is managed by the operator and points to the AKS Gateway LoadBalancer IP
- Terraform remains the source of truth for Azure resource state
- ArgoCD remains the source of truth for Kubernetes application state

## Operational Environment Policy

The two deployed environments (`dev`, `prod`) exist specifically to separate change-risk from production traffic.

- **All troubleshooting, diagnosis, and live operational work must be performed against the dev environment.** Production is only touched for authorized deployment or incident response where the issue is confirmed non-reproducible in dev.
- This rule applies to human operators and to AI agents. An AI agent must never be provided production resource identifiers (resource group, Key Vault, storage account, AKS cluster name, ArgoCD application name) in a debugging context. If there is any ambiguity about which environment is targeted, the agent must stop and ask before executing any `az`, `kubectl`, Terraform, or script command.
- Production incidents are an exception, not a default. Explicitly document the authorization to work in prod before executing any live commands.

## Planned Evolution

Recommended next enhancements:

- Automated backup — Azure Files share snapshots and Blob export scheduled via Terraform or a container sidecar
- Authentication layer in front of OpenClaw (in addition to gateway token auth)
- Container image scanning in CI pipeline
- Monitoring alerts for availability and failed-request signals
- Managed Identity coverage for the Azure AI Model Inference endpoint (Grok) once OpenClaw provider support is available
- AKS node autoscaling or vertical pod autoscaling as workload grows
