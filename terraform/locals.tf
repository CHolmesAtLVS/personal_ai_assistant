locals {
  name_prefix    = "${var.project}-${var.environment}"
  openclaw_image = "${var.openclaw_image_repository}:${var.openclaw_image_tag}"

  required_tags = {
    project     = var.project
    environment = var.environment
    owner       = var.owner
    managed_by  = "CHolmesAtLVS\\personal_ai_assistant"
  }

  common_tags = merge(local.required_tags, var.extra_tags)
}

locals {
  # Resource name locals.
  # Key Vault constraint: 3-24 chars, alphanumeric and hyphens only.
  # ACR constraint: 5-50 chars, alphanumeric only (no hyphens).
  law_name                            = "${local.name_prefix}-law"
  identity_name                       = "${local.name_prefix}-id"
  kv_name                             = "${local.name_prefix}-kv"
  acr_name                            = "${replace(var.project, "-", "")}sharedacr"
  shared_rg_name                      = "${var.project}-shared-rg"
  ai_hub_name                         = "${local.name_prefix}-hub"
  ai_project_name                     = "${local.name_prefix}-proj"
  cae_name                            = "${local.name_prefix}-cae"
  app_name                            = "${local.name_prefix}-app"
  budget_name                         = "${local.name_prefix}-budget"
  action_group_name                   = "${local.name_prefix}-ag-cost"
  openclaw_state_storage_account_name = substr(replace("${var.project}${var.environment}ocstate", "-", ""), 0, 24)
  openclaw_state_file_share_name      = "openclaw-state"
  openclaw_backup_file_share_name     = "openclaw-backup"
}
