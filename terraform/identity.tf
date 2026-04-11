module "identity" {
  source  = "Azure/avm-res-managedidentity-userassignedidentity/azurerm"
  version = "~> 0.3"

  for_each = local.instances

  name                = local.instance_identity_name[each.key]
  location            = var.location
  resource_group_name = module.resource_group.name
  tags                = local.common_tags
  enable_telemetry    = true
}
