module "acr" {
  source  = "Azure/avm-res-containerregistry-registry/azurerm"
  version = "~> 0.4"

  name                = local.acr_name
  location            = var.location
  resource_group_name = module.resource_group.name
  tags                = local.common_tags

  enable_telemetry = true

  sku           = "Standard"
  admin_enabled = false

  diagnostic_settings = {
    law = {
      workspace_resource_id = module.logging.resource_id
    }
  }
}
