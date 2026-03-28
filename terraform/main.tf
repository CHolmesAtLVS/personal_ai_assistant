# This file is the extension point for all future Azure resource deployments.
# Add each new resource type here as an AVM module call when available,
# or a direct azurerm_* resource only when no AVM exists.
module "resource_group" {
  source  = "Azure/avm-res-resources-resourcegroup/azurerm"
  version = "~> 0.2"

  name     = "${local.name_prefix}-rg"
  location = var.location
  tags     = local.common_tags
}

# Shared resource group hosts resources that are environment-agnostic (e.g. ACR).
# Provisioned only in prod; dev deployments use a public placeholder image.
module "shared_resource_group" {
  source  = "Azure/avm-res-resources-resourcegroup/azurerm"
  version = "~> 0.2"
  count   = var.environment == "prod" ? 1 : 0

  name     = local.shared_rg_name
  location = var.location
  tags     = local.common_tags
}
