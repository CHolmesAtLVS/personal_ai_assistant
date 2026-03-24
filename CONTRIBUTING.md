# Contributing Guidelines

## Scope

This project deploys OpenClaw to Azure Container Apps using Terraform, GitHub Actions, and an Ubuntu-based container image. Keep changes aligned with these architecture choices unless a proposal explicitly changes them.

## Core Contribution Principles

- Keep secrets out of source control, always.
- Treat Terraform as the source of truth for Azure infrastructure.
- Prefer Managed Identity to static credentials.
- Preserve ingress restriction to approved home public IP unless intentionally changed.
- Keep changes small, reviewable, and reversible.

## What to Update for Typical Changes

- Application behavior changes: update app code and related documentation.
- Runtime/dependency changes: update Dockerfile and verify container build.
- Infrastructure changes: update Terraform and document impact.
- Deployment changes: update GitHub Actions workflow and rollout notes.

## Security Requirements

- Do not commit secrets, keys, tokens, or sensitive connection strings.
- Treat Azure tenant names, subscription names or IDs, Entra object names or IDs, DNS names, and similar deployment identifiers as secret.
- Use Azure-managed secret stores for sensitive values.
- Verify no credentials are introduced in code, workflow files, Terraform vars, or logs.
- Verify documentation and examples do not expose deployment-identifying Azure metadata.
- Keep HTTPS and source-IP ingress restrictions intact by default.

## Pull Request Expectations

Include the following in every PR:

- Purpose and summary of the change
- Affected areas (app, container, Terraform, CI/CD)
- Validation steps and results
- Security impact statement (especially for auth, networking, secret handling)
- Documentation updates when behavior or operations changed

## Validation Checklist

Before requesting review:

- Terraform changes are formatted and validated
- Container image builds successfully
- CI/CD workflow updates are syntactically valid
- No secrets are present in committed files
- Architecture/product docs remain accurate

## Documentation Discipline

If your change modifies behavior, operational flow, or architecture assumptions, update:

- `ARCHITECTURE.md`
- `PRODUCT.md`
- `CONTRIBUTING.md` (if process/policy changed)
- `.github/copilot-instructions.md` (if AI guidance should change)

## Proposed Enhancements

When proposing larger evolution (custom domain, auth layer, environment split, scanning, alerts), document:

- Problem statement and expected value
- Security and operational implications
- Required Terraform and CI/CD changes
- Migration or rollback considerations
