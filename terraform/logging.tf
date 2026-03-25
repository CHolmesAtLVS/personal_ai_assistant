module "logging" {
  source  = "Azure/avm-res-operationalinsights-workspace/azurerm"
  version = "~> 0.4"

  name                = local.law_name
  location            = var.location
  resource_group_name = module.resource_group.name
  tags                = local.common_tags
  enable_telemetry    = true

  log_analytics_workspace_retention_in_days = 30
}
