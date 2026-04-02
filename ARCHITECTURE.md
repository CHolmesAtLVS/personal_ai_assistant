# OpenClaw Architecture

## System Overview

This project deploys OpenClaw from a public GitHub repository into Azure Container Apps in a private Azure environment. The runtime is an Ubuntu-based Docker container. Infrastructure is defined and managed through Terraform. The application's LLM backend is Azure AI Foundry.

Core architecture goals:

- Keep deployment repeatable and auditable through Infrastructure as Code
- Keep credentials out of source control
- Use managed Azure identity where possible
- Limit application exposure by allowing ingress only from a specific home public IP

## Logical Components

### Source and Build

- Public GitHub repository
- OpenClaw runtime sourced from the pre-built public image at `ghcr.io/openclaw/openclaw`, pinned to an explicit version tag
- Terraform configuration for Azure resources
- GitHub Actions for CI/CD orchestration (Terraform-only; no container build step)

Image versioning is controlled by the `openclaw_image_tag` Terraform variable. The `latest` tag is explicitly rejected by a Terraform variable validation rule.

### Terraform Delivery Path

- GitHub Actions applies Terraform on every PR (dev) and on merge to `main` (prod), using environment-scoped secrets and independent approval gates
- Azure CLI bootstraps remote state infrastructure before Terraform initializes
- Terraform uses Azure Blob remote state; resource naming and tags are centralized in locals for consistent policy enforcement

### Azure Runtime Platform

- Azure Container Registry (ACR): stores built container images; lives in a dedicated shared resource group (`${project}-shared-rg`) provisioned only in the prod environment. Dev deployments use a public placeholder image and have no ACR dependency. ACR is reserved for custom-built image scenarios; standard deployment uses the pre-built GHCR image.
- Azure Container Apps Environment: runtime environment for containerized workloads, linked to Log Analytics Workspace
- OpenClaw Container App: running service endpoint; min replicas 0, 2 vCPU / 4 GiB per replica; pulls pre-built image from `ghcr.io/openclaw/openclaw` at the pinned tag
- Azure Files share mounted at `/home/node/.openclaw`: persists all long-lived OpenClaw state (config, auth profiles, skills state, workspace files) across revisions and restarts
- Gateway token auth: the OpenClaw gateway runs with `bind=lan` and token authentication; the token is stored in Key Vault under the canonical secret name `openclaw-gateway-token` and injected into the container at startup via Managed Identity secret reference
- HTTPS ingress with source IP restriction to the user's home public IP; insecure connections blocked
- Liveness probe at `/healthz:18789` and readiness probe at `/readyz:18789` for Container Apps health management
- Log Analytics Workspace: centralized telemetry sink for Container Apps Environment, Key Vault diagnostics, and ACR diagnostics
- Azure Monitor Action Group + Consumption Budget: cost alerts at 50 %, 80 %, 100 % actual, and 110 % forecasted thresholds against the environment resource group

### Resource Group Topology

- **Environment resource group** (`${project}-${environment}-rg`): deployed in every environment; holds Key Vault, AI platform, Container Apps Environment, Container App, Managed Identity, and Log Analytics Workspace.
- **Shared resource group** (`${project}-shared-rg`): deployed in prod only; holds the single Azure Container Registry shared across the project.

### Security and Configuration

- A single User-Assigned Managed Identity is attached to the Container App and is the preferred authentication path to all Azure services
- Azure Key Vault (RBAC mode): stores all runtime secrets; legacy access policies disabled
- Non-secret settings are injected as container environment variables by Terraform at deploy time
- Secrets are injected via Managed Identity secret references — no credentials are hardcoded or committed to source control
- Where Managed Identity is not yet supported by the AI provider, an API key is stored in Key Vault and injected at runtime; Managed Identity coverage is a planned improvement

#### Managed Identity Role Assignments

| Role | Scope | Environment |
| ---- | ----- | ----------- |
| AcrPull | Shared ACR | prod only |
| Key Vault Secrets User | Environment Key Vault | all |
| Cognitive Services OpenAI User | AI Services account | all |
| Cognitive Services User | AI Services account | all |

### AI and Observability

- Azure AI Services account with an AI Foundry Hub and Project provides the LLM endpoint consumed by OpenClaw
- Multiple model deployments are configured: an embeddings model and one or more chat models; see [docs/baseline-configuration.md](docs/baseline-configuration.md) for current model assignments
- Log Analytics Workspace: 30-day retention; receives diagnostics from Key Vault, ACR (prod), and the Container Apps Environment

### Resource Inventory

#### Environment resource group (`${project}-${environment}-rg`) — all environments

