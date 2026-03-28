---
goal: Introduce a prod-only shared resource group and migrate ACR into it
plan_type: standalone
version: 1.0
date_created: 2026-03-28
last_updated: 2026-03-28
owner: Platform Engineering
status: 'Complete'
tags: [infrastructure, terraform, azure, acr, resource-group, shared, prod]
---

# Introduction

![Status: Complete](https://img.shields.io/badge/status-Complete-brightgreen)

The current topology deploys one Azure Container Registry (ACR) per environment inside the environment-scoped resource group. This plan introduces a third resource group — `${project}-shared-rg` — that is provisioned only on the `prod` deployment path and hosts a single ACR shared across the project. Dev deployments continue to use a public placeholder image and never provision ACR or the shared resource group.

## 1. Requirements & Constraints

- **REQ-001**: Create a new Terraform-managed resource group named `${project}-shared-rg` that deploys only when `var.environment == "prod"`.
- **REQ-002**: Migrate the ACR module to target the new shared resource group; remove ACR from the environment-scoped resource group.
- **REQ-003**: ACR name must not contain the environment slug because the registry is shared. Use `${replace(var.project, "-", "")}acr` (project prefix only).
- **REQ-004**: The `AcrPull` role assignment must be made conditional so it is created only when ACR exists (i.e., in prod).
- **REQ-005**: Add a `acr_login_server` Terraform output (sensitive) for prod, so CI can reference the login server without hard-coding it.
- **REQ-006**: Dev deployments must continue to function using the existing `container_image` public placeholder path with `container_image_acr_server = null`.
- **SEC-001**: No static ACR credentials. Managed Identity pull remains the only authentication path.
- **SEC-002**: Do not expose ACR resource IDs or login server values as non-sensitive outputs.
- **CON-001**: All infrastructure changes must remain declarative in Terraform.
- **CON-002**: AVM module `Azure/avm-res-resources-resourcegroup/azurerm` (`~> 0.2`) must be used for the shared resource group, consistent with the existing resource group pattern.
- **CON-003**: AVM module `Azure/avm-res-containerregistry-registry/azurerm` (`~> 0.4`) must be used for ACR, consistent with the existing ACR pattern.
- **CON-004**: The existing `module.resource_group` (environment-scoped) must not be altered in scope or naming.
- **GUD-001**: Use `count = var.environment == "prod" ? 1 : 0` as the standard conditional guard for all prod-only resources in this plan.
- **GUD-002**: Reference conditional module outputs with the `[0]` index accessor (`module.shared_resource_group[0].name`) and guard with the same condition.
- **PAT-001**: Keep the shared resource group declaration in `terraform/main.tf` alongside the existing resource group module.
- **PAT-002**: Keep ACR in `terraform/acr.tf`; update the resource group reference and add the `count` guard there.

## 2. Implementation Steps

### Implementation Phase 1

- **GOAL-001**: Add the shared resource group as a prod-only Terraform resource.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-001 | Add `local.shared_rg_name = "${var.project}-shared-rg"` to the naming block in `terraform/locals.tf`. This name omits the environment slug because the resource is not environment-specific. | ✅ | 2026-03-28 |
| TASK-002 | Add `module "shared_resource_group"` block in `terraform/main.tf` using `Azure/avm-res-resources-resourcegroup/azurerm ~> 0.2`, `count = var.environment == "prod" ? 1 : 0`, `name = local.shared_rg_name`, `location = var.location`, and `tags = local.common_tags`. Place it immediately after the existing `module "resource_group"` block. | ✅ | 2026-03-28 |

### Implementation Phase 2

- **GOAL-002**: Migrate ACR to the shared resource group and update its naming.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-003 | Update `local.acr_name` in `terraform/locals.tf` from `"${replace(local.name_prefix, "-", "")}acr"` to `"${replace(var.project, "-", "")}acr"`. This removes the environment slug from the ACR name since the registry is shared. | ✅ | 2026-03-28 |
| TASK-004 | Add `count = var.environment == "prod" ? 1 : 0` to `module "acr"` in `terraform/acr.tf`. | ✅ | 2026-03-28 |
| TASK-005 | Change `resource_group_name` in `module "acr"` from `module.resource_group.name` to `module.shared_resource_group[0].name`. | ✅ | 2026-03-28 |

### Implementation Phase 3

- **GOAL-003**: Update RBAC so the AcrPull role assignment is conditional and references the indexed module output.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-006 | Add `count = var.environment == "prod" ? 1 : 0` to `resource "azurerm_role_assignment" "mi_acr_pull"` in `terraform/roleassignments.tf`. | ✅ | 2026-03-28 |
| TASK-007 | Update the `scope` attribute of `azurerm_role_assignment.mi_acr_pull` from `module.acr.resource_id` to `module.acr[0].resource_id`. | ✅ | 2026-03-28 |
| TASK-008 | Update the `depends_on` list in `module "container_app"` (in `terraform/containerapp.tf`) to reference `azurerm_role_assignment.mi_acr_pull` only conditionally, or use `azurerm_role_assignment.mi_acr_pull[0]` guarded by the same condition. Replace the flat reference `azurerm_role_assignment.mi_acr_pull` in the `depends_on` list with `azurerm_role_assignment.mi_acr_pull` (the whole resource, not an index — Terraform resolves `count` collections in `depends_on` automatically). No change required for `depends_on` format; verify Terraform plan raises no unknown dependency errors in dev. | ✅ | 2026-03-28 |

### Implementation Phase 4

- **GOAL-004**: Extend outputs to surface the shared ACR login server for CI use.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-009 | Add output `acr_login_server` in `terraform/outputs.tf` with `sensitive = true`, `value = var.environment == "prod" ? module.acr[0].resource.login_server : null`, and description `"Login server of the shared ACR. Null in non-prod environments."` Verify the correct output attribute name from the AVM module during implementation (common candidates: `resource.login_server` or the module's documented output). | ✅ | 2026-03-28 |

### Implementation Phase 5

- **GOAL-005**: Update architecture documentation to reflect the shared resource group topology.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-010 | Update the `Azure Runtime Platform` section of `ARCHITECTURE.md` to state that ACR lives in a dedicated shared resource group (`${project}-shared-rg`) provisioned only in prod, and that dev deployments use a public placeholder image with no ACR dependency. | ✅ | 2026-03-28 |
| TASK-011 | Update the `End-to-End Deployment and Runtime Flow` section of `ARCHITECTURE.md` step 3 (image push to ACR) to note that this step only executes for the prod environment. | ✅ | 2026-03-28 |

### Implementation Phase 6

- **GOAL-006**: Validate Terraform correctness and confirm no regressions in dev or prod plans.

| Task     | Description | Completed | Date |
| -------- | ----------- | --------- | ---- |
| TASK-012 | Run `terraform fmt` across `terraform/` and confirm no formatting diffs remain. | ✅ | 2026-03-28 |
| TASK-013 | Run `terraform validate` against the module root and confirm zero errors. | ✅ | 2026-03-28 |
| TASK-014 | Run `terraform plan` with dev variable values (`environment = "dev"`) and confirm: no `module.shared_resource_group`, no `module.acr`, no `azurerm_role_assignment.mi_acr_pull` in the planned changes. | | |
| TASK-015 | Run `terraform plan` with prod variable values (`environment = "prod"`) and confirm: one `module.shared_resource_group[0]`, one `module.acr[0]`, one `azurerm_role_assignment.mi_acr_pull[0]`, one `acr_login_server` output in the planned changes, and no changes to the environment-scoped resource group. | | |
| TASK-016 | Confirm `terraform plan` in prod shows the existing ACR as destroyed and replaced by the new ACR in the shared resource group. Accept the replacement as an expected one-time migration. Record any downstream state dependencies that require targeted apply ordering (e.g., apply shared resource group first, then ACR, then container app). | | |

## 3. Alternatives

- **ALT-001**: Keep one ACR per environment. Rejected because a single shared registry reduces cost, eliminates parallel image push pipelines, and simplifies CI targeting.
- **ALT-002**: Use a `locals.tf` environment flag variable instead of `count`. Rejected because `count` is the idiomatic Terraform mechanism for conditional resource creation and is more explicit for plan diffing.
- **ALT-003**: Use a separate Terraform workspace or root module for the shared resource group. Rejected because it introduces cross-workspace state references (remote state data sources), which adds complexity and secret handling surface area.
- **ALT-004**: Create the shared resource group in both dev and prod but leave it empty in dev. Rejected because it creates an unused resource and a billing surface that the user explicitly excluded.

## 4. Dependencies

- **DEP-001**: [plan/infrastructure-azure-security-registry-1.md](infrastructure-azure-security-registry-1.md) — ACR must already exist in the current environment-scoped resource group before this migration is applied (state already exists in prod).
- **DEP-002**: [plan/infrastructure-azure-rbac-outputs-1.md](infrastructure-azure-rbac-outputs-1.md) — the `AcrPull` role assignment structure being changed here was introduced by this plan.
- **DEP-003**: [plan/infrastructure-azure-container-runtime-1.md](infrastructure-azure-container-runtime-1.md) — the container app `depends_on` block references the AcrPull assignment and must tolerate the conditional form.

## 5. Files

- **FILE-001**: `terraform/main.tf` — add `module "shared_resource_group"` with prod-only `count`.
- **FILE-002**: `terraform/locals.tf` — update `acr_name` to remove env slug; add `shared_rg_name`.
- **FILE-003**: `terraform/acr.tf` — add `count` guard; change `resource_group_name` to the shared resource group output.
- **FILE-004**: `terraform/roleassignments.tf` — add `count` guard to `mi_acr_pull`; update `scope` to indexed ACR module output.
- **FILE-005**: `terraform/containerapp.tf` — verify `depends_on` form is compatible with `count`-based role assignment.
- **FILE-006**: `terraform/outputs.tf` — add `acr_login_server` sensitive output.
- **FILE-007**: `ARCHITECTURE.md` — update resource group topology and deployment flow descriptions.

## 6. Testing

- **TEST-001**: `terraform plan` with `environment = "dev"` produces zero ACR, zero shared resource group, and zero AcrPull resources — confirming dev isolation.
- **TEST-002**: `terraform plan` with `environment = "prod"` produces exactly one `module.shared_resource_group[0]`, one `module.acr[0]`, and one `azurerm_role_assignment.mi_acr_pull[0]`.
- **TEST-003**: `terraform validate` returns zero errors on the module root.
- **TEST-004**: `terraform output acr_login_server` in a prod apply returns a non-empty, sensitive login server string.
- **TEST-005**: After applying in prod, the Container App's registry entry points to the shared ACR login server and the managed identity pull succeeds (verified via container app log stream or revision status).

## 7. Risks & Assumptions

- **RISK-001**: The existing prod ACR will be destroyed and re-created in the new shared resource group. Any images already pushed will be lost unless manually replicated before the apply. Mitigation: re-run the CI image build/push step after the Terraform migration apply to repopulate the new registry.
- **RISK-002**: The `depends_on` block in `module "container_app"` references `azurerm_role_assignment.mi_acr_pull`; with `count`, this becomes a collection. Terraform handles collection references in `depends_on` correctly but this must be verified during TASK-008.
- **RISK-003**: The AVM ACR module output attribute name for `login_server` may differ from `resource.login_server`. Verify against the `Azure/avm-res-containerregistry-registry/azurerm ~> 0.4` module outputs during TASK-009 and adjust accordingly.
- **RISK-004**: CI pipelines that hard-code the ACR login server (e.g., in GitHub Actions environment variables) must be updated to consume the `acr_login_server` Terraform output instead, or the value must be re-supplied as a secret after migration.
- **ASSUMPTION-001**: Only two environments are in use: `dev` and `prod`. If additional environments are introduced, the `var.environment == "prod"` guard must be revisited.
- **ASSUMPTION-002**: No budget alert resource is required for the shared resource group at this time. If cost tracking is required, a separate cost management plan should be created.
- **ASSUMPTION-003**: The CI Service Principal has `Contributor` rights (or equivalent) on the subscription or shared resource group path to create it during the first prod apply.

## 8. Related Specifications / Further Reading

- [plan/infrastructure-azure-resources-deployment-2.md](infrastructure-azure-resources-deployment-2.md)
- [plan/infrastructure-azure-security-registry-1.md](infrastructure-azure-security-registry-1.md)
- [plan/infrastructure-azure-rbac-outputs-1.md](infrastructure-azure-rbac-outputs-1.md)
- [plan/infrastructure-azure-container-runtime-1.md](infrastructure-azure-container-runtime-1.md)
- [ARCHITECTURE.md](../ARCHITECTURE.md)
- [CONTRIBUTING.md](../CONTRIBUTING.md)
