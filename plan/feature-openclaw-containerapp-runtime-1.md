---
goal: Deploy OpenClaw on Azure Container Apps using a pinned pre-built Docker image with durable state and gateway-safe configuration
plan_type: standalone
version: 1.0
date_created: 2026-03-29
last_updated: 2026-03-29
owner: Platform Engineering
status: Planned
tags: [feature, azure-container-apps, terraform, persistence, gateway, documentation]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

This plan migrates runtime deployment to the official pre-built OpenClaw image and hardens the Azure Container Apps runtime for persistence and gateway correctness. It implements pinned image versioning, Azure Files-backed persistent storage mapped to OpenClaw state paths, and deterministic gateway configuration for bind/auth/control UI origins. The plan also updates architecture and operations documentation to match the new runtime model.

## 1. Requirements & Constraints

- **REQ-001**: Deploy OpenClaw from the pre-built image repository `ghcr.io/openclaw/openclaw` instead of a locally built image.
- **REQ-002**: Pin the image to an explicit version tag (initial value: `2026.2.26`) and disallow `latest` in Terraform defaults and examples.
- **REQ-003**: Keep Terraform as the authoritative infrastructure mechanism; all Azure runtime changes must be declarative in Terraform.
- **REQ-004**: Persist OpenClaw long-lived state at `/home/node/.openclaw` so config, auth profiles, skills state, and workspace (`/home/node/.openclaw/workspace`) survive revisions and restarts.
- **REQ-005**: Gateway configuration must be explicit and schema-valid to avoid startup failure under strict config validation.
- **REQ-006**: Gateway bind mode must be compatible with Container Apps ingress; use `gateway.bind = "lan"`.
- **REQ-007**: Gateway authentication must remain enabled for non-loopback operation; use token auth and source the token from environment/secret.
- **REQ-008**: Control UI origins must be explicitly allowlisted for the deployed HTTPS origin(s) used by operators.
- **REQ-009**: Keep HTTPS ingress and home-IP restriction unchanged unless an explicit follow-up requirement modifies networking.
- **REQ-010**: Include storage sizing and growth controls for known hotspots (`media/`, session JSONL files, `cron/runs/*.jsonl`, and logs).
- **REQ-011**: Document operational runbook for bootstrap, rotation, backup/restore, and upgrade behavior with pinned image versions.
- **SEC-001**: Do not commit secrets, tokens, tenant/subscription identifiers, Entra IDs, DNS names, or other deployment identifiers to repository files.
- **SEC-002**: Keep Managed Identity as the preferred Azure authentication path.
- **SEC-003**: Store gateway token and other runtime secrets in Key Vault; inject into Container App through secret references.
- **CON-001**: Use existing Terraform module style and naming conventions already established in `terraform/*.tf`.
- **CON-002**: Minimize blast radius by limiting Terraform changes to variables, storage resources, container app template/secret/env wiring, and outputs.
- **GUD-001**: Follow OpenClaw runtime path semantics from Docker docs (`/home/node/.openclaw` as source of truth) when mapping persistent storage.
- **GUD-002**: Use deterministic image version bump workflow (single variable/value change per release).
- **PAT-001**: Prefer one persistent mount at `/home/node/.openclaw` to cover all required persistent subpaths unless performance testing proves split shares are required.

## 2. Implementation Steps

### Implementation Phase 1

- GOAL-001: Establish pinned pre-built image inputs and remove mutable image defaults.

| Task | Description | Completed | Date |
| -------- | --------------------- | --------- | ---------- |
| TASK-001 | Update `terraform/variables.tf`: replace mutable defaults with explicit pre-built image variables. Add `openclaw_image_repository` default `ghcr.io/openclaw/openclaw`; add `openclaw_image_tag` default `2026.2.26`; remove default use of `latest`; keep `container_image` only as computed value or deprecate it explicitly with validation. |  |  |
| TASK-002 | Update `terraform/locals.tf`: derive canonical image string `local.openclaw_image = "${var.openclaw_image_repository}:${var.openclaw_image_tag}"` and ensure all container app image references use this local. |  |  |
| TASK-003 | Update `terraform/containerapp.tf`: replace `image = var.container_image` with `image = local.openclaw_image` in `module "container_app" -> template -> containers[0]`. |  |  |
| TASK-004 | Update `scripts/dev.tfvars.example` and `scripts/prod.tfvars.example`: add pinned `openclaw_image_tag` value examples and remove `latest` examples. |  |  |
| TASK-005 | Update CI variable usage references (if present) to pass `TF_VAR_openclaw_image_tag` instead of mutable `TF_VAR_CONTAINER_IMAGE_TAG` naming; keep one canonical variable key across workflows and docs. |  |  |

### Implementation Phase 2

- GOAL-002: Implement durable OpenClaw state persistence in Azure Container Apps.

