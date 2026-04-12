data "azurerm_client_config" "current" {}

module "key_vault" {
  source  = "Azure/avm-res-keyvault-vault/azurerm"
  version = "~> 0.9"

  name                = local.kv_name
  location            = var.location
  resource_group_name = module.resource_group.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  tags                = local.common_tags

  enable_telemetry = true

  sku_name                       = "standard"
  legacy_access_policies_enabled = false
  network_acls                   = null

  diagnostic_settings = {
    law = {
      workspace_resource_id = module.logging.resource_id
    }
  }
}

# Generates a stable 48-character hex token per instance on first deploy.
# Values are stored in Terraform state (sensitive) and never regenerated
# unless explicitly replaced. Manual KV rotation is preserved by the
# ignore_changes lifecycle rule on the secret resources.
resource "random_id" "openclaw_gateway_token" {
  for_each = local.instances

  byte_length = 24
}

resource "azurerm_key_vault_secret" "openclaw_gateway_token" {
  for_each = local.instances

  name         = "${each.key}-openclaw-gateway-token"
  value        = random_id.openclaw_gateway_token[each.key].hex
  key_vault_id = module.key_vault.resource_id
  content_type = "text/plain"

  # Prevent Terraform from overwriting a token that was manually rotated.
  lifecycle {
    ignore_changes = [value]
  }

  # The CI SP must hold Key Vault Secrets Officer before this resource can be
  # created. The role assignment is managed by Terraform in the same apply;
  # RBAC propagation may require a retry on a brand-new environment.
  depends_on = [azurerm_role_assignment.ci_sp_kv_secrets_officer]
}

resource "azurerm_key_vault_secret" "azure_ai_api_key" {
  name         = "azure-ai-api-key"
  value        = "placeholder-set-manually-in-azure-key-vault"
  key_vault_id = module.key_vault.resource_id
  content_type = "text/plain"

  # The azure-ai-api-key secret value is set manually in Azure Key Vault and
  # is never written by Terraform after initial resource creation.
  # ignore_changes = [value] ensures Terraform never overwrites the real key,
  # and the placeholder above is only used when creating the secret for the
  # first time in a fresh environment (it must then be updated manually).
  lifecycle {
    ignore_changes = [value]
  }

  depends_on = [azurerm_role_assignment.ci_sp_kv_secrets_officer]
}
