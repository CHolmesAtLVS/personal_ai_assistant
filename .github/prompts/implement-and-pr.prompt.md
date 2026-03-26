---
description: "Implement a task, branch if on main, push changes, open a PR, monitor workflows, and report when ready for review."
argument-hint: "Describe the task to implement, e.g. Add Key Vault soft-delete configuration"
agent: "agent"
tools: [search, read, edit, run_in_terminal, github_repo]
---

Implement the following task: **$ARGUMENTS**

## Step 1 — Branch check

Check the current git branch.  Use 'git remote -v' to confirm the current repository and ensure it's the expected one.

- If on `main`, derive a short, descriptive branch name from the task (e.g. `feat/add-keyvault-soft-delete` or `fix/acr-sku-typo`), then create and switch to that branch.
- If already on a feature branch, continue with the existing branch.

## Step 2 — Understand context

Before writing any code:

1. Read the relevant files to understand existing patterns.
2. Consult project documentation in [ARCHITECTURE.md](../../ARCHITECTURE.md), [PRODUCT.md](../../PRODUCT.md), and [CONTRIBUTING.md](../../CONTRIBUTING.md) if the task touches architecture, product behavior, or contribution conventions.
3. Check [docs/secrets-inventory.md](../../docs/secrets-inventory.md) if the task involves credentials or secrets.

## Step 3 — Implement

Make the minimal, focused changes required.

Follow all non-negotiable project rules:
- No secrets in source code, workflow files, or committed Terraform variables.
- Prefer Managed Identity over embedded credentials.
- Keep infrastructure changes declarative in Terraform (`terraform/`).
- Preserve IP-restricted ingress and HTTPS unless explicitly asked to change it.
- Do not add unnecessary documentation, comments, or abstractions.

## Step 4 — Validate

Run any locally executable checks appropriate to the changes:

| Change type | Validation |
|---|---|
| Terraform | In `terraform/`: run `terraform fmt -check`, then `terraform init` (or `terraform init -upgrade` if you changed provider or module versions), then `terraform validate` |
| Shell scripts | `shellcheck <file>` |
| General | Lint tools already configured in the repo |

Fix any errors before proceeding.

## Step 5 — Commit and push

Stage all changed files. Write a concise, conventional commit message that describes what changed and why. Push the branch.

## Step 6 — Open a pull request

Create a PR targeting `main` using `gh pr create` with:
- **Title**: concise summary matching the commit message
- **Body**: what changed, why, and any deployment or operational considerations
- Do not include secrets, tenant names, subscription IDs, or other deployment identifiers in the PR body.

## Step 7 — Monitor workflows

After the PR is created:

1. Check that the `Terraform Deploy` workflow (`.github/workflows/terraform-deploy.yml`) was triggered.
2. Poll the workflow run status using `gh run list` and `gh run view` until runs complete or fail.
3. If a run fails, fetch the failed job logs with `gh run view --log-failed` and diagnose the root cause.
4. Fix any failures, commit, and push. Repeat until all checks pass.

## Step 8 — Report

When all workflow checks pass, report:
- PR URL
- Branch name
- Summary of changes made
- Any assumptions or caveats the reviewer should know about
