---
goal: Build OpenClaw container with dynamic Key Vault secret injection as environment variables
version: 1.0
date_created: 2026-03-24
last_updated: 2026-03-24
owner: Platform Engineering
status: 'Planned'
tags: [feature, container, docker, github-actions, keyvault, secrets, managed-identity, acr]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

This plan builds the OpenClaw container image and implements a dynamic Key Vault secret injection pattern whereby all secrets stored in Azure Key Vault are loaded as environment variables at container startup using Managed Identity — with zero secret names documented anywhere in the repository. It follows [infrastructure-azure-resources-deployment-1.md](infrastructure-azure-resources-deployment-1.md), which provisioned the Key Vault, ACR, Container App, and Managed Identity.

**Core secret injection design**: A Python loader script (`scripts/load_secrets.py`) runs as the container entrypoint. It authenticates to Key Vault using the workload's Managed Identity (`DefaultAzureCredential`), enumerates every secret in the vault dynamically via `list_properties_of_secrets()`, fetches each value, and injects all of them as environment variables before `exec`-ing the OpenClaw process. This means:
- No secret names exist in any repository file.
- New secrets added to Key Vault are automatically available on next container restart with no code or Terraform changes.
- Secret rotation in Key Vault is immediately effective on the next container revision.

## 1. Requirements & Constraints

- **REQ-001**: Build the OpenClaw container image from an Ubuntu 24.04 base, consistent with the architecture definition.
- **REQ-002**: The container entrypoint must dynamically load all secrets from Azure Key Vault using Managed Identity and inject them as environment variables before starting the OpenClaw process.
- **REQ-003**: Secret names must not appear in any repository file, workflow file, Terraform file, or documentation. The Key Vault is the sole authoritative record of secret names and values.
- **REQ-004**: Implement a GitHub Actions CI workflow that builds, tags, and pushes the container image to ACR on changes to application or container source files.
- **REQ-005**: Container images must be tagged with the full Git SHA as the primary immutable tag. The `latest` tag may also be pushed but must never be the sole tag.
- **REQ-006**: After a successful image push, the CI workflow must trigger the Terraform deployment workflow with the exact Git SHA image tag to deploy the new revision.
- **REQ-007**: The Terraform Container App definition must inject two non-secret configuration values: `AZURE_KEY_VAULT_NAME` (vault name, sourced from `local.kv_name`) and `AZURE_CLIENT_ID` (Managed Identity client ID, sourced from `module.managed_identity.client_id`). These are configuration, not secrets.
- **REQ-008**: Provide an operator guide for adding and rotating secrets in Key Vault manually. The guide must define a secret naming convention and operational procedure without listing actual secret names.
- **SEC-001**: The loader script must use `ManagedIdentityCredential` with the explicit `client_id` of the User-Assigned Managed Identity. Do not rely on system-assigned identity or ambient credential chain beyond the intended identity.
- **SEC-002**: The loader script must not log, print, or write any secret value to stdout, stderr, or any file at any point.
- **SEC-003**: All Key Vault operations in the loader script must propagate exceptions to stderr and exit non-zero on failure; a container that cannot load secrets must not start.
- **SEC-004**: ACR admin credentials must remain disabled; image push from CI uses Service Principal authentication only.
- **SEC-005**: The Dockerfile must not contain any `ENV`, `ARG`, or `RUN` instruction that embeds a secret value. The only secrets present at container runtime are those loaded from Key Vault by the entrypoint.
- **CON-001**: Changes to `terraform/containerapp.tf` (from plan 2 TASK-013) are the only Terraform file modifications in this plan. All other Terraform files from plans 1 and 2 are unchanged.
- **CON-002**: The loader script must handle Key Vault secret names containing hyphens, underscores, and mixed case. It must normalize each name to `UPPER_SNAKE_CASE` for the environment variable name (replace `-` with `_`, uppercase all characters).
- **CON-003**: The loader script must skip secrets that are disabled or in a non-enabled state in Key Vault without failing.
- **GUD-001**: The loader script is written in Python 3 using the `azure-keyvault-secrets` and `azure-identity` packages. Azure CLI is not installed in the production container image to minimize attack surface and image size.
- **GUD-002**: The operator guide defines naming conventions for Key Vault secrets without enumerating actual secret names.

