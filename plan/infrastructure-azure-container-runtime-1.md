---
goal: Implement Azure Container Apps runtime resources for OpenClaw
version: 1.0
date_created: 2026-03-24
last_updated: 2026-03-24
owner: Platform Engineering
status: 'Planned'
tags: [infrastructure, terraform, azure, container-apps, runtime]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

This child plan provisions Container Apps runtime resources for OpenClaw, including managed environment and application deployment with HTTPS ingress, source-IP restriction, Managed Identity, and ACR image pull configuration.

## 1. Requirements & Constraints

- **REQ-001**: Deploy Container Apps Environment connected to Log Analytics.
- **REQ-002**: Deploy OpenClaw Container App via AVM with single revision mode.
- **REQ-003**: Configure ingress for HTTPS and allow-list source IP from `var.public_ip`.
- **REQ-004**: Configure app image source from ACR and set `AZURE_OPENAI_ENDPOINT` env var.
- **SEC-001**: Keep `allow_insecure_connections = false`.
- **SEC-002**: Use Managed Identity for registry auth.
- **CON-001**: Use output names from upstream modules exactly as documented.
- **PAT-001**: Keep environment and app resources in `terraform/containerapp.tf`.

## 2. Implementation Steps

### Implementation Phase 1

- **GOAL-001**: Provision Container Apps Environment.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-001 | Create `terraform/containerapp.tf` with AVM `Azure/avm-res-app-managedenvironment/azurerm` (`~> 0.3`) and Log Analytics linkage. |  |  |

### Implementation Phase 2

- **GOAL-002**: Provision OpenClaw Container App with required security and connectivity configuration.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-002 | Append AVM `Azure/avm-res-app-containerapp/azurerm` (`~> 0.3`) with user-assigned identity attachment. |  |  |
| TASK-003 | Configure ingress external endpoint with target port, HTTPS-only behavior, and IP restriction from `var.public_ip`. |  |  |
| TASK-004 | Configure container image `${module.acr.login_server}/openclaw:${var.container_image_tag}` and environment variable `AZURE_OPENAI_ENDPOINT = module.ai_services.endpoint`. |  |  |
| TASK-005 | Configure registry block to authenticate to ACR using managed identity resource ID. |  |  |

## 3. Alternatives

- **ALT-001**: Use inline `azurerm_container_app` resources; rejected due to AVM-first requirement.
- **ALT-002**: Allow all ingress and rely on app auth; rejected due to network control guardrails.

## 4. Dependencies

- **DEP-001**: [plan/infrastructure-azure-foundation-1.md](infrastructure-azure-foundation-1.md) complete.
- **DEP-002**: [plan/infrastructure-azure-security-registry-1.md](infrastructure-azure-security-registry-1.md) complete.
- **DEP-003**: [plan/infrastructure-azure-ai-platform-1.md](infrastructure-azure-ai-platform-1.md) complete.

## 5. Files

- **FILE-001**: `terraform/containerapp.tf`

## 6. Testing

- **TEST-001**: `terraform plan` includes Container Apps Environment and Container App resources.
- **TEST-002**: Runtime ingress configuration enforces HTTPS and source IP restriction.
- **TEST-003**: Container app template resolves image and environment settings from module outputs.

## 7. Risks & Assumptions

- **RISK-001**: Incorrect module output name for shared key or FQDN can fail plan/apply.
- **ASSUMPTION-001**: OpenClaw process listens on configured target port.

## 8. Related Specifications / Further Reading

- [infrastructure-azure-resources-deployment-2.md](infrastructure-azure-resources-deployment-2.md)
- [infrastructure-azure-foundation-1.md](infrastructure-azure-foundation-1.md)
- [infrastructure-azure-security-registry-1.md](infrastructure-azure-security-registry-1.md)
- [infrastructure-azure-ai-platform-1.md](infrastructure-azure-ai-platform-1.md)
- [ARCHITECTURE.md](../ARCHITECTURE.md)
