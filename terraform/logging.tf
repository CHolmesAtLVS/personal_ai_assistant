module "logging" {
  source  = "Azure/avm-res-operationalinsights-workspace/azurerm"
  version = "~> 0.4"

  name                = local.law_name
  location            = var.location
  resource_group_name = module.resource_group.name
  tags                = local.common_tags
  enable_telemetry    = true

  log_analytics_workspace_retention_in_days = 30 # AVM ~> 0.4 enforces 30-730 day range; 30 is the minimum
  # TODO: upgrade avm-res-operationalinsights-workspace to expose daily_quota_gb
  # and add daily_quota_gb = 0.5 (500 MB/day cap) when the module version supports it.
}