| Task | Description | Completed | Date |
| -------- | --------------------- | --------- | ---------- |
| TASK-006 | Add Azure Storage Account and Azure File Share resources in Terraform for OpenClaw state persistence. Create one share dedicated to OpenClaw state (for example `openclaw-state`) sized for expected workspace/media/log growth. Implement in a new Terraform file `terraform/storage.tf`. |  |  |
| TASK-007 | Add storage account hardening defaults in `terraform/storage.tf`: minimum TLS, public network access aligned with current project policy, and tags from `local.common_tags`. |  |  |
| TASK-008 | Add Container Apps storage binding for Azure Files in `terraform/containerapp.tf`: configure a named volume using the Azure File Share and mount it at `/home/node/.openclaw` in the OpenClaw container definition. |  |  |
| TASK-009 | Add Key Vault-managed secret for Azure Files access key if module wiring requires key-based share auth; wire secret reference into Container App secret block without exposing value in Terraform state outputs. |  |  |
| TASK-010 | Add configurable capacity/retention variables in `terraform/variables.tf` for storage planning (for example `openclaw_state_share_quota_gb`), with validation bounds and documented defaults. |  |  |
| TASK-011 | Add outputs in `terraform/outputs.tf` for non-sensitive operational references (storage account/share names), mark sensitive metadata appropriately per project policy. |  |  |

### Implementation Phase 3

- GOAL-003: Configure gateway runtime for Container Apps with strict-schema-safe settings.

| Task | Description | Completed | Date |
| -------- | --------------------- | --------- | ---------- |
| TASK-012 | Define required runtime env/secret injection in `terraform/containerapp.tf` for gateway operation: `OPENCLAW_GATEWAY_TOKEN` (secret ref), `OPENCLAW_GATEWAY_BIND=lan`, and any required OpenClaw startup env keys confirmed in docs. |  |  |
| TASK-013 | Add a managed config bootstrap artifact in repository docs and plan to place it on the persisted mount as `/home/node/.openclaw/openclaw.json` containing schema-valid baseline gateway config: `gateway.mode`, `gateway.port`, `gateway.bind`, `gateway.auth.mode=token`, `gateway.auth.token=${OPENCLAW_GATEWAY_TOKEN}`, and `gateway.controlUi.allowedOrigins`. |  |  |
| TASK-014 | Define deterministic bootstrap process for first deploy (non-interactive): one of (A) one-time `az containerapp exec` command sequence using `openclaw config set`, or (B) pre-seeding config file in Azure File Share before app start. Select one method and document exact command sequence and rollback. |  |  |
| TASK-015 | Add origin allowlist variable in `terraform/variables.tf` (for example `openclaw_control_ui_allowed_origins_json`) and wire it into config generation/bootstrap so Control UI works only for explicit HTTPS origins. |  |  |
| TASK-016 | Ensure health probes remain aligned with OpenClaw endpoints (`/healthz`, `/readyz`) and are configured in Container App template if currently absent. |  |  |

### Implementation Phase 4

- GOAL-004: Align platform and contributor documentation with the new runtime model.

| Task | Description | Completed | Date |
| -------- | --------------------- | --------- | ---------- |
| TASK-017 | Update `ARCHITECTURE.md` with final runtime design: pinned GHCR image, persistence via Azure Files mounted at `/home/node/.openclaw`, gateway token/auth model, and bootstrap flow for strict config validation. |  |  |
| TASK-018 | Update `PRODUCT.md` to reflect persistence guarantees and operational expectations for user data and workspace durability across revisions/restarts. |  |  |
| TASK-019 | Update `CONTRIBUTING.md` with release procedure for image version bumps, validation steps for storage/gateway changes, and explicit rule prohibiting `latest` tag in Terraform defaults/examples. |  |  |
| TASK-020 | Update `readme.md` deployment section with operator runbook summary: required secrets, first-time bootstrap, volume persistence behavior, and upgrade steps using pinned tag changes. |  |  |
| TASK-021 | Update `docs/secrets-inventory.md` to include any new secret names used for gateway token and storage key references (names only, no values), and clarify ownership/rotation cadence. |  |  |
| TASK-022 | Create `docs/openclaw-containerapp-operations.md` documenting backup/restore of persisted state, token rotation, config updates, and safe image upgrade/rollback steps. |  |  |

### Implementation Phase 5

- GOAL-005: Validate runtime behavior, persistence, and operability end-to-end.

| Task | Description | Completed | Date |
| -------- | --------------------- | --------- | ---------- |
| TASK-023 | Run `terraform fmt`, `terraform validate`, and `terraform plan` for dev and prod variable sets; confirm only expected deltas (image/persistence/gateway wiring). |  |  |
| TASK-024 | Deploy to dev and verify gateway startup succeeds with strict config validation (no schema errors), and `/healthz` + `/readyz` respond successfully through Container App endpoint. |  |  |
| TASK-025 | Validate persistence: create sentinel files under `/home/node/.openclaw` and `/home/node/.openclaw/workspace`, roll new revision, and confirm files remain present. |  |  |
| TASK-026 | Validate gateway auth: unauthenticated access to protected surfaces is denied; token-authenticated Control UI/API access succeeds from allowlisted origin only. |  |  |
| TASK-027 | Validate upgrade path: bump `openclaw_image_tag` from `2026.2.26` to next pinned release in a test branch, deploy, and confirm rollback by reverting only tag value restores previous runtime behavior without data loss. |  |  |
| TASK-028 | Capture operational evidence and update plan status to `In progress` or `Completed` based on verification outcomes. |  |  |

