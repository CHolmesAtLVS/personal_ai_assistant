resource "azurerm_storage_account" "openclaw_state" {
  name                     = local.openclaw_state_storage_account_name
  resource_group_name      = module.resource_group.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = local.common_tags

  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = true
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true
}

resource "azurerm_storage_share" "openclaw_state" {
  name               = local.openclaw_state_file_share_name
  storage_account_id = azurerm_storage_account.openclaw_state.id
  quota              = var.openclaw_state_share_quota_gb
}

resource "azurerm_key_vault_secret" "openclaw_state_storage_access_key" {
  name         = "${local.name_prefix}-openclaw-state-storage-key"
  value        = azurerm_storage_account.openclaw_state.primary_access_key
  key_vault_id = module.key_vault.resource_id
  tags         = local.common_tags
}

resource "azurerm_container_app_environment_storage" "openclaw_state" {
  name                         = "openclaw-state"
  container_app_environment_id = module.container_apps_environment.resource_id
  account_name                 = azurerm_storage_account.openclaw_state.name
  access_key                   = azurerm_storage_account.openclaw_state.primary_access_key
  share_name                   = azurerm_storage_share.openclaw_state.name
  access_mode                  = "ReadWrite"
}
