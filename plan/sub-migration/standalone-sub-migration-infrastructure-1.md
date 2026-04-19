---
goal: Migrate all Azure infrastructure from old subscription to new subscription
plan_type: standalone
version: 1.0
date_created: 2026-04-19
status: 'Completed'
tags: [infrastructure, migration, subscription, terraform, dns, github-actions]
---

# Introduction

![Status: Completed](https://img.shields.io/badge/status-Completed-brightgreen)

Migrate OpenClaw infrastructure from the old Azure subscription (`57215661-2f9e-482f-9334-c092e02651ec`) to the new Azure subscription (`04e514be-afa0-4ce3-a4ab-4278113774c0`). All Azure resources are to be recreated fresh — no application data is preserved. Terraform state backend storage is migrated first so state is on the target subscription before old resources are deleted. ACR is replaced by GHCR (code change already landed). Logging diagnostic settings are removed to minimize costs. All changes are performed locally; GitHub Actions workflows are re-enabled after validation.

The DNS zone for `acmeadventure.ca` already resides on the new subscription (`rg-dns-zones`). Both dev and prod environments are in scope; dev is validated first.

---

## 1. Requirements & Constraints

- **REQ-001**: Terraform state backend must be bootstrapped on the new subscription before any old resources are deleted.
- **REQ-002**: All Azure resources are recreated fresh. No application or file-share data is preserved.
- **REQ-003**: Dev environment is fully validated before prod migration begins.
- **REQ-004**: GitHub Actions workflows remain disabled (no merges to `dev` or `main`) until secrets are updated and the new infrastructure is validated.
- **REQ-005**: ACR is replaced by GHCR — no ACR resource is created in the new subscription (Terraform code change already landed).
- **REQ-006**: Container image source is `ghcr.io/openclaw/openclaw` (default value of `openclaw_image_repository`; no variable change needed).
- **REQ-007**: Logging diagnostic settings are removed from AKS and Key Vault to minimize Log Analytics ingest costs. The Log Analytics Workspace module is retained as the AKS add-on OMS agent configuration references it, but with no diagnostic sinks it costs nothing.
- **REQ-008**: The `import` block in `terraform/identity.tf` imports a pre-existing AKS cluster identity that predates Terraform management. On a fresh deployment this resource does not exist yet; the import block must be removed or it will error at plan time.
- **REQ-009**: The budget `start_date` in `terraform/costs.tf` must be updated to the first day of the current or upcoming billing month. Azure rejects a start date in a past billing period.
- **REQ-012**: The existing CI Service Principal is reused on the new subscription. No new SP is created. The SP's `appId` and `clientSecret` values in GitHub Secrets and local `*.tfvars` files do not change — only `AZURE_SUBSCRIPTION_ID` and tfstate backend values change.
- **REQ-010**: DNS A records for `paa-dev.acmeadventure.ca` and `paa.acmeadventure.ca` must be updated to the new NGINX Gateway Fabric LoadBalancer IPs after AKS bootstrap.
- **REQ-011**: The Azure AI Foundry API key (`azure-ai-api-key`) must be manually set in the new Key Vault after `terraform apply` completes, before OpenClaw pods can authenticate to AI models.
- **SEC-001**: Never commit `scripts/dev.tfvars` or `scripts/prod.tfvars`; both are git-ignored.
- **SEC-002**: All new SP credentials go directly into GitHub Secrets and local `*.tfvars` files only — never into source code or workflow files.
- **SEC-003**: All operational commands must target `dev` first. Prod commands require explicit confirmation.
- **CON-001**: The original tfstate storage account name (`stpaatfstate`) is globally unique to Azure and is occupied by the old subscription during the migration window. A new distinct name (e.g., `stpaatfstate2`) is required until the old storage account is deleted.
- **CON-002**: `scripts/dev.tfvars` is local-only and git-ignored; its updated values are not committed.
- **CON-003**: ArgoCD manages workload reconciliation. No ArgoCD manifests require subscription-specific values; no ArgoCD file changes are needed.
- **CON-004**: DNS A records are hosted in the `acmeadventure.ca` zone in `rg-dns-zones` on the new subscription (`04e514be-afa0-4ce3-a4ab-4278113774c0`). Azure DNS `az network dns record-set a` commands target this RG and subscription.
- **GUD-001**: Use `terraform plan` before every `terraform apply`. Confirm that the plan shows zero destroys and only expected creates/updates before applying.
- **GUD-002**: Use `letsencrypt-staging` ClusterIssuer for initial cert validation. Switch to `letsencrypt-prod` only after staging certificates are issued successfully to avoid Let's Encrypt rate limits.
- **PAT-001**: Terraform state migration uses `az storage blob download` from old sub then `az storage blob upload` to new sub.

---

## 2. Implementation Steps

### Implementation Phase 1 — Terraform Code Changes (local, no Azure commands)

- GOAL-001: Update Terraform configuration so it applies cleanly on a fresh deployment with no ACR, reduced logging, and correct metadata for the new subscription context.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-001 | **`terraform/identity.tf`** — Remove the `import` block that imports the pre-existing AKS cluster identity (`module.aks_identity.azurerm_user_assigned_identity.this`). This block was a one-time import for the old subscription's resource and will error on a fresh deployment where the resource does not yet exist. The `module "aks_identity"` resource block itself stays. | ✅ | 2026-04-19 |
| TASK-002 | **`terraform/aks.tf`** — Remove the `diagnostic_settings` block inside `module "aks"` (the `aks_diagnostics` key that routes `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` logs to the Log Analytics workspace). Removes Log Analytics ingest cost for Kubernetes API plane logs. | ✅ | 2026-04-19 |
| TASK-003 | **`terraform/keyvault.tf`** — Remove the `diagnostic_settings` block inside `module "key_vault"` (the `law` key routing KV audit logs to the Log Analytics workspace). Removes KV audit log ingest cost. | ✅ | 2026-04-19 |
| TASK-004 | **`terraform/costs.tf`** — Update `start_date` in `azurerm_consumption_budget_resource_group.openclaw` from `"2026-04-01T00:00:00Z"` to `"2026-05-01T00:00:00Z"`. Azure rejects a budget start date in a past or current completed billing period (April 2026 has passed or is closing). | ✅ | 2026-04-19 |
| TASK-005 | Run `terraform fmt -recursive` in `terraform/` and confirm no lint errors. Run `terraform validate` locally if a backend is already configured, or defer validation to Phase 5. | ✅ | 2026-04-19 |

---

### Implementation Phase 2 — Terraform State Backend Migration

- GOAL-002: Stand up the Terraform state backend on the new subscription and copy the existing state files there. The old subscription's state storage is not touched until after new infrastructure is created and verified.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-006 | **Local:** Set the following values in `scripts/dev.tfvars` (local file, never committed). Change `AZURE_SUBSCRIPTION_ID` to `04e514be-afa0-4ce3-a4ab-4278113774c0`. Set `TFSTATE_STORAGE_ACCOUNT` to a new globally-unique name (e.g., `stpaatfstate2`) — the original `stpaatfstate` is still occupied by the old subscription during this window. All other tfstate fields (`TFSTATE_RG=rg-paa-tfstate`, `TFSTATE_LOCATION=eastus`, `TFSTATE_CONTAINER=tfstate`) can remain the same. | ✅ | 2026-04-19 |
| TASK-007 | **`az login`** and `az account set --subscription 04e514be-afa0-4ce3-a4ab-4278113774c0`. Confirm correct subscription context before running any bootstrapping commands. | ✅ | 2026-04-19 |
| TASK-008 | **Bootstrap new tfstate storage** on the new subscription by running `scripts/bootstrap-tfstate.sh` with the new values exported from `scripts/dev.tfvars`. This creates `rg-paa-tfstate` and the new storage account (`stpaatfstate2`) with versioning enabled. Run the script for both the dev values; the same storage account will hold both dev and prod state blobs. | ✅ | 2026-04-19 |
| TASK-009 | **Export dev state from old sub.** Switch to old subscription context (`az account set --subscription 57215661-2f9e-482f-9334-c092e02651ec`), then download the dev state file: `az storage blob download --account-name stpaatfstate --container-name tfstate --name terraform-dev.tfstate --file /tmp/terraform-dev.tfstate --auth-mode login`. | ✅ | 2026-04-19 |
| TASK-010 | **Upload dev state to new sub.** Switch back to new subscription context. Upload: `az storage blob upload --account-name stpaatfstate2 --container-name tfstate --name terraform-dev.tfstate --file /tmp/terraform-dev.tfstate --auth-mode login --overwrite`. | ✅ | 2026-04-19 |
| TASK-011 | **Export prod state from old sub.** Switch to old subscription context. Download: `az storage blob download --account-name stpaatfstate --container-name tfstate --name terraform-prod.tfstate --file /tmp/terraform-prod.tfstate --auth-mode login`. | ✅ | 2026-04-19 |
| TASK-012 | **Upload prod state to new sub.** Switch back to new subscription. Upload: `az storage blob upload --account-name stpaatfstate2 --container-name tfstate --name terraform-prod.tfstate --file /tmp/terraform-prod.tfstate --auth-mode login --overwrite`. | ✅ | 2026-04-19 |
| TASK-013 | Verify both blobs are present: `az storage blob list --account-name stpaatfstate2 --container-name tfstate --auth-mode login --output table`. Confirm `terraform-dev.tfstate` and `terraform-prod.tfstate` appear. | ✅ | 2026-04-19 |
| TASK-014 | **Also upload the central tfvars blobs** if they exist in the old container. Download `tfvars/dev.auto.tfvars` from old sub and upload to new sub's container. Repeat for `tfvars/prod.auto.tfvars`. These are non-secret config blobs needed by `terraform-local.sh`. If they do not exist, they must be created before running Phase 5 (see central-tfvars.example). | ✅ | 2026-04-19 |

---

### Implementation Phase 3 — Grant Existing Service Principal Roles on New Subscription

- GOAL-003: Assign the existing CI Service Principal the required roles on the new subscription. The SP's `appId` and `password` (client secret) are unchanged; only scope changes. No credential rotation is needed.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-015 | **Retrieve the existing SP object ID** for the role assignment commands: `az ad sp show --id <AZURE_CLIENT_ID> --query id -o tsv`. Use this object ID in TASK-016 and TASK-017. `AZURE_CLIENT_ID` is the `appId` already stored in `scripts/dev.tfvars` and GitHub Secrets. | ✅ | 2026-04-19 |
| TASK-016 | **Grant Contributor** on the new subscription: `az role assignment create --assignee-object-id <sp-object-id> --assignee-principal-type ServicePrincipal --role Contributor --scope /subscriptions/04e514be-afa0-4ce3-a4ab-4278113774c0`. | ✅ | 2026-04-19 |
| TASK-017 | **Grant User Access Administrator** on the new subscription (required for `azurerm_role_assignment` resources in Terraform): `az role assignment create --assignee-object-id <sp-object-id> --assignee-principal-type ServicePrincipal --role "User Access Administrator" --scope /subscriptions/04e514be-afa0-4ce3-a4ab-4278113774c0`. | ✅ | 2026-04-19 |
| TASK-017B | **Update `scripts/dev.tfvars`** — only `AZURE_SUBSCRIPTION_ID` changes (already set in TASK-006); `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, and `AZURE_CLIENT_SECRET` remain the same as they reference the same SP. | ✅ | 2026-04-19 |

---

### Implementation Phase 4 — Delete Old Subscription Resources

- GOAL-004: Remove all Azure resources from the old subscription. Direct resource-group deletion is used rather than `terraform destroy` because the state files have already been migrated to the new subscription backend.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-018 | Switch to old subscription context: `az account set --subscription 57215661-2f9e-482f-9334-c092e02651ec`. | ✅ | 2026-04-19 |
| TASK-019 | Delete the dev resource group: `az group delete --name paa-dev-rg --yes --no-wait`. This deletes AKS, Key Vault, AI Foundry, Log Analytics, Automation Account, Managed Identities, and all associated resources in the dev environment. `--no-wait` allows the command to return immediately; Azure processes the deletion asynchronously. | ✅ | 2026-04-19 |
| TASK-020 | Delete the prod resource group: `az group delete --name paa-prod-rg --yes --no-wait`. Same as above for prod environment resources. | ✅ | 2026-04-19 |
| TASK-021 | Delete old tfstate resource group **after confirming new sub's state backend is healthy** (TASK-013 complete): `az group delete --name rg-paa-tfstate --yes --no-wait`. This deletes the old `stpaatfstate` storage account and frees the name for potential future reuse. | ✅ | 2026-04-19 |
| TASK-022 | Confirm Key Vault soft-delete: after RG deletion, Key Vaults enter a soft-deleted recoverable state for 90 days by default. If new terraform apply fails with a "Key Vault name already exists in soft-deleted state" error, purge via: `az keyvault purge --name <kv-name> --location eastus`. Expected KV names: `paa-dev-kv`, `paa-prod-kv`. Purge both proactively to avoid naming collision. | ✅ | 2026-04-19 |
| TASK-023 | Confirm AI Foundry Hub soft-delete: same pattern as Key Vault. If `terraform apply` fails on AI Foundry naming collision, purge: `az cognitiveservices account purge --resource-group paa-dev-rg --name paa-dev-hub --location eastus` (and prod equivalent). Purge both proactively. | ✅ | 2026-04-19 |

---

### Implementation Phase 5 — Terraform Apply (Dev)

- GOAL-005: Recreate all dev infrastructure on the new subscription from the migrated state. Terraform will plan creates for all resources since they do not exist in the new subscription.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-024 | Switch to new subscription context: `az account set --subscription 04e514be-afa0-4ce3-a4ab-4278113774c0`. | ✅ | 2026-04-19 |
| TASK-025 | Ensure the central `dev.auto.tfvars` blob exists in the new sub's state container (uploaded in TASK-014). If not, create a local file from `scripts/central-tfvars.example` with env values (`project=paa`, `environment=dev`, `location=eastus`, etc.) and upload it before proceeding. | ✅ | 2026-04-19 |
| TASK-026 | Run `./scripts/terraform-local.sh dev plan`. Review the output carefully: every resource should show as `to be created` (`+`). Confirm zero destroys. If any resource shows as `to be destroyed` or `to be replaced`, investigate before applying. The state references old-subscription resource IDs; Terraform's refresh will detect they don't exist in the new sub and plan creates. | ✅ | 2026-04-19 |
| TASK-027 | Run `./scripts/terraform-local.sh dev apply`. Monitor for errors. Common expected first-apply issues: RBAC propagation delay on the new Key Vault secrets officer role assignment (may require a second apply). | ✅ | 2026-04-19 |
| TASK-028 | Capture Terraform outputs for use in AKS bootstrap: `./scripts/terraform-local.sh dev output`. Record `aks_cluster_name`, `kv_name`, `instance_mi_client_ids` (per-instance managed identity client IDs), `azure_openai_endpoint`, `aks_oidc_issuer_url`. | ✅ | 2026-04-19 |

---

### Implementation Phase 6 — AKS Bootstrap (Dev)

- GOAL-006: Install platform tooling on the new dev AKS cluster and seed per-instance Kubernetes resources, replicating the AKS bootstrap workflow steps locally.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-029 | **Configure kubectl**: `az aks get-credentials --resource-group paa-dev-rg --name paa-dev-aks --overwrite-existing`. | ✅ | 2026-04-19 |
| TASK-030 | **Apply Gateway API CRDs**: `kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml`. | ✅ | 2026-04-19 |
| TASK-031 | **Install NGINX Gateway Fabric** (chart 2.5.0): `helm upgrade --install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric --namespace gateway-system --create-namespace --version 2.5.0 --set nginx.service.type=LoadBalancer --wait --timeout 10m`. | ✅ | 2026-04-19 |
| TASK-032 | **Capture new LoadBalancer IP**: `kubectl get svc -n gateway-system ngf-nginx-gateway-fabric --output jsonpath='{.status.loadBalancer.ingress[0].ip}'`. Record this IP — it replaces all previous dev LoadBalancer IPs. This is `<NEW-DEV-LB-IP>`. | ✅ | 2026-04-19 |
| TASK-033 | **Apply Gateway manifest**: `kubectl apply -f workloads/bootstrap/gateway.yaml`. | ✅ | 2026-04-19 |
| TASK-034 | **Install cert-manager** (chart 1.20.1, `--enable-gateway-api` required): `helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version 1.20.1 --set crds.enabled=true --set config.enableGatewayAPI=true --wait`. (Follow exact flags in `.github/workflows/aks-bootstrap.yml`.) | ✅ | 2026-04-19 |
| TASK-035 | **Apply ClusterIssuers**: Apply `workloads/bootstrap/cluster-issuers.yaml` after substituting `LETSENCRYPT_EMAIL` with the real address (use `envsubst` as done in CI). | ✅ | 2026-04-19 |
| TASK-036 | **Install ArgoCD**: follow the ArgoCD install steps in `aks-bootstrap.yml` for the dev bootstrap job. Apply `workloads/bootstrap/argocd-netpol.yaml` after install. | ✅ | 2026-04-19 |
| TASK-037 | **Seed per-instance K8s resources** for each dev instance (e.g., `ch`, `jh`). For each instance, export the required env vars from Terraform outputs (TASK-028) and run: `OPENCLAW_MI_CLIENT_ID=<id> KEY_VAULT_NAME=<kv> AZURE_TENANT_ID=<tid> AZURE_OPENAI_ENDPOINT=<ep> ./scripts/seed-openclaw-aks.sh dev <inst>`. | ✅ | 2026-04-19 |

---

### Implementation Phase 7 — DNS Update (Dev)

- GOAL-007: Update DNS A records in the `acmeadventure.ca` zone on the new subscription to point to the new NGINX Gateway Fabric LoadBalancer IP.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-038 | Confirm the `acmeadventure.ca` DNS zone exists in `rg-dns-zones` on subscription `04e514be-afa0-4ce3-a4ab-4278113774c0`: `az network dns zone show --name acmeadventure.ca --resource-group rg-dns-zones --subscription 04e514be-afa0-4ce3-a4ab-4278113774c0`. | ✅ | 2026-04-19 |
| TASK-039 | **Update dev A record** (`paa-dev`): `az network dns record-set a set-record --resource-group rg-dns-zones --zone-name acmeadventure.ca --record-set-name paa-dev --ipv4-address <NEW-DEV-LB-IP> --subscription 04e514be-afa0-4ce3-a4ab-4278113774c0`. If any old IP records exist on the record set, delete them first with `az network dns record-set a remove-record`. | ✅ | 2026-04-19 |
| TASK-040 | Validate DNS propagation: `dig paa-dev.acmeadventure.ca +short` must return `<NEW-DEV-LB-IP>`. Wait for propagation before proceeding with cert-manager ACME validation. | ✅ | 2026-04-19 |

---

### Implementation Phase 8 — Prod Migration

- GOAL-008: Repeat Phases 5–7 for the prod environment after dev is fully validated (ArgoCD synced, pods running, HTTPS reachable).

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-041 | Create or update `scripts/prod.tfvars` (local, git-ignored) with new subscription credentials, new SP credentials, and new tfstate backend values. Ensure `TFSTATE_KEY=terraform-prod.tfstate`. | ✅ | 2026-04-19 |
| TASK-042 | Run `./scripts/terraform-local.sh prod plan`. Confirm all resources show as `to be created`. Review for any unexpected plan actions before applying. | ✅ | 2026-04-19 |
| TASK-043 | Run `./scripts/terraform-local.sh prod apply`. | ✅ | 2026-04-19 |
| TASK-044 | Capture prod Terraform outputs (same set as TASK-028, prod environment). | ✅ | 2026-04-19 |
| TASK-045 | Run AKS bootstrap steps for prod (equivalent of TASK-029 through TASK-036, targeting `paa-prod-aks`, using prod outputs). | ✅ | 2026-04-19 |
| TASK-046 | **Seed per-instance K8s resources** for each prod instance (e.g., `ch`, `jh`, `kjm`). Run `seed-openclaw-aks.sh prod <inst>` with `ALLOW_PROD=true` for each instance. | ✅ | 2026-04-19 |
| TASK-047 | **Update prod A record** (`@` or `paa`): `az network dns record-set a set-record --resource-group rg-dns-zones --zone-name acmeadventure.ca --record-set-name paa --ipv4-address <NEW-PROD-LB-IP> --subscription 04e514be-afa0-4ce3-a4ab-4278113774c0`. | ✅ | 2026-04-19 |
| TASK-048 | Validate DNS propagation for prod: `dig paa.acmeadventure.ca +short` must return `<NEW-PROD-LB-IP>`. | ✅ | 2026-04-19 |

---

### Implementation Phase 9 — Manual Post-Apply Secrets (Both Environments)

- GOAL-009: Set the Azure AI Foundry API key in both Key Vaults. Terraform creates the `azure-ai-api-key` secret with a placeholder value on first apply and never overwrites it on subsequent applies (`lifecycle { ignore_changes = [value] }`). The real key must be set manually.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-049 | Retrieve the Azure AI API key from the new AI Foundry account. In the Azure portal: AI Foundry → `paa-dev-hub` → Keys and Endpoint → copy Key 1. | ✅ | 2026-04-19 |
| TASK-050 | Set the dev Key Vault secret: `az keyvault secret set --vault-name paa-dev-kv2 --name azure-ai-api-key --value "<key>" --subscription 04e514be-afa0-4ce3-a4ab-4278113774c0`. | ✅ | 2026-04-19 |
| TASK-051 | Retrieve the prod Azure AI API key (may be the same account or a separate one depending on tfvars) and set it in the prod Key Vault: `az keyvault secret set --vault-name paa-prod-kv2 --name azure-ai-api-key --value "<key>" --subscription 04e514be-afa0-4ce3-a4ab-4278113774c0`. | ✅ | 2026-04-19 |

---

### Implementation Phase 10 — GitHub Secrets and Workflow Re-enablement

- GOAL-010: Update all GitHub Environment secrets affected by the new subscription and Service Principal, then re-enable workflows.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
- **TASK-052 | **GitHub `dev` environment — update secrets**. Navigate to GitHub → Settings → Environments → `dev` → Secrets. Update only the values that changed: `AZURE_SUBSCRIPTION_ID` → `04e514be-afa0-4ce3-a4ab-4278113774c0`; `TFSTATE_STORAGE_ACCOUNT` → new name from TASK-006 (e.g., `stpaatfstate2`). `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, and `AZURE_TENANT_ID` are **unchanged** — the same SP is reused. `TFSTATE_RG` and `TFSTATE_LOCATION` are unchanged. | ✅ | 2026-04-19 |
- **TASK-053 | **GitHub `prod` environment — update the same two changed secrets**: `AZURE_SUBSCRIPTION_ID` and `TFSTATE_STORAGE_ACCOUNT`. All other secrets are unchanged. | ✅ | 2026-04-19 |
| TASK-054 | **Verify no other secrets reference the old subscription.** Check the `dev` and `prod` environments for any other secrets that embed the old subscription ID or old storage account name. `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`, `PUBLIC_IP`, `BUDGET_ALERT_EMAIL`, and `LETSENCRYPT_EMAIL` are all unchanged. | ✅ | 2026-04-19 |
| TASK-055 | **Workflow review — `terraform-dev.yml`**: Triggers on PRs to `dev` and `workflow_dispatch`. No workflow file changes needed — subscription identity comes entirely from secrets. Re-enable by creating a test PR to `dev` after secrets are updated. | ✅ | 2026-04-19 |
| TASK-056 | **Workflow review — `terraform-infra.yml`**: Triggers on push to `main`. No workflow file changes needed. The prod apply will run against the new subscription after secrets are updated. | ✅ | 2026-04-19 |
| TASK-057 | **Workflow review — `aks-bootstrap.yml`**: Triggers after Terraform Dev or Terraform Infrastructure succeeds. No changes needed — uses `AZURE_SUBSCRIPTION_ID` from secrets and derives cluster/RG names from `TF_VAR_PROJECT` + `TF_VAR_environment`. Confirm `TF_VAR_PROJECT` repo variable still equals `paa`. | ✅ | 2026-04-19 |
| TASK-058 | **Workflow review — `openclaw-test-dev.yml`**: Triggers after Terraform Dev succeeds. No changes needed — all connectivity is via `AZURE_SUBSCRIPTION_ID` secret. | ✅ | 2026-04-19 |
| TASK-059 | **Workflow review — `backup.yml`**: Triggers on daily schedule. Backs up AKS NFS share data. References `TF_VAR_project` and `TF_VAR_environment` to derive resource names. No changes needed — works after secrets update. Review `scripts/backup-openclaw.sh` to confirm it does not hardcode the old subscription. | ✅ | 2026-04-19 |
| TASK-060 | **Workflow review — `enforce-branch-model.yml`**: No Azure dependency. No changes needed. | ✅ | 2026-04-19 |
| TASK-061 | **Update `workloads/bootstrap/README.md`** IP table with the new dev and prod LoadBalancer IPs captured in TASK-032 and TASK-045. This is the only source file that contains IPs and must be kept current. | ✅ | 2026-04-19 |

---

## 3. Alternatives

- **ALT-001**: Run `terraform destroy` on the old subscription instead of deleting RGs directly. Not chosen because the state backend has already been migrated to the new subscription; re-pointing the backend at the old sub to run destroy and then back to the new sub adds complexity and risk. Direct RG deletion is faster and achieves the same outcome.
- **ALT-002**: Keep the `import` block and work around the fresh-deploy error by first creating just the AKS identity resource and then running full apply. Not chosen because removing the import block is the correct long-term state — the resource was imported years ago and the import block serves no purpose after the initial import.
- **ALT-003**: Remove the Log Analytics Workspace entirely to eliminate even the resource cost. Not chosen because the AKS add-on OMS agent configuration block references `module.logging.resource_id` (even with `enabled = false`), requiring schema changes to the AKS module. Removing the diagnostic sinks (TASK-002, TASK-003) achieves zero ingest cost with minimal code change.
- **ALT-004**: Reuse the original tfstate storage account name `stpaatfstate` by deleting old sub resources first, then bootstrapping the new state storage. Not chosen because state migration must precede resource deletion per REQ-001.
- **ALT-005**: Create a new Service Principal for the new subscription. Not chosen — the existing SP resides in Entra and its identity is not subscription-scoped. Adding role assignments on the new subscription is sufficient; no new SP or credential rotation is needed.

---

## 4. Dependencies

- **DEP-001**: `az` CLI must be authenticated to both subscriptions during Phase 2 state migration (switching contexts between old and new).
- **DEP-002**: Existing SP role assignments on the new subscription (Phase 3) must be complete before running `terraform apply` (Phase 5).
- **DEP-003**: Dev infrastructure (Phase 5) must be running and validated before prod migration (Phase 8) begins.
- **DEP-004**: DNS propagation (Phase 7) must complete before ACME HTTP-01 challenges succeed and Let's Encrypt issues TLS certificates.
- **DEP-005**: `azure-ai-api-key` must be set in Key Vault (Phase 9) before OpenClaw pods can initialize their AI model providers.
- **DEP-006**: GitHub secrets (Phase 10) must be updated before workflows can successfully target the new subscription.

---

## 5. Files

- **FILE-001**: `terraform/identity.tf` — Remove `import` block (TASK-001)
- **FILE-002**: `terraform/aks.tf` — Remove `diagnostic_settings` block (TASK-002)
- **FILE-003**: `terraform/keyvault.tf` — Remove `diagnostic_settings` block (TASK-003)
- **FILE-004**: `terraform/costs.tf` — Update `start_date` (TASK-004)
- **FILE-005**: `scripts/dev.tfvars` — Update subscription ID, SP credentials, tfstate storage account name (TASK-006, TASK-017); local file, never committed
- **FILE-006**: `scripts/prod.tfvars` — Create/update with new-sub credentials and tfstate values (TASK-041); local file, never committed
- **FILE-007**: `workloads/bootstrap/README.md` — Update LoadBalancer IP table after bootstrap (TASK-061)
- **FILE-008**: `terraform/acr.tf`, `terraform/main.tf`, `terraform/roleassignments.tf`, `terraform/outputs.tf`, `terraform/locals.tf` — ACR removal already completed

---

## 6. Testing

- **TEST-001**: After TASK-026 (`terraform plan`), verify the plan output shows zero destroys and all resources as `to be created`. Block on any unexpected destroy.
- **TEST-002**: After TASK-027 (`terraform apply`), verify all Terraform outputs are populated and non-null: `aks_cluster_name`, `kv_name`, `instance_mi_client_ids`, `azure_openai_endpoint`.
- **TEST-003**: After TASK-032 (NGINX install), confirm `kubectl get svc -n gateway-system` shows an `EXTERNAL-IP` (not `<pending>`).
- **TEST-004**: After TASK-039 (DNS update), `dig paa-dev.acmeadventure.ca +short` must return the new LB IP.
- **TEST-005**: After cert-manager and ClusterIssuer installation, confirm a staging certificate is issued: `kubectl get certificate -A` shows `True` in READY column.
- **TEST-006**: After ArgoCD Application seeding, confirm pods are running: `kubectl get pods -n openclaw-ch` and `kubectl get pods -n openclaw-jh` show `Running`.
- **TEST-007**: After Phase 9 (AI key set), validate OpenClaw can reach the AI model by triggering a test prompt (use `openclaw` CLI or `kubectl exec`).
- **TEST-008**: After Phase 10 (secrets updated), trigger `terraform-dev` workflow via `workflow_dispatch` and confirm it succeeds against the new subscription.

---

## 7. Risks & Assumptions

- **RISK-001**: Key Vault soft-delete may block `terraform apply` if the old KV name enters a soft-deleted state with the same name. Mitigation: purge proactively (TASK-022) after RG deletion.
- **RISK-002**: Azure AI Foundry Hub soft-delete has same risk. Mitigation: purge proactively (TASK-023).
- **RISK-003**: Let's Encrypt rate limits apply if `letsencrypt-prod` is used before staging validation succeeds. Mitigation: GUD-002 mandates staging first.
- **RISK-004**: Newly added RBAC role assignments (Contributor + User Access Administrator on the new subscription) require a few minutes to propagate before `terraform apply` can create nested role assignments. Wait 2–3 minutes after TASK-017 before running `terraform plan`/`apply`. A second apply may be needed if the first fails on RBAC propagation.
- **RISK-005**: `random_id.openclaw_gateway_token` values in the migrated state reference old tokens. Because Terraform state is copied (not blanked), the same gateway tokens are preserved in state and Terraform will create new KV secrets with the same values. This is the desired behavior — OpenClaw config that references these tokens remains valid.
- **RISK-006**: The `import` block on `module.aks_identity` currently exists in the committed code. If it is not removed (TASK-001) before running `terraform plan` on the new sub, Terraform will attempt to import a resource that does not exist and fail with a 404. This is a hard blocker.
- **ASSUMPTION-001**: The old and new subscriptions belong to the same Entra tenant. The existing SP is already registered in that tenant and can be granted roles on any subscription within it. `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, and `AZURE_CLIENT_SECRET` are all unchanged.
- **ASSUMPTION-002**: The `acmeadventure.ca` DNS zone NS records are already delegated and authoritative for the zone hosted in `rg-dns-zones` on the new subscription.
- **ASSUMPTION-003**: The old subscription's VM (removed from Terraform management per `windowsvm.tf` comment) is left as-is; it is not in any Terraform-managed resource group and is not in scope for deletion.
- **ASSUMPTION-004**: The prod tfvars blob (`tfvars/prod.auto.tfvars`) mirrors the dev blob structure. If it does not exist on the old sub, it must be recreated from `scripts/central-tfvars.example` before running prod apply.
- **ASSUMPTION-005**: `scripts/backup-openclaw.sh` does not hardcode the old subscription ID. If it does, it must be reviewed before re-enabling the backup workflow.

---

## 8. Related Specifications / Further Reading

- [../../ARCHITECTURE.md](../../ARCHITECTURE.md)
- [../../scripts/central-tfvars.example](../../scripts/central-tfvars.example)
- [../../workloads/bootstrap/README.md](../../workloads/bootstrap/README.md)
- [../../docs/secrets-inventory.md](../../docs/secrets-inventory.md)