## 2. Implementation Steps

### Implementation Phase 1

- **GOAL-001**: Create the dynamic Key Vault secret loader script and the container entrypoint wrapper.

| Task     | Description           | Completed | Date |
| -------- | --------------------- | --------- | ---- |
| TASK-001 | Create `scripts/load_secrets.py`. The script must: (1) Read `AZURE_KEY_VAULT_NAME` from the environment (exit 1 with a clear error message if absent). (2) Read `AZURE_CLIENT_ID` from the environment (exit 1 if absent). (3) Define a `MAX_ATTEMPTS = 3` and `RETRY_DELAY_SECONDS = 5` constant at module level. (4) Wrap the entire Key Vault load sequence in a `for attempt in range(1, MAX_ATTEMPTS + 1)` retry loop: on each attempt, instantiate `ManagedIdentityCredential(client_id=client_id)` and `SecretClient(vault_url=f"https://{vault_name}.vault.azure.net/", credential=credential)`; call `client.list_properties_of_secrets()` and iterate over enabled secrets only (skip where `secret_props.enabled is False`); for each enabled secret call `client.get_secret(name)` and accumulate values in a local dict; if the attempt succeeds, break out of the retry loop. (5) On any exception within the retry loop: print to stderr `f"[load_secrets] Attempt {attempt}/{MAX_ATTEMPTS} failed: {type(e).__name__}: {e}"` (never print secret values); if `attempt < MAX_ATTEMPTS`, print `f"[load_secrets] Retrying in {RETRY_DELAY_SECONDS}s..."` to stderr and call `time.sleep(RETRY_DELAY_SECONDS)`; if `attempt == MAX_ATTEMPTS`, print `f"[load_secrets] All {MAX_ATTEMPTS} attempts failed. Exiting."` to stderr and call `sys.exit(1)`. (6) After the retry loop completes successfully, convert each secret name to env var name: `name.upper().replace("-", "_")`. (7) Update `os.environ` with the loaded values. (8) Call `os.execvp(sys.argv[1], sys.argv[1:])` to replace the current process with the OpenClaw application command passed as arguments. Import `time` at the top of the file alongside `os` and `sys`. |           |      |
| TASK-002 | Create `scripts/entrypoint.sh` as a thin shell wrapper. Content: `#!/bin/bash\nset -euo pipefail\nexec python3 /app/scripts/load_secrets.py "$@"`. This script is the Docker `ENTRYPOINT`. It passes all arguments to the loader, which then exec-chains to the application. Mark the file executable (`chmod +x`). |           |      |

### Implementation Phase 2

- **GOAL-002**: Create the Dockerfile for the Ubuntu-based OpenClaw container image.

