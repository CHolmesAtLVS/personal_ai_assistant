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
- OpenClaw application code
- Dockerfile for Ubuntu-based image
- Terraform configuration for Azure resources
- GitHub Actions for CI/CD orchestration

### Terraform Delivery Path

- GitHub Actions authenticates to Azure with a Service Principal provided through GitHub environment secrets
- Terraform deploy workflow is split into explicit `dev` and `prod` jobs mapped to GitHub Environments with independent approvals and secret scopes
- Azure CLI bootstraps Terraform remote state infrastructure (Resource Group, Storage Account, Blob Container) before Terraform backend initialization
- Terraform uses Azure Blob remote state for shared, auditable infrastructure state
- Resource naming and required tags are centralized in Terraform locals for consistent policy enforcement

### Azure Runtime Platform

- Azure Container Registry (ACR): stores built container images; lives in a dedicated shared resource group (`${project}-shared-rg`) provisioned only in the prod environment. Dev deployments use a public placeholder image and have no ACR dependency.
- Azure Container Apps Environment: runtime environment for containerized workloads
- OpenClaw Container App: running service endpoint
- HTTPS ingress with source IP restriction to the user's home public IP

### Resource Group Topology

- **Environment resource group** (`${project}-${environment}-rg`): deployed in every environment; holds Key Vault, AI platform, Container Apps Environment, Container App, Managed Identity, and Log Analytics Workspace.
- **Shared resource group** (`${project}-shared-rg`): deployed in prod only; holds the single Azure Container Registry shared across the project.

### Security and Configuration

- Managed Identity: preferred authentication path to Azure services
- Azure Key Vault and/or Azure-hosted secret stores: secret values outside code
- Runtime configuration injection: non-secret settings injected at deployment/runtime

### AI and Observability

- Azure AI Foundry project and model deployment endpoint used by OpenClaw
- Log Analytics / Azure monitoring for logs, telemetry, and diagnostics

## End-to-End Deployment and Runtime Flow

1. A change is pushed to the public GitHub repository (app code, Docker config, or Terraform).
2. GitHub Actions builds an Ubuntu-based OpenClaw container image.
3. GitHub Actions pushes the image to ACR (prod only; dev deployments use a public placeholder image).
4. GitHub Actions applies Terraform to provision or update Azure resources in the private Azure environment.
5. Azure Container Apps pulls the image from ACR and runs the OpenClaw container.
6. A user connects over HTTPS from the approved home public IP.
7. OpenClaw authenticates to Azure services via Managed Identity where supported.
8. OpenClaw calls Azure AI Foundry's configured LLM deployment endpoint.
9. Operational telemetry and diagnostics flow to Azure monitoring.

Terraform workflow details:

1. CI selects the explicit environment job (`dev` for non-main refs, `prod` for `main`) and loads that environment's secrets and variables.
2. CI runs an idempotent Azure CLI bootstrap script for backend state resources.
3. CI runs `terraform fmt -check`, `terraform init`, `terraform validate`, `terraform plan`.
4. CI uploads the environment-specific plan artifact for pull requests (plan-only).
5. CI auto-applies in the `dev` job on non-main push events.
6. CI applies in the `prod` job only on push to `main` with protected environment controls.

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

## Planned Evolution

Recommended next enhancements:

- Custom domain mapping for Container App
- Azure-managed TLS certificate for the custom domain
- Front-door authentication layer (basic or federated)
- Separate dev and prod environments
- Container image scanning in CI
- Monitoring alerts for availability and failed requests
