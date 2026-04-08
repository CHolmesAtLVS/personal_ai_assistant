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

# Azure Files NFS shares use network-level (POSIX) authentication, not Azure RBAC data-plane
# roles. Storage Account Contributor is granted so the CSI driver can enumerate file shares
# and retrieve account metadata when establishing the NFS mount via Workload Identity.
resource "azurerm_role_assignment" "aks_files_contributor" {
  scope                = azurerm_storage_account.openclaw_nfs.id
  role_definition_name = "Storage Account Contributor"
  principal_id         = module.identity.principal_id
}