## 3. Alternatives

- **ALT-001**: Continue building custom images in CI and push to ACR. Rejected because requirement is to run from OpenClaw pre-built image and reduce build pipeline complexity.
- **ALT-002**: Use ephemeral Container App filesystem only. Rejected because OpenClaw persistence model requires durable `/home/node/.openclaw` data.
- **ALT-003**: Persist only `/home/node/.openclaw/workspace`. Rejected because OpenClaw also persists config, tokens, skills state, and auth profiles under parent path.
- **ALT-004**: Use `latest` image tag with frequent pulls. Rejected because mutable tags break deterministic deployments and rollback integrity.
- **ALT-005**: Keep gateway auth disabled behind IP restriction only. Rejected because non-loopback gateway mode requires defense-in-depth and explicit auth controls.
- **ALT-006**: Split persistence into multiple file shares immediately. Deferred; single-share mount minimizes complexity and can be split later based on measured IO/retention pressure.

## 4. Dependencies

- **DEP-001**: Existing Azure Container Apps environment and OpenClaw Container App resources in Terraform state.
- **DEP-002**: Existing Key Vault and Managed Identity role assignments remain functional.
- **DEP-003**: Terraform provider capabilities for Azure File Share + Container App volume mounts in current module/provider versions.
- **DEP-004**: Access to GHCR image `ghcr.io/openclaw/openclaw:<pinned-version>` from Container Apps runtime network path.
- **DEP-005**: Operator-provided control UI origin values and gateway token secret at deploy time.

## 5. Files

- **FILE-001**: `terraform/variables.tf` — new pinned image and gateway/persistence variables.
- **FILE-002**: `terraform/locals.tf` — canonical computed image string local.
- **FILE-003**: `terraform/containerapp.tf` — image reference swap, storage mount wiring, gateway env/secret wiring, probes.
- **FILE-004**: `terraform/storage.tf` — new storage account/file share resources for persistence.
- **FILE-005**: `terraform/outputs.tf` — operational outputs for storage/image runtime metadata.
- **FILE-006**: `scripts/dev.tfvars.example` — pinned image tag and persistence variable examples.
- **FILE-007**: `scripts/prod.tfvars.example` — pinned image tag and persistence variable examples.
- **FILE-008**: `ARCHITECTURE.md` — runtime architecture updates.
- **FILE-009**: `PRODUCT.md` — persistence/user behavior updates.
- **FILE-010**: `CONTRIBUTING.md` — contribution/release policy updates for pinned image workflow.
- **FILE-011**: `readme.md` — deployment and operations updates.
- **FILE-012**: `docs/secrets-inventory.md` — secret inventory updates.
- **FILE-013**: `docs/openclaw-containerapp-operations.md` — new detailed operational runbook.

## 6. Testing

- **TEST-001**: Terraform static validation passes (`fmt`, `validate`) with no new warnings/errors.
- **TEST-002**: Plan output confirms image reference uses pinned tag and no `latest` remains in runtime config.
- **TEST-003**: Container App starts successfully with mounted persistent volume and healthy probes.
- **TEST-004**: State persistence survives revision replacement and restart for files under `/home/node/.openclaw`.
- **TEST-005**: Gateway strict validation passes for baseline config; malformed config test fails as expected and recovers with corrected config.
- **TEST-006**: Auth token enforcement works for gateway access paths.
- **TEST-007**: Control UI allowed origins enforcement blocks non-allowlisted origin requests.
- **TEST-008**: Upgrade/rollback drill using image tag-only changes succeeds without persistent data loss.

## 7. Risks & Assumptions

- **RISK-001**: Azure File Share latency may affect high-volume workspace/media operations; monitor and tune quota/retention.
- **RISK-002**: Incorrect gateway baseline config can prevent startup due to strict schema enforcement.
- **RISK-003**: If Control UI origin list is incomplete, operators may lose UI access until config is corrected.
- **RISK-004**: Pre-built image version may alter defaults between releases; release notes review is required before each bump.
- **ASSUMPTION-001**: The pinned tag `2026.2.26` remains available in GHCR for the deployment lifecycle.
- **ASSUMPTION-002**: Current AVM/module/provider versions support required Container App volume mount and secret wiring semantics.
- **ASSUMPTION-003**: Existing ingress restrictions (home IP allowlist + HTTPS) remain the intended security posture for this phase.

## 8. Related Specifications / Further Reading

- https://docs.openclaw.ai/install/docker
- https://docs.openclaw.ai/install/docker-vm-runtime#what-persists-where
- https://docs.openclaw.ai/gateway/configuration
- https://docs.openclaw.ai/gateway/configuration-reference
- [ARCHITECTURE.md](../ARCHITECTURE.md)
- [PRODUCT.md](../PRODUCT.md)
- [CONTRIBUTING.md](../CONTRIBUTING.md)
