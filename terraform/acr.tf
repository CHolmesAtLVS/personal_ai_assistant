# ACR is deployed only in the prod environment into the shared resource group.
# Dev deployments use a public placeholder image and do not require a registry.
module "acr" {
  source  = "Azure/avm-res-containerregistry-registry/azurerm"
  version = "~> 0.4"
  count   = var.environment == "prod" ? 1 : 0

  name                = local.acr_name
  location            = var.location
  resource_group_name = module.shared_resource_group[0].name
  tags                = local.common_tags

  enable_telemetry = true

  sku                     = "Standard"
  admin_enabled           = false
  zone_redundancy_enabled = false

  diagnostic_settings = {
    law = {
      workspace_resource_id = module.logging.resource_id
    }
  }
}