| Resource | Notes |
| -------- | ----- |
| Resource Group | |
| Log Analytics Workspace | 30-day retention; telemetry sink for all environment resources |
| User-Assigned Managed Identity | Attached to the Container App; used for Key Vault and AI Services access |
| Key Vault (standard, RBAC mode) | Holds gateway token and AI API key secrets |
| AI Services / AI Foundry Hub + Project | LLM endpoint and model deployments |
| Container Apps Environment | Linked to Log Analytics Workspace |
| Container App (OpenClaw) | HTTPS, IP-restricted ingress; gateway token injected via Key Vault secret ref |
| Azure Storage Account + Files share | Persists `/home/node/.openclaw`; also hosts backup Blob exports |
| Container Apps Environment Storage binding | Mounts the Files share into the Container App |
| Monitor Action Group | Budget alert notifications |
| Consumption Budget | Monthly spend cap on the environment resource group |

#### Shared resource group (`${project}-shared-rg`) — prod only

| Resource | Notes |
| -------- | ----- |
| Shared Resource Group | |
| Azure Container Registry (Standard) | Admin disabled; diagnostics → Log Analytics Workspace |

## End-to-End Deployment and Runtime Flow

1. A change is pushed to the public GitHub repository (app code, Docker config, or Terraform).
2. GitHub Actions applies Terraform to provision or update Azure resources in the private Azure environment.
3. Azure Container Apps pulls the pre-built OpenClaw image from `ghcr.io/openclaw/openclaw` at the pinned tag and runs the container.
4. The Azure Files share hosting `/home/node/.openclaw` is mounted into the container, restoring all persistent state.
5. The Container App reads the `openclaw-gateway-token` Key Vault secret via Managed Identity and starts the gateway with token authentication.
6. A user connects over HTTPS from the approved home public IP.
7. OpenClaw authenticates to Azure services via Managed Identity where supported.
8. OpenClaw calls Azure AI Foundry's configured LLM deployment endpoint.
9. Operational telemetry and diagnostics flow to Azure monitoring.

See [docs/openclaw-containerapp-operations.md](docs/openclaw-containerapp-operations.md) for detailed Terraform CI workflow steps and bootstrap procedures.

## Trust Boundaries and Access Model

- Public boundary: GitHub repository and the public HTTPS endpoint
- Controlled ingress boundary: Container App ingress allows only the approved source IP
- Cloud identity boundary: workload identity through Managed Identity
- Secret boundary: sensitive values stored in Azure-managed secret stores, not in repository history

This model intentionally reduces blast radius for a public codebase deployment while preserving a straightforward operational path.

## Infrastructure Ownership and Change Model

- Terraform is the authoritative mechanism for provisioning and infrastructure updates.
- GitHub Actions is the deployment entry point for image publish and infrastructure changes.
- Azure Container Apps is the authoritative runtime for serving OpenClaw.

This gives a single declarative infrastructure source, a single CI/CD execution layer, and a managed container runtime.

## Security Principles Applied

- No secrets committed to source control
- Secrets managed in Azure-hosted secret services
- Managed Identity favored over embedded credentials
- Public ingress restricted to one approved source IP
- HTTPS used for encrypted client access
- Terraform-based deployments for consistency and traceability
- Azure deployment identifiers such as tenant names, subscription names or IDs, Entra object names, and DNS names are treated as secret operational metadata

## Assumptions and Constraints

- OpenClaw runs correctly in Azure Container Apps
- Azure AI Foundry is the selected LLM platform
- Home public IP is stable, or ingress rules can be updated when it changes
- Terraform remains the source of truth for Azure resource state

## Operational Environment Policy

The two deployed environments (`dev`, `prod`) exist specifically to separate change-risk from production traffic.

- **All troubleshooting, diagnosis, and live operational work must be performed against the dev environment.** Production is only touched for authorized deployment or incident response where the issue is confirmed non-reproducible in dev.
- This rule applies to human operators and to AI agents. An AI agent must never be provided production resource identifiers (resource group, Key Vault, storage account, Container App name) in a debugging context. If there is any ambiguity about which environment is targeted, the agent must stop and ask before executing any `az`, Terraform, or script command.
- Production incidents are an exception, not a default. Explicitly document the authorization to work in prod before executing any live commands.

## Planned Evolution

Recommended next enhancements:

- Custom domain mapping for Container App
- Azure-managed TLS certificate for the custom domain
- Front-door authentication layer (basic or federated)
- Separate dev and prod environments
- Container image scanning in CI
- Monitoring alerts for availability and failed requests
