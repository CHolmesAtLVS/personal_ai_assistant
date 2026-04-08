# Premium FileStorage storage account for the OpenClaw NFS share.
# NFS protocol requires account_kind = "FileStorage" and account_tier = "Premium".
# https_traffic_only_enabled must be false: NFS protocol does not use HTTPS.
# The existing standard-tier storage account (storage.tf) is preserved for ACA
# until ACA is decommissioned (see plan/feature-aks-decommission-1.md).
resource "azurerm_storage_account" "openclaw_nfs" {
  name                     = local.openclaw_nfs_storage_account_name
  resource_group_name      = module.resource_group.name
  location                 = var.location
  account_tier             = "Premium"
  account_kind             = "FileStorage"
  account_replication_type = "LRS"
  tags                     = local.common_tags

  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = true
  https_traffic_only_enabled      = false
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true
}

resource "azurerm_storage_share" "openclaw_nfs" {
  name               = "openclaw-nfs"
  storage_account_id = azurerm_storage_account.openclaw_nfs.id
  quota              = var.openclaw_state_share_quota_gb
  enabled_protocol   = "NFS"
}