| Task     | Description           | Completed | Date |
| -------- | --------------------- | --------- | ---- |
| TASK-003 | Create `Dockerfile` at repository root. Base image: `ubuntu:24.04`. Add `ARG DEBIAN_FRONTEND=noninteractive`. Run `apt-get update && apt-get install -y python3 python3-pip python3-venv ca-certificates && rm -rf /var/lib/apt/lists/*`. Create `/app` working directory. Copy `requirements.txt` (from TASK-004) to `/app/requirements.txt`. Run `pip3 install --no-cache-dir -r /app/requirements.txt`. Copy `scripts/` to `/app/scripts/`. Copy application source (the OpenClaw app directory, to be confirmed at implementation time) to `/app/`. Set `WORKDIR /app`. Set `ENTRYPOINT ["/app/scripts/entrypoint.sh"]`. Set `CMD ["python3", "/app/main.py"]` (adjust entrypoint application command to match OpenClaw's actual startup command). Do not include any `ENV` instruction containing a secret or deployment identifier. |           |      |
| TASK-004 | Create `requirements.txt` at repository root listing Python dependencies: `azure-identity>=1.17.0`, `azure-keyvault-secrets>=4.8.0`. Add any additional Python runtime dependencies required by the OpenClaw application itself. This file is the authoritative pip dependency list for the container. |           |      |

### Implementation Phase 3

- **GOAL-003**: Create the GitHub Actions container build and publish CI workflow.

| Task     | Description           | Completed | Date |
| -------- | --------------------- | --------- | ---- |
| TASK-005 | Create `.github/workflows/container-build.yml`. Set triggers: `push` to `main` with `paths` filter matching `Dockerfile`, `requirements.txt`, `scripts/**`, and the OpenClaw application source directory. Add `workflow_dispatch` with no inputs (allows manual build). |           |      |
| TASK-006 | Add `build-and-push` job to the workflow. Add `permissions: contents: read`. Set `runs-on: ubuntu-24.04`. Add step `azure-cli-login` using `az login --service-principal --username "${{ secrets.AZURE_CLIENT_ID }}" --password "${{ secrets.AZURE_CLIENT_SECRET }}" --tenant "${{ secrets.AZURE_TENANT_ID }}"`. Add step to set the image tag as an output: `echo "image_tag=${{ github.sha }}" >> $GITHUB_OUTPUT`. |           |      |
| TASK-007 | Append to `container-build.yml`. Add step `acr-login`: run `az acr login --name "${{ secrets.ACR_NAME }}"`. Add new required GitHub Secret `ACR_NAME` to the secret inventory (secret name only, no value; value is the ACR resource name derived from `local.acr_name`). Add step `docker-build-push`: run `docker build -t "${{ secrets.ACR_LOGIN_SERVER }}/openclaw:${{ github.sha }}" -t "${{ secrets.ACR_LOGIN_SERVER }}/openclaw:latest" .`. Then `docker push "${{ secrets.ACR_LOGIN_SERVER }}/openclaw:${{ github.sha }}"` and `docker push "${{ secrets.ACR_LOGIN_SERVER }}/openclaw:latest"`. Add new required GitHub Secret `ACR_LOGIN_SERVER` (the ACR login server FQDN, treated as deployment metadata and stored as a secret). |           |      |
| TASK-008 | Append to `container-build.yml`. After a successful image push, add step `trigger-terraform-deploy` that calls the Terraform deployment workflow with the immutable image tag: `gh workflow run terraform-deploy.yml -f container_image_tag="${{ github.sha }}"`. Set `env: GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}`. This ensures only the exact SHA-tagged image is deployed; `latest` is never used by Terraform. Update `terraform-deploy.yml` (from plan 1 TASK-011) to accept `container_image_tag` as a `workflow_dispatch` input of type string with no default, and pass its value as a `-var` argument to `terraform plan`. |           |      |

### Implementation Phase 4

- **GOAL-004**: Update Terraform Container App definition to inject the Key Vault name and Managed Identity client ID as environment variables. This is the only Terraform modification in this plan.

| Task     | Description           | Completed | Date |
| -------- | --------------------- | --------- | ---- |
| TASK-009 | Modify `terraform/containerapp.tf` (plan 2 TASK-013). In the `module "container_app"` block's `template.container` section, add two additional `env` blocks alongside the existing `AZURE_OPENAI_ENDPOINT` entry: (1) `name = "AZURE_KEY_VAULT_NAME"`, `value = local.kv_name` — injects the vault name so the loader script can construct the vault URL without hardcoding it. (2) `name = "AZURE_CLIENT_ID"`, `value = module.managed_identity.client_id` — injects the User-Assigned Managed Identity client ID so `ManagedIdentityCredential` targets the correct identity. Neither value is sensitive in the Container App template context; neither is declared as a Container App `secret` block. |           |      |
| TASK-010 | Append to `terraform/outputs.tf` (plan 2 TASK-017). Add `output "key_vault_name"`: `value = local.kv_name`, `description = "Key Vault name for operator secret management"`, `sensitive = false`. This allows the operator to retrieve the vault name from `terraform output` after deployment without it needing to be stored elsewhere. |           |      |

### Implementation Phase 5

- **GOAL-005**: Create the operator secret management guide. The guide defines the process and naming convention without listing actual secret names.

| Task     | Description           | Completed | Date |
| -------- | --------------------- | --------- | ---- |
| TASK-011 | Create `docs/secret-management-guide.md`. Include: (1) **Overview**: description of the dynamic injection pattern and why no secrets are in the repo. (2) **Prerequisites**: operator must hold `Key Vault Secrets Officer` role on the vault, assigned via `az role assignment create --role "Key Vault Secrets Officer" --assignee <your-object-id> --scope <kv-resource-id>` (object IDs and resource IDs are not documented here; retrieve them at runtime from `az ad signed-in-user show` and `terraform output`). (3) **Secret naming convention**: secrets must use lowercase hyphenated names only (e.g., pattern `<service>-<descriptor>`); no uppercase, no spaces, no special characters except hyphens; the loader converts hyphens to underscores and uppercases to form the env var name. (4) **Adding a secret**: command pattern `az keyvault secret set --vault-name <vault-name> --name <secret-name> --value <value>` — operators retrieve vault name from `terraform output key_vault_name`; do not paste vault name or secret names into this document. (5) **Rotating a secret**: same `az keyvault secret set` command with the new value; then restart the Container App revision (`az containerapp revision restart`) to reload. (6) **Disabling a secret**: `az keyvault secret set-attributes --vault-name <vault-name> --name <secret-name> --enabled false`; loader skips disabled secrets. (7) **Security reminders**: never paste a secret name or value in a PR, issue comment, Slack message, or document; treat the vault name as deployment metadata. |           |      |
| TASK-012 | Update `docs/secrets-inventory.md` (from plan 1 TASK-004). Add new entries for `ACR_NAME` and `ACR_LOGIN_SERVER` GitHub Secrets (name, purpose, rotation cadence only). Add a section note: "Application runtime secrets are stored exclusively in Azure Key Vault and are not inventoried here. See `docs/secret-management-guide.md` for the management process." |           |      |

### Implementation Phase 6

- **GOAL-006**: Validate the container build, secret injection behaviour, and end-to-end runtime.

| Task     | Description           | Completed | Date |
| -------- | --------------------- | --------- | ---- |
| TASK-013 | Build the container image locally: `docker build -t openclaw:test .`. Confirm the build succeeds with zero errors. Confirm no secret values appear in any build layer by running `docker history openclaw:test` and inspecting all `RUN` instructions. |           |      |
| TASK-014 | Test the loader script in isolation: run `docker run --rm -e AZURE_KEY_VAULT_NAME=invalid -e AZURE_CLIENT_ID=invalid openclaw:test python3 /app/scripts/load_secrets.py echo test` and confirm it exits non-zero with an error message that does not contain any secret value. |           |      |
| TASK-015 | Trigger the `container-build.yml` workflow on a feature branch (manual `workflow_dispatch`). Confirm image is pushed to ACR with the correct SHA tag. Confirm the workflow does not print `ACR_LOGIN_SERVER`, `AZURE_CLIENT_SECRET`, or any secret value in the job logs. Confirm `latest` and SHA tags are both present in ACR. |           |      |
| TASK-016 | Confirm the `terraform-deploy.yml` workflow is triggered by `container-build.yml` with the correct `container_image_tag` input. Confirm `terraform plan` shows a Container App revision update with the new image tag. |           |      |
| TASK-017 | Add one test secret to Key Vault manually: `az keyvault secret set --vault-name <vault-name> --name test-secret --value test-value`. Restart the Container App revision. Confirm `TEST_SECRET` is available in the container environment by running `az containerapp exec` to open a shell and `echo $TEST_SECRET` (do not capture this output in CI logs). Remove the test secret after validation. |           |      |
| TASK-018 | Rotate a secret: update its value via `az keyvault secret set`, restart the Container App revision, and confirm the container picks up the new value. Confirm the old value is no longer accessible after the revision restart. |           |      |
| TASK-019 | Confirm that a disabled secret (set via `az keyvault secret set-attributes --enabled false`) is not loaded by the entrypoint script and that the container starts successfully without it. |           |      |

## 3. Alternatives

- **ALT-001**: Use Container App `secret` blocks with Key Vault secret URI references (`key_vault_secret_id`). Not selected; this requires every secret name to be declared in Terraform, which would document all secret names in the repository — a direct violation of REQ-003 and the security model.
- **ALT-002**: Use Azure Key Vault CSI driver volume mount to expose secrets as files, with a sidecar reading files into env vars. Not selected; CSI driver is not natively supported in Azure Container Apps (it is supported in AKS). Container Apps requires a different pattern.
- **ALT-003**: Use the `azure/login` GitHub Action with OIDC for the container build workflow. Not selected; the existing Service Principal credential pattern (plan 1) is used for consistency across all workflows. A future plan can migrate all workflows to OIDC.
- **ALT-004**: Install Azure CLI in the container and use `az keyvault secret list/show` in the entrypoint. Not selected; Azure CLI adds ~100MB to the image, introduces a dependency on the CLI version, and increases attack surface. The Python SDK is leaner and is already a direct dependency.
- **ALT-005**: Have the OpenClaw application itself fetch secrets from Key Vault via SDK at startup, removing the entrypoint wrapper entirely. Not selected without knowledge of the OpenClaw application's internal architecture. The wrapper approach is application-agnostic and does not require modifying OpenClaw source code.
- **ALT-006**: Use GitHub Actions secrets to hold all application secrets and inject them as Container App env vars via Terraform. Not selected; this requires documenting secret names in workflow files and Terraform, imposes GitHub Secrets limits, and couples the secret lifecycle to CI/CD rather than the operational Key Vault.

## 4. Dependencies

- **DEP-001**: Plans 1 and 2 fully completed; Key Vault, ACR, Container App, and Managed Identity all exist in Azure and in Terraform state.
- **DEP-002**: `azure-identity >= 1.17.0` and `azure-keyvault-secrets >= 4.8.0` Python packages available from PyPI in the CI runner build environment.
- **DEP-003**: Managed Identity holds `Key Vault Secrets User` role on Key Vault (provisioned in plan 2 TASK-015). This grants `GET` and `LIST` permissions on secrets, which are the minimum required for the loader script.
- **DEP-004**: GitHub Secrets `ACR_NAME` and `ACR_LOGIN_SERVER` configured in repository settings before the container build workflow is run.
- **DEP-005**: `terraform-deploy.yml` (plan 1) updated to accept `container_image_tag` as a `workflow_dispatch` string input and pass it to `terraform plan -var container_image_tag=<value>`.
- **DEP-006**: The operator adding the initial secrets to Key Vault holds the `Key Vault Secrets Officer` RBAC role on the vault.

## 5. Files

- **FILE-001**: `Dockerfile` — Ubuntu 24.04 container image definition; installs Python 3, pip, SDK packages; copies app and scripts; sets entrypoint.
- **FILE-002**: `requirements.txt` — Python package requirements for the container image.
- **FILE-003**: `scripts/load_secrets.py` — dynamic Key Vault secret loader; loads all enabled secrets as env vars, then exec-chains to the application.
- **FILE-004**: `scripts/entrypoint.sh` — thin shell entrypoint wrapper that delegates to `load_secrets.py`.
- **FILE-005**: `.github/workflows/container-build.yml` — CI workflow for building, tagging, and pushing the container image to ACR, then triggering the Terraform deploy workflow.
- **FILE-006**: `.github/workflows/terraform-deploy.yml` — modified (plan 1 file) to accept `container_image_tag` as a `workflow_dispatch` input.
- **FILE-007**: `terraform/containerapp.tf` — modified (plan 2 file) to add `AZURE_KEY_VAULT_NAME` and `AZURE_CLIENT_ID` env vars to the Container App template.
- **FILE-008**: `terraform/outputs.tf` — modified (plan 2 file) to add `key_vault_name` output.
- **FILE-009**: `docs/secret-management-guide.md` — new operator guide for Key Vault secret management; defines naming convention and procedures; does not list secret names or values.
- **FILE-010**: `docs/secrets-inventory.md` — updated (plan 1 file) to add `ACR_NAME`, `ACR_LOGIN_SERVER` GitHub Secret entries and note that application secrets are managed in Key Vault only.

## 6. Testing

- **TEST-001**: Container image builds successfully from `Dockerfile` with no errors.
- **TEST-002**: `docker history` on the built image shows no secret values in any layer command.
- **TEST-003**: Loader script exits non-zero and writes to stderr (not stdout) when `AZURE_KEY_VAULT_NAME` or `AZURE_CLIENT_ID` env vars are absent.
- **TEST-004**: Loader script skips disabled secrets and allows the container to start successfully.
- **TEST-005**: A secret added manually to Key Vault appears as the correctly normalized env var (`UPPER_SNAKE_CASE`) in the running container after a revision restart.
- **TEST-006**: Secret rotation (updating Key Vault value, restarting revision) delivers the new value; old value is gone.
- **TEST-007**: Container build CI workflow pushes both SHA-tagged and `latest`-tagged images to ACR without printing `ACR_LOGIN_SERVER` or any credential in job logs.
- **TEST-008**: Terraform deploy workflow is triggered with the correct SHA tag after a container build; `terraform plan` shows a Container App image update and no other resource changes.
- **TEST-009**: Container App starts successfully in Azure with Managed Identity loading secrets from Key Vault; no Azure CLI is present in the container (`which az` exits non-zero).

## 7. Risks & Assumptions

- **RISK-001**: If Key Vault is unreachable at container startup (network issue, MSAL token endpoint unavailable during cold-start), the container will fail to start after 3 attempts. Each attempt is separated by a fixed 5-second delay; total worst-case blocking time before exit is ~10 seconds. Failure details are written to stderr on every attempt for diagnosis via `az containerapp logs show`.
- **RISK-002**: Startup latency from Key Vault calls is bounded. With fewer than 50 secrets, the `list_properties_of_secrets` + individual `get_secret` pattern produces at most 51 Key Vault API calls. This is well within the Key Vault throttling limit (2000 GET operations per vault per 10 seconds) and adds a negligible startup overhead. No caching or batching is required.
- **RISK-003**: Concurrent container restarts are unlikely to cause Key Vault throttling at the confirmed secret count (< 50 secrets, single Container App instance). Monitor via Key Vault diagnostic logs if horizontal scaling is added in future.
- **RISK-004**: `ManagedIdentityCredential` token acquisition may fail during Container Apps cold-start before the identity endpoint is available. The fixed retry loop in RISK-001 (5s delay × 3 attempts) provides sufficient time for the identity endpoint to become available.
- **RISK-005**: The `container_image_tag` `workflow_dispatch` input added to `terraform-deploy.yml` may conflict with existing PR-triggered plan jobs that produce a `tfplan` artifact. Carefully test that the plan/apply gate remains intact after this modification.
- **ASSUMPTION-001**: The OpenClaw application startup command is known and can be placed in the `CMD` instruction of the Dockerfile. Adjust `CMD` at implementation time.
- **ASSUMPTION-002**: OpenClaw reads its configuration exclusively from environment variables. If it reads from config files, the loader script may need adapting to write to files rather than (or in addition to) env vars.
- **ASSUMPTION-003**: Python 3.10+ is available in `ubuntu:24.04` (it ships Python 3.12). The `azure-identity` and `azure-keyvault-secrets` packages are compatible with this version.
- **ASSUMPTION-004**: `Key Vault Secrets User` role (read-only) is sufficient for the loader. This role grants `secrets/get` and `secrets/list` actions, which are all that is required.

## 8. Related Specifications / Further Reading

- [infrastructure-terraform-workflow-auth-1.md](infrastructure-terraform-workflow-auth-1.md)
- [infrastructure-azure-resources-deployment-1.md](infrastructure-azure-resources-deployment-1.md)
- `ARCHITECTURE.md`
- `PRODUCT.md`
- Azure Key Vault secrets Python SDK: https://learn.microsoft.com/python/api/overview/azure/keyvault-secrets-readme
- Azure Identity Python SDK (DefaultAzureCredential / ManagedIdentityCredential): https://learn.microsoft.com/python/api/overview/azure/identity-readme
- Container Apps managed identity documentation: https://learn.microsoft.com/azure/container-apps/managed-identity
- Key Vault RBAC built-in roles: https://learn.microsoft.com/azure/key-vault/general/rbac-guide
