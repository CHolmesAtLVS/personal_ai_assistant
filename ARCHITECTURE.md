# OpenClaw Architecture

## System Overview

This project deploys multiple isolated OpenClaw instances from a public GitHub repository into Azure Kubernetes Service (AKS) in a private Azure environment. Each instance serves a named individual and runs in its own Kubernetes namespace with dedicated persistent storage, managed identity, and gateway token. All instances share the AKS cluster, AI Services endpoint, Key Vault, and Log Analytics workspace to keep infrastructure costs proportional to active usage. Infrastructure is defined and managed through Terraform. Application delivery uses a GitOps model via ArgoCD and the [serhanekicii/openclaw-helm](https://github.com/serhanekicii/openclaw-helm) Helm chart.

The set of deployed instances per environment is controlled by the `openclaw_instances` Terraform variable, stored in the environment's central tfvars file in Azure Blob Storage. Adding or removing an instance is a single-line change to that file followed by a Terraform apply.

Core architecture goals:

- Keep deployment repeatable and auditable through Infrastructure as Code
- Keep credentials out of source control
- Use managed Azure identity where possible
- Limit application exposure via HTTPS and DNS-scoped ingress through Kubernetes Gateway API
- Maintain GitOps delivery: all application state declared in Git, reconciled by ArgoCD
- Isolate instances from one another at the namespace, storage, identity, and secret levels

## Logical Components

### Source and Build

- Public GitHub repository
- OpenClaw runtime sourced from the pre-built public image at `ghcr.io/openclaw/openclaw`, pinned to an explicit version tag
- Terraform configuration for Azure resources
- GitHub Actions for CI/CD orchestration (Terraform-only; no container build step)

Image versioning is controlled by the `openclaw_image_tag` Terraform variable. The `latest` tag is explicitly rejected by a Terraform variable validation rule.

### Terraform Delivery Path

- GitHub Actions authenticates to Azure with a Service Principal provided through GitHub environment secrets (credentials only — non-sensitive config lives in the central tfvars file)
- Before each Terraform run, CI downloads the environment's central tfvars file from Azure Blob Storage (`{TFSTATE_CONTAINER}/tfvars/{env}.auto.tfvars`) and places it in the `terraform/` directory; Terraform loads it automatically
- Terraform deploy workflow is split into explicit `dev` and `prod` jobs mapped to GitHub Environments with independent approvals and secret scopes
- The `terraform-dev` job triggers on pull request events (opened, synchronize, reopened) targeting `main`; the `terraform-prod` job triggers on pull request merged to `main`
- Azure CLI bootstraps Terraform remote state infrastructure (Resource Group, Storage Account, Blob Container) before Terraform backend initialization
- Terraform uses Azure Blob remote state for shared, auditable infrastructure state
- Resource naming and required tags are centralized in Terraform locals for consistent policy enforcement
- After `terraform apply`, CI runs `az aks get-credentials` and the `scripts/bootstrap-aks-platform.sh` script to install cluster-level platform tools
- CI then runs `scripts/seed-openclaw-aks.sh` for each instance in `openclaw_instances`, creating per-instance namespace, ServiceAccount, SecretProviderClass, ConfigMap, and ArgoCD Application

### GitHub Secrets

Only true credentials and sensitive values are stored in GitHub Secrets. All non-sensitive configuration is stored in the central tfvars file.

| Secret | Purpose | Stays in Secrets |
|---|---|---|
| `AZURE_TENANT_ID` | SP login + CSI Driver tenant binding | Yes — deployment identifier |
| `AZURE_SUBSCRIPTION_ID` | SP login + az account set | Yes — deployment identifier |
| `AZURE_CLIENT_ID` | SP login | Yes — deployment identifier |
| `AZURE_CLIENT_SECRET` | SP credential | Yes — true secret |
| `TFSTATE_STORAGE_ACCOUNT` | Backend init + tfvars download | Yes — needed before tfvars available |
| `TFSTATE_RG` | Backend bootstrap | Yes — needed before tfvars available |
| `TFSTATE_CONTAINER` | Backend init + tfvars download | Yes — needed before tfvars available |
| `TFSTATE_LOCATION` | Backend bootstrap | Yes — needed before tfvars available |
| `PUBLIC_IP` | Ingress IP restriction; CI exports it to Terraform as `TF_VAR_public_ip` | Yes — sensitive |
| `BUDGET_ALERT_EMAIL` | Cost alert delivery | Yes — sensitive |
| `TF_VAR_AZURE_AI_API_KEY` | AI API key bootstrap | Yes — true secret |

All other previously-stored variables (`TF_VAR_PROJECT`, `TF_VAR_LOCATION`, `TF_VAR_OWNER`, `TF_VAR_COST_CENTER`, model names and versions, image tag, quota, budget amount, `TF_VAR_OPENCLAW_INSTANCES`) are stored in the central tfvars file and no longer appear in GitHub Secrets or GitHub Variables.

### Azure Runtime Platform

#### Shared Infrastructure (per environment)

- **AKS cluster** (free tier, 2 × `Standard_B2s` nodes, Azure CNI Overlay): shared runtime for all OpenClaw instances in the environment. One system node pool and one workload node pool. All instances schedule pods on this cluster.
- **NGINX Gateway Fabric**: implements Kubernetes Gateway API (`GatewayClass: nginx`); provides a shared external LoadBalancer with one HTTPS listener per instance, using neutral hostname patterns such as `https-{instance}-{env}` → `{instance}.{env-domain}`.
- **cert-manager + Let's Encrypt**: TLS certificates issued per instance hostname via HTTP-01 ACME challenge.
- **Key Vault** (RBAC mode): one vault per environment holding all instance secrets, named with per-instance prefix (e.g. `ch-openclaw-gateway-token`). Shared `azure-ai-api-key` used by all instances.
- **AI Services / AI Foundry**: one account and endpoint per environment, shared across all instances. Each instance's config points to the same endpoint.
- **Log Analytics Workspace**: centralized telemetry sink shared by all instances in the environment.
- **Premium FileStorage storage account**: one storage account per environment; each instance gets a dedicated NFS share (`openclaw-{instance}-nfs`) mounted at `/home/node/.openclaw` in its pod.
- **ArgoCD**: single operator per cluster; manages one Application per instance (`{instance}-openclaw-{env}`).

#### Per-Instance Resources (one set per entry in `openclaw_instances`)

Each instance `{inst}` in the `openclaw_instances` list produces the following isolated resources:

| Resource | Name pattern | Isolation boundary |
|---|---|---|
| Kubernetes namespace | `openclaw-{inst}` | All K8s resources for the instance |
| User-Assigned MI | `{project}-{env}-{inst}-id` | Scoped to this instance's service account only |
| OIDC federated credential | `openclaw-aks-{env}-{inst}` | Subject: `system:serviceaccount:openclaw-{inst}:openclaw` |
| Key Vault secret | `{inst}-openclaw-gateway-token` | Token unique to this instance |
| Azure Files NFS share | `openclaw-{inst}-nfs` | Persistent state isolated from other instances |
| Kubernetes ServiceAccount | `openclaw` in `openclaw-{inst}` | Annotated with this instance's MI client ID |
| SecretProviderClass | `openclaw-kv` in `openclaw-{inst}` | Syncs `{inst}-openclaw-gateway-token` + shared AI key |
| ConfigMap `openclaw-env-config` | `openclaw-{inst}` namespace | Instance endpoint + app FQDN |
| NetworkPolicy | `openclaw-{inst}` namespace | Ingress from `gateway-system` only; no cross-instance traffic |
| HTTPS Gateway listener | `https-{inst}-{env}` | Hostname: `{inst}.{env-domain}` |
| HTTPRoute | `openclaw-{inst}-https` | Routes HTTPS traffic to instance service port 18789 |
| ArgoCD Application | `{inst}-openclaw-{env}` | Tracks `workloads/{env}/openclaw-{inst}/` |
| Role: KV Secrets User | Environment Key Vault | Scoped to this instance's MI |
| Role: Storage Account Contributor | NFS storage account | Scoped to this instance's MI |
| Role: Cognitive Services OpenAI User | AI Services account | Scoped to this instance's MI |

#### OpenClaw Pod (per instance)

- Image: `ghcr.io/openclaw/openclaw:{tag}` (pinned, never `latest`)
- Single-replica Deployment; resource requests sized for `Standard_B2s` nodes (`requests: {cpu: 100m, memory: 256Mi}`, `limits: {cpu: 500m, memory: 512Mi}`)
- NFS share mounted at `/home/node/.openclaw` via PV/PVC backed by `azureFile` CSI driver
- Secrets injected via CSI volume → `openclaw-env-secret` → pod `envFrom`
- Non-sensitive config injected via `openclaw-env-config` ConfigMap → pod `envFrom`
- Security context: UID 1000, `readOnlyRootFilesystem: true`, drop ALL capabilities
- Network isolation: `NetworkPolicy` blocks all cross-namespace traffic; allows only inbound from `gateway-system` on port 18789

#### Workloads Directory Structure

```
workloads/
  bootstrap/
    gateway.yaml          — Gateway with per-instance listeners (one entry per instance per env)
    cluster-issuers.yaml
    ...
  dev/
    openclaw-ch/          — Instance "ch" dev
      Chart.yaml
      values.yaml
      bootstrap/          — envsubst templates: SA, SecretProviderClass, ConfigMap, HTTPRoute
      crds/               — PV for NFS share
    openclaw-jh/          — Instance "jh" dev
      ...
  prod/
    openclaw-ch/          — Instance "ch" prod
    openclaw-jh/
    openclaw-kjm/         — Instance "kjm" prod only
```

ArgoCD Application manifests live in `argocd/apps/{env}-openclaw-{inst}.yaml`.

### Resource Group Topology

- **Environment resource group** (`${project}-${environment}-rg`): deployed in every environment; holds Key Vault, AI platform, AKS cluster, Log Analytics Workspace, Premium storage account (NFS shares for all instances), and budget resources. All per-instance Managed Identities also live here.
- **Shared resource group** (`${project}-shared-rg`): deployed in prod only; holds the single Azure Container Registry shared across the project.

### Central Terraform Variables File

Non-sensitive Terraform input variables are stored in an `.auto.tfvars` file in Azure Blob Storage alongside the Terraform state file:

| Blob path | Environment | Loaded by |
|---|---|---|
| `{TFSTATE_CONTAINER}/tfvars/dev.auto.tfvars` | dev | CI (downloaded before `terraform init`) |
| `{TFSTATE_CONTAINER}/tfvars/prod.auto.tfvars` | prod | CI (downloaded before `terraform init`) |

The file contains all non-secret variables: `project`, `environment`, `location`, `owner`, `cost_center`, model names/versions/capacities, `openclaw_image_tag`, `openclaw_state_share_quota_gb`, `monthly_budget_amount`, and `openclaw_instances`. CI downloads the file using the Terraform state storage account credentials already available in GitHub Secrets and places it at `terraform/{env}.auto.tfvars` before running Terraform commands.

`scripts/terraform-local.sh` downloads the central tfvars file from Blob Storage before running Terraform locally, using `az storage blob download` authenticated via the existing CLI session.

The `dev.tfvars` file in `scripts/` is reduced to only the credentials and bootstrap variables required before the central tfvars is available:
- SP credentials (`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`)
- `TFSTATE_*` variables
- `TF_VAR_public_ip`, `BUDGET_ALERT_EMAIL`, `TF_VAR_azure_ai_api_key`

### Security and Configuration

- Managed Identity: each instance has its own User-Assigned Managed Identity; OIDC-federated to `system:serviceaccount:openclaw-{inst}:openclaw`; no credential sharing between instances
- Azure Key Vault (RBAC mode, admin-disabled): one vault per environment; per-instance secrets use `{inst}-` prefix; shared `azure-ai-api-key` accessed by all instance MIs
- Runtime configuration: non-secret settings (e.g. `AZURE_OPENAI_ENDPOINT`, `APP_FQDN`) injected as container environment variables via per-instance ConfigMap; secrets injected via per-instance `SecretProviderClass` CSI sync → Kubernetes Secret → pod `envFrom`
- AI authentication: Managed Identity is used where supported (Azure OpenAI embedding endpoint via `Cognitive Services OpenAI User` role). The Azure AI Model Inference endpoint uses an API key stored in Key Vault (`azure-ai-api-key`) and injected at runtime via CSI secret sync. Managed Identity coverage for that endpoint is a planned improvement.

#### Managed Identity Role Assignments (per instance)

Each instance MI receives these role assignments:

| Role | Scope | Notes |
| ---- | ----- | ----- |
| Key Vault Secrets User | Environment Key Vault | Access scoped to this MI only |
| Storage Account Contributor | Premium NFS storage account | NFS mount enumeration |
| Cognitive Services OpenAI User | AI Services account | Shared endpoint, per-instance MI |
| Cognitive Services User | AI Services account | Shared endpoint, per-instance MI |
| AcrPull | Shared ACR (prod only) | One assignment per instance in prod |

### AI and Observability

- Azure AI Services account (Cognitive Services) with an AI Foundry Hub and Project: provides the LLM model deployment endpoint consumed by all OpenClaw instances in the environment
- Model deployments: `text-embedding-3-large` (embeddings, Azure OpenAI endpoint); `gpt-5.4-mini` (primary chat, version `2026-03-17`) via the Azure OpenAI endpoint. All instances share these deployments.
- Primary chat model: `gpt-5.4-mini` — set via `agents.defaults.model.primary` in openclaw config
- Log Analytics Workspace (`${project}-${environment}-law`): 30-day retention; receives diagnostics from Key Vault, ACR (prod), and the AKS cluster

### Resource Inventory

#### Environment resource group (`${project}-${environment}-rg`) — all environments

| Resource | AVM Module | Notes |
| -------- | ---------- | ----- |
| Resource Group | `avm-res-resources-resourcegroup` | |
| Log Analytics Workspace | `avm-res-operationalinsights-workspace` | 30-day retention; shared |
| User-Assigned Managed Identity × N | `avm-res-managedidentity-userassignedidentity` | One per instance; OIDC federated to `system:serviceaccount:openclaw-{inst}:openclaw` |
| Key Vault (standard, RBAC mode) | `avm-res-keyvault-vault` | Shared; per-instance secrets prefixed `{inst}-` |
| AI Services / AI Foundry Hub + Project + model deployment | `avm-ptn-aiml-ai-foundry` | Shared across all instances |
| AKS Cluster (free tier, 2 × `Standard_B2s`) | `avm-res-containerservice-managedcluster ~> 0.5` | Shared; Azure CNI Overlay; OIDC issuer; Workload Identity; KV Secrets Provider add-on |
| Premium Storage Account (FileStorage) | `azurerm_storage_account` | Shared; NFS protocol; one share per instance |
| Azure Files NFS share × N | `azurerm_storage_share` | Per instance: `openclaw-{inst}-nfs`; mounted at `/home/node/.openclaw` |
| OIDC Federated Identity Credential × N | `azurerm_federated_identity_credential` | One per instance; binds MI to instance K8s ServiceAccount |
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
| `nfs_storage_account_name` | Storage account name hosting all instance NFS shares | no |
| `instance_mi_client_ids` | Map of `{instance} → MI client ID` for OIDC seeding | yes |
| `instance_nfs_share_names` | Map of `{instance} → NFS share name` | no |
| `kv_name` | Key Vault name for bootstrap scripts | yes |

## End-to-End Deployment and Runtime Flow

1. A change is pushed to the public GitHub repository (Terraform, Helm values, tfvars in Blob, or new instance directory).
2. CI downloads the environment's central tfvars file from Azure Blob Storage and places it at `terraform/{env}.auto.tfvars`.
3. GitHub Actions applies Terraform to provision or update Azure resources: AKS cluster, Key Vault, AI Services, NFS storage account, and **for each instance** in `openclaw_instances`: MI, OIDC federated credential, NFS share, Key Vault secret, and role assignments.
4. CI fetches AKS credentials and runs `scripts/bootstrap-aks-platform.sh` to install/upgrade platform tools: Secrets Store CSI Driver, Azure Key Vault Provider, NGINX Gateway Fabric (with updated per-instance Gateway listeners), cert-manager (with ClusterIssuers), ArgoCD.
5. CI runs `scripts/seed-openclaw-aks.sh {env} {inst}` for each instance in `openclaw_instances`, creating the `openclaw-{inst}` namespace and applying bootstrap manifests (ServiceAccount, SecretProviderClass, ConfigMap, HTTPRoute).
6. ArgoCD detects the updated `workloads/{env}/openclaw-{inst}/` directory in Git and syncs the umbrella Helm chart for each instance.
7. Each Helm chart deploys an OpenClaw `Deployment`, `Service`, `ConfigMap`, `PVC`, `ServiceAccount`, and NetworkPolicy in the `openclaw-{inst}` namespace.
8. The Secrets Store CSI volume mount triggers Key Vault secret sync → `openclaw-env-secret` Kubernetes Secret is created/updated per instance.
9. The NFS Azure Files share (`openclaw-{inst}-nfs`) is mounted at `/home/node/.openclaw` for each pod, restoring all persistent state.
10. OpenClaw starts with `gateway.bind=lan`, reads `OPENCLAW_GATEWAY_TOKEN` from the synced secret, and begins accepting connections.
11. A user connects over HTTPS to `{inst}.{env-domain}`; the NGINX Gateway Fabric routes the request via the per-instance `HTTPRoute` to `openclaw-{inst}` service on port 18789.
12. OpenClaw authenticates to Azure AI Foundry via Workload Identity (per-instance MI OIDC token exchange).
13. Operational telemetry flows to the shared Log Analytics Workspace; cost alerts fire via the Consumption Budget.

Terraform workflow details:

1. CI selects the environment job: `terraform-dev` on PR opened/synchronize/reopened targeting `main`; `terraform-prod` on PR merged to `main`.
2. CI downloads `{TFSTATE_STORAGE_ACCOUNT}/{TFSTATE_CONTAINER}/tfvars/{env}.auto.tfvars` to `terraform/{env}.auto.tfvars`.
3. CI runs an idempotent Azure CLI bootstrap script for backend state resources.
4. CI runs `terraform fmt -check`, `terraform init`, `terraform validate`, `terraform plan`.
5. CI uploads the environment-specific plan artifact (both jobs).
6. CI auto-applies in the `terraform-dev` job after plan succeeds; fetches AKS kubeconfig; runs platform bootstrap and per-instance seeding.
7. CI applies in the `terraform-prod` job only on merge to `main`, subject to GitHub Environment protection controls.

## Trust Boundaries and Access Model

- Public boundary: GitHub repository and the public HTTPS endpoints (one per instance)
- Controlled ingress boundary: per-instance `HTTPRoute` routes to the correct namespace; the gateway token provides authentication at the application layer
- Cloud identity boundary: Workload Identity through per-instance Managed Identity OIDC federation; no static credentials in pods; no MI shared between instances
- Secret boundary: per-instance sensitive values stored in Azure Key Vault (prefixed by instance name), synced to per-instance Kubernetes Secrets via CSI Driver only at pod runtime; never committed to Git or Helm values
- Cross-instance isolation: NetworkPolicy blocks all pod-to-pod traffic across `openclaw-*` namespaces; each pod can only receive from `gateway-system` and egress to the internet

This model intentionally reduces blast radius for a public codebase deployment while preserving a straightforward operational path. A compromised instance pod cannot reach secrets or storage belonging to another instance.

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
- Azure AI Foundry is the selected LLM platform; the endpoint is shared across all instances
- DNS for each instance hostname (`{inst}.{dev-domain}`, `{inst}.{prod-domain}`) is managed by the operator and points to the AKS Gateway LoadBalancer IP (all instance hostnames resolve to the same IP)
- Terraform remains the source of truth for Azure resource state; `openclaw_instances` is the single authoritative list of deployed instances
- ArgoCD remains the source of truth for Kubernetes application state
- The central tfvars file in Azure Blob Storage is the authoritative source for all non-secret Terraform inputs; it must be updated before adding or removing instances
- Standard_B2s nodes (2 vCPU, 4 GB RAM) support up to ~10 simultaneous OpenClaw pods within safe headroom at the configured resource requests; resize or add nodes if active instances exceed this

## Operational Environment Policy

The two deployed environments (`dev`, `prod`) exist specifically to separate change-risk from production traffic.

- **All troubleshooting, diagnosis, and live operational work must be performed against the dev environment.** Production is only touched for authorized deployment or incident response where the issue is confirmed non-reproducible in dev.
- This rule applies to human operators and to AI agents. An AI agent must never be provided production resource identifiers (resource group, Key Vault, storage account, AKS cluster name, ArgoCD application name) in a debugging context. If there is any ambiguity about which environment is targeted, the agent must stop and ask before executing any `az`, `kubectl`, Terraform, or script command.
- Production incidents are an exception, not a default. Explicitly document the authorization to work in prod before executing any live commands.

## Planned Evolution

Recommended next enhancements:

- Automated backup — per-instance Azure Files share snapshots and Blob export scheduled via Terraform or a container sidecar
- Authentication layer in front of OpenClaw (in addition to gateway token auth)
- Container image scanning in CI pipeline
- Monitoring alerts per instance for availability and failed-request signals
- Managed Identity coverage for the Azure AI Model Inference endpoint (Grok) once OpenClaw provider support is available
- AKS node autoscaling or vertical pod autoscaling as instance count or workload grows
