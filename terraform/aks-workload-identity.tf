resource "azurerm_federated_identity_credential" "openclaw" {
  for_each = local.instances

  name                = "openclaw-aks-${var.environment}-${each.key}"
  resource_group_name = module.resource_group.name
  parent_id           = module.identity[each.key].resource_id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = module.aks.oidc_issuer_profile_issuer_url
  subject             = "system:serviceaccount:openclaw-${each.key}:openclaw"
}

# The Managed Identity already holds Key Vault Secrets User (see roleassignments.tf).
# No new Key Vault role assignment is required for Workload Identity — the existing
# role binding applies via the same MI client ID when tokens are exchanged via OIDC.
