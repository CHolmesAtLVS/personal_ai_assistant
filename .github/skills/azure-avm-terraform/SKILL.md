---
name: azure-avm-terraform
description: "Create, update, or review Azure Terraform code using Azure Verified Modules (AVM). WHEN: \"azure avm terraform\", \"use avm\", \"terraform azure module\", \"review terraform avm\", \"convert azure terraform to avm\", \"avm module\", \"azure verified module\"."
license: MIT
metadata:
  author: Microsoft
  version: "1.0.0"
---

# Azure AVM Terraform

Use this skill to implement Azure infrastructure with Azure Verified Modules (AVM) and consistent Terraform practices.

## Workflow

1. Identify the target Azure service/resource.
2. Match to AVM naming pattern (see [Module Discovery](references/discovery.md)):
   - Resource: `Azure/avm-res-{service}-{resource}/azurerm`
   - Pattern: `Azure/avm-ptn-{pattern}/azurerm`
   - Utility: `Azure/avm-utl-{utility}/azurerm`
3. Start from the official module example; replace `source = "../../"` with the registry source.
4. Pin `version` - see [Versioning](references/versioning.md) for lookup approach.
5. Set required inputs, wire outputs, set `enable_telemetry`.
6. Run `terraform fmt` then `terraform validate`.

## Key Rules

- Pin both module and provider versions.
- No secrets in source code or committed variable files.
- Prefer managed identity over embedded credentials.
- Keep changes minimal and declarative.

## Reference Documentation

- [Module Discovery](references/discovery.md) - AVM index, registry lookup, naming conventions
- [Versioning](references/versioning.md) - Module and provider version pinning
- [Best Practices](references/best-practices.md) - Implementation, security, and review checklist
