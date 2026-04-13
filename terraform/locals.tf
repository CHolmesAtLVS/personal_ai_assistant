locals {
  name_prefix = "${var.project}-${var.environment}"

  required_tags = {
    project     = var.project
    environment = var.environment
    owner       = var.owner
    managed_by  = "CHolmesAtLVS\\personal_ai_assistant"
  }

  common_tags = merge(local.required_tags, var.extra_tags)
}

locals {
  # Resource name locals derived from name_prefix = "{project}-{environment}".
  # Key Vault constraint: 3-24 chars, alphanumeric and hyphens only.
  # ACR constraint: 5-50 chars, alphanumeric only (no hyphens).
  law_name          = "${local.name_prefix}-law"
  identity_name     = "${local.name_prefix}-id"
  kv_name           = "${local.name_prefix}-kv"
  acr_name          = "${replace(var.project, "-", "")}sharedacr"
  shared_rg_name    = "${var.project}-shared-rg"
  ai_hub_name       = "${local.name_prefix}-hub"
  ai_project_name   = "${local.name_prefix}-proj"
  budget_name       = "${local.name_prefix}-budget"
  action_group_name = "${local.name_prefix}-ag-cost"
}

locals {
  instances = toset(var.openclaw_instances)

  instance_identity_name = {
    for inst in var.openclaw_instances : inst => "${local.name_prefix}-${inst}-id"
  }
}
