# Contributing Guidelines

## Scope

This project deploys OpenClaw to Azure Kubernetes Service (AKS) using Terraform, GitHub Actions, ArgoCD, and an Ubuntu-based container image. Application delivery uses the [serhanekicii/openclaw-helm](https://github.com/serhanekicii/openclaw-helm) Helm chart via an umbrella chart pattern. Keep changes aligned with these architecture choices unless a proposal explicitly changes them.

## Branch Model

- **`dev`** is the integration branch. All PRs — for features, fixes, config changes, Helm values, Terraform, ArgoCD manifests — must target `dev`.
- **`main`** is the production-ready branch. Only a `dev` → `main` PR may target `main`. Direct pushes to `main` are blocked.
- Feature branches are created from `dev` and PR back to `dev`.
- ArgoCD dev tracks the `dev` branch; ArgoCD prod tracks `main`.
- All changes must pass dev deployment and integration tests (`OpenClaw Test Dev`) before the `dev` → `main` promote PR can be merged.

> **Note (RISK-001):** PRs that only touch `workloads/` or `argocd/` (no `terraform/` changes) do not trigger `Terraform Dev` automatically. For workload-only changes, manually trigger `OpenClaw Test Dev` via `workflow_dispatch` before opening the `dev` → `main` promote PR.

## Core Contribution Principles

- Keep secrets out of source control, always.
- Treat Terraform as the source of truth for Azure infrastructure.
- Prefer Managed Identity to static credentials.
- Preserve ingress restriction to approved home public IP unless intentionally changed.
- Keep changes small, reviewable, and reversible.
- Never use `latest` or any mutable image tag in Terraform defaults or `.tfvars` examples; always use a pinned version tag.
- **Never run live diagnostic or operational commands against the production environment when troubleshooting.** Always reproduce and diagnose issues in dev first. This applies to human operators and AI agents equally.

## What to Update for Typical Changes

- Application behavior changes: update app code and related documentation.
- Image version bump: update `image.tag` in `workloads/<env>/openclaw/values.yaml` and open a PR to `dev` so ArgoCD syncs only the tag change. Never use `latest`.
- Infrastructure changes: update Terraform and document impact; open a PR to `dev`.
- Deployment changes: update GitHub Actions workflow, `scripts/bootstrap-aks-platform.sh`, or Helm chart values and document the rollout; open a PR to `dev`.
- Helm values changes: update `workloads/<env>/openclaw/values.yaml` and open a PR to `dev`; ArgoCD will detect and sync automatically after the `dev` → `main` promote.
- ArgoCD Application changes: update `argocd/apps/<env>-openclaw.yaml` and open a PR to `dev`; re-apply via `kubectl apply` or the bootstrap script after sync.

## Environment Safety

All live debugging, troubleshooting, and operational commands must target the **dev** environment unless you are performing an explicit, authorized production incident response where the problem cannot be reproduced in dev.

- AI agents and automated tooling must only be directed against dev resources during troubleshooting sessions. Do not provide production resource group names, Key Vault names, storage account names, app names, or other production identifiers to an AI agent in a debugging context.
- If a production issue cannot be reproduced in dev, document the impasse and explicitly authorize the scope change before proceeding against production.
- Production operations (config seed, secret rotation, image upgrades, ArgoCD sync) are documented in `docs/openclaw-containerapp-operations.md`. Validate all runbook steps in dev before applying to prod.

## Local Troubleshooting

Use `scripts/dump-tf-outputs.sh` to dump all Terraform outputs (including sensitive values) to local files for troubleshooting:

```bash
./scripts/dump-tf-outputs.sh          # both dev and prod
./scripts/dump-tf-outputs.sh dev
./scripts/dump-tf-outputs.sh prod
```

Output is written to `scripts/dev.tfoutputs` and `scripts/prod.tfoutputs`. These files are git-ignored and contain sensitive values in plain text — treat them as secrets and never share or commit them.

Use `scripts/dump-resource-inventory.sh` to query Azure Resource Graph for all resources with a given `managed_by` tag value and write a CSV inventory. Pass your tag value as the first argument (do not commit deployment-identifying values into docs or code). Useful for auditing, cost analysis, and troubleshooting resource presence:

```bash
./scripts/dump-resource-inventory.sh 'YourOrg\your-repo'
```

Output is written to `scripts/resource-inventory.csv`. The file is git-ignored and may contain Azure identifiers — do not share or commit it. Requires an active `az login` session with Reader access to the subscription(s).

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
- Helm values changes validated with `helm dependency build && helm template . --debug` before committing
- For gateway config changes: confirm `gateway.bind` is `lan` (not `loopback`) when deploying to AKS; `loopback` is incompatible with Kubernetes Service/HTTPRoute routing
- `SecretProviderClass` manifests contain only `${VAR}` placeholders; confirm no real Key Vault names, tenant IDs, or client IDs are committed
- ArgoCD Application sync confirmed healthy after merge: `argocd app wait openclaw-<env> --sync --timeout 300`

## Terraform CI/CD Baseline

- Terraform CI uses Service Principal authentication via GitHub environment secrets.
- Terraform deploy workflow is split into `terraform-dev` and `terraform-prod` jobs mapped to `dev` and `prod` GitHub Environments.
- Remote state resources are bootstrapped through Azure CLI before `terraform init`.
- Pull requests must run `terraform fmt`, `terraform validate`, and `terraform plan` and remain plan-only.
- Non-main push events auto-apply in the `terraform-dev` job; followed by `az aks get-credentials` and `scripts/bootstrap-aks-platform.sh dev`.
- Apply to production is limited to the `terraform-prod` job on `main` and must remain protected by environment approvals.

## ArgoCD and Helm Baseline

- All OpenClaw application manifests are delivered via ArgoCD from `workloads/<env>/openclaw/` in this repository.
- ArgoCD is bootstrapped via `scripts/bootstrap-aks-platform.sh` after each `terraform apply`; it is idempotent.
- Umbrella chart dependencies must be updated with `helm dependency build` after changing `Chart.yaml`; commit the resulting `charts/` directory lockfile.
- ArgoCD `syncPolicy.automated.prune: true` and `selfHeal: true` are enabled; direct `kubectl apply` of application manifests is reserved for bootstrapping only.
- `SecretProviderClass`, `PersistentVolume`, and `PersistentVolumeClaim` manifests in `crds/` are applied before ArgoCD sync via the bootstrap script using `envsubst`; they contain only `${VAR}` placeholders in committed form.

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
