# Dedicated managed identity for the AKS cluster control plane.
# Separate from per-instance workload identities — AKS requires exactly one
# user-assigned identity; workload pods federate via their own per-instance MIs.
module "aks_identity" {
  source  = "Azure/avm-res-managedidentity-userassignedidentity/azurerm"
  version = "~> 0.3"

  name                = local.identity_name
  location            = var.location
  resource_group_name = module.resource_group.name
  tags                = local.common_tags
  enable_telemetry    = true
}

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
