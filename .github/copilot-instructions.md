# OpenClaw Project Guidelines

Use these documents as the primary project context:

- [Product functionality](../PRODUCT.md): Describe the product features, user experience, and high-level design goals. This is the primary source for understanding what the product does and how it should behave.  Technical details should be limited.
- [System architecture](../ARCHITECTURE.md): Describe the system's architectural design, including components, interactions, and technology choices. This is the primary source for understanding how the product is built and how its parts fit together.
- [Contribution standards](../CONTRIBUTING.md): Describe the contribution process, coding standards, review expectations, and other guidelines for contributing to the project. This is the primary source for understanding how to contribute effectively and in alignment with project norms.

## Project Context

- OpenClaw is deployed to AKS (Azure Kubernetes Service) in a private Azure environment, managed by ArgoCD.
- Runtime is an Ubuntu-based Docker container.
- Terraform is the authoritative infrastructure mechanism.
- Azure AI Foundry is the LLM backend.
- Ingress is IP-restricted HTTPS via NGINX Gateway Fabric; preserve these controls unless explicitly asked to change them.
- **Branch model:** `dev` is the integration branch. PRs target `dev`. Only a `dev` → `main` PR promotes to production. AI agents must generate PRs targeting `dev` unless explicitly asked to create a production promote PR (`dev` → `main`).

## Non-Negotiable Rules

- Never place secrets in source code, workflow files, or committed Terraform variables.
- Treat Azure tenant names, subscription names or IDs, Entra object names or IDs, DNS names, and similar deployment identifiers as secret and avoid reproducing them in docs or generated output.
- Prefer Managed Identity over embedded credentials where supported.
- Preserve IP-restricted ingress and HTTPS unless explicitly asked to change it.
- Keep infrastructure changes declarative in Terraform.
- **All troubleshooting, diagnosis, and live operational commands (`az`, Terraform, scripts) must target the dev environment only. Never execute commands against production resources during a troubleshooting or debugging session.** If the target environment is ambiguous, ask for explicit confirmation before running any command. This rule applies equally to AI agents and to human operators.
- Never accept or use production resource identifiers (resource group names, Key Vault names, storage account names, app names) when the intent is to diagnose a problem. Require the user to provide dev equivalents, or surface the ambiguity and stop.

## OpenClaw Configuration Preferences

- Always reference environment variables explicitly in `openclaw.json` using `${VAR_NAME}` substitution (e.g. `"token": "${OPENCLAW_GATEWAY_TOKEN}"`, `"apiKey": "${CUSTOM_API_KEY}"`). This makes the mapping between env vars and config values clear and auditable.
- For openclaw CLI usage (connecting to the remote gateway, diagnostics, config changes, device pairing): load the `openclaw-cli` skill (`.github/skills/openclaw-cli/SKILL.md`). The local CLI is preferred over `kubectl exec ...` when an AKS fallback is required.
- OpenClaw security is paramount. For any configuration changes that could impact security (e.g. changing ingress from private to public, modifying authentication settings, altering network rules), explicitly call out the security implications in the output and require confirmation before proceeding.

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
