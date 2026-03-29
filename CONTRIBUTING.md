# Contributing Guidelines

## Scope

This project deploys OpenClaw to Azure Container Apps using Terraform, GitHub Actions, and an Ubuntu-based container image. Keep changes aligned with these architecture choices unless a proposal explicitly changes them.

## Core Contribution Principles

- Keep secrets out of source control, always.
- Treat Terraform as the source of truth for Azure infrastructure.
- Prefer Managed Identity to static credentials.
- Preserve ingress restriction to approved home public IP unless intentionally changed.
- Keep changes small, reviewable, and reversible.
- Never use `latest` or any mutable image tag in Terraform defaults or `.tfvars` examples; always use a pinned version tag.

## What to Update for Typical Changes

- Application behavior changes: update app code and related documentation.
- Image version bump: update the `TF_VAR_OPENCLAW_IMAGE_TAG` GitHub Environment variable to the new pinned tag; open a PR so CI plans and applies only the tag change.
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
- CI/CD workflow updates are syntactically valid
- No secrets are present in committed files
- Architecture/product docs remain accurate
- Service Principal and backend bootstrap workflow changes preserve secret masking and avoid printing sensitive values
- Personal details (including home public IP) are sourced only from GitHub Secrets and never committed
- Image tag changes use a pinned version; `latest` is not present anywhere in Terraform defaults or examples
- Storage and gateway changes verified against `docs/openclaw-containerapp-operations.md` runbook

## Terraform CI/CD Baseline

- Terraform CI uses Service Principal authentication via GitHub environment secrets.
- Terraform deploy workflow is split into `terraform-dev` and `terraform-prod` jobs mapped to `dev` and `prod` GitHub Environments.
- Remote state resources are bootstrapped through Azure CLI before `terraform init`.
- Pull requests must run `terraform fmt`, `terraform validate`, and `terraform plan` and remain plan-only.
- Non-main push events auto-apply in the `terraform-dev` job.
- Apply to production is limited to the `terraform-prod` job on `main` and must remain protected by environment approvals.

## Pull Request Checklist Addendum

- Confirm no personal details, Azure identifiers, or secret values are printed in CI output.

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
