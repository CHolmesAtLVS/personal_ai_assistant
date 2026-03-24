# OpenClaw Project Guidelines

Use these documents as the primary project context:

- [Product functionality](../PRODUCT.md)
- [System architecture](../ARCHITECTURE.md)
- [Contribution standards](../CONTRIBUTING.md)

## Project Context

- OpenClaw is deployed to Azure Container Apps in a private Azure environment.
- Runtime is an Ubuntu-based Docker container.
- Terraform is the authoritative infrastructure mechanism.
- Azure AI Foundry is the LLM backend.
- Access is restricted to the approved home public IP via HTTPS ingress.

## Non-Negotiable Rules

- Never place secrets in source code, workflow files, or committed Terraform variables.
- Treat Azure tenant names, subscription names or IDs, Entra object names or IDs, DNS names, and similar deployment identifiers as secret and avoid reproducing them in docs or generated output.
- Prefer Managed Identity over embedded credentials where supported.
- Preserve IP-restricted ingress and HTTPS unless explicitly asked to change it.
- Keep infrastructure changes declarative in Terraform.

## Implementation Guidance

- Prioritize minimal, focused changes.
- Update documentation when behavior, architecture, or contribution process changes.
- For infrastructure-impacting work, call out effects on security, deployment flow, and operations.
- If requirements are ambiguous, state assumptions explicitly in output.

## Quality and Consistency

- Align suggestions and generated code with architecture decisions in `ARCHITECTURE.md`.
- Align feature behavior suggestions with `PRODUCT.md`.
- Follow process and review expectations in `CONTRIBUTING.md`.

If you detect incomplete or conflicting information across these files, propose specific documentation updates before or alongside code changes.
