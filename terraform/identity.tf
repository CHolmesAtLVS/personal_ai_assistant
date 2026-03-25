module "identity" {
  source  = "Azure/avm-res-managedidentity-userassignedidentity/azurerm"
  version = "~> 0.3"

  name                = local.identity_name
  location            = var.location
  resource_group_name = module.resource_group.name
  tags                = local.common_tags
  enable_telemetry    = true
}
