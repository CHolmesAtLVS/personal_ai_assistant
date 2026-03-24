locals {
  name_prefix = "${var.project}-${var.environment}"

  required_tags = {
    project     = var.project
    environment = var.environment
    owner       = var.owner
    cost_center = var.cost_center
    managed_by  = "CHolmesAtLVS\\personal_ai_assistant"
  }

  common_tags = merge(local.required_tags, var.extra_tags)
}
