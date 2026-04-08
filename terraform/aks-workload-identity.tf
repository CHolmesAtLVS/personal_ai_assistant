resource "azurerm_federated_identity_credential" "openclaw" {
  name                = "openclaw-aks-${var.environment}"
  resource_group_name = module.resource_group.name
  parent_id           = module.identity.resource_id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = module.aks.oidc_issuer_profile_issuer_url
  subject             = "system:serviceaccount:openclaw:openclaw"
}

# The Managed Identity already holds Key Vault Secrets User (see roleassignments.tf).
# No new Key Vault role assignment is required for Workload Identity — the existing
# role binding applies via the same MI client ID when tokens are exchanged via OIDC.

resource "azurerm_role_assignment" "aks_files_contributor" {
  scope                = "${azurerm_storage_account.openclaw_nfs.id}/fileServices/default/shares/${azurerm_storage_share.openclaw_nfs.name}"
  role_definition_name = "Storage File Data NFS Share Contributor"
  principal_id         = module.identity.principal_id
}
