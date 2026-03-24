# OpenClaw Product

## Product Purpose

OpenClaw provides a web interface for interacting with an LLM powered by Azure AI Foundry. The product is deployed as a containerized service on Azure Container Apps and exposed via HTTPS with strict source IP access control.

The current product goal is secure, private, single-user access from a known home network while preserving cloud-native deployment and operational practices.

## Primary User and Access Model

### Primary User

- The home user who operates OpenClaw from an approved public IP address

### Access Constraints

- The service is internet-reachable only through HTTPS ingress
- Ingress is allow-listed to the user's home public IP only
- Requests from non-approved source IP addresses are denied

This provides a simple but effective protection boundary for a public endpoint.

## Functional Capabilities

### 1. LLM Interaction

- Accepts user prompts via the OpenClaw web interface
- Sends prompt requests to a configured Azure AI Foundry model endpoint
- Returns model responses to the user interface

### 2. Cloud-Native Runtime

- Runs OpenClaw in an Ubuntu-based Docker container
- Hosts the container in Azure Container Apps
- Pulls application images from Azure Container Registry

### 3. Secure Configuration Handling

- Uses Managed Identity when Azure services support it
- Stores secrets outside source code in Azure-managed secret stores
- Injects non-secret settings at runtime rather than hardcoding

### 4. Observability

- Emits operational logs and telemetry to Azure monitoring services
- Supports troubleshooting and health visibility through centralized logs

## Non-Functional Requirements

- Security: no secret material in public repository artifacts
- Reliability: managed Azure runtime and repeatable deployments
- Maintainability: Terraform as Infrastructure as Code source of truth
- Traceability: CI/CD-driven deployments through GitHub Actions
- Network control: HTTPS ingress constrained to approved source IP
- Privacy of deployment metadata: do not expose Azure tenant, subscription, identity object, or DNS identifiers in public-facing project docs

## Product Workflow

1. Maintainer updates app code, Docker config, or Terraform in GitHub.
2. CI/CD builds and publishes a new container image.
3. Terraform applies infrastructure changes where needed.
4. Container Apps runs the updated OpenClaw service.
5. User accesses the web interface from approved home IP.
6. OpenClaw processes prompt/response cycles through Azure AI Foundry.
7. Logs and diagnostics are available in Azure monitoring.

## Out of Scope (Current State)

- Multi-tenant or organization-wide access
- Built-in federated user authentication
- Separate production lifecycle environments (dev/prod split)
- Custom domain and managed certificate setup

These are planned growth options, not current baseline requirements.

## Product Guardrails

- Public repository is allowed, but never for secret storage
- Prefer identity-based service auth over static credentials
- Keep infrastructure changes declarative and reviewable
- Restrict exposure first, then incrementally add convenience features

## Near-Term Roadmap

1. Add custom domain and managed TLS certificate.
2. Add authentication layer in front of OpenClaw.
3. Introduce dev/prod environment split.
4. Add image scanning in CI pipeline.
5. Add alerting for availability and failed-request signals.
