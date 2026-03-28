# AcrPull is only created when ACR exists (prod only).
resource "azurerm_role_assignment" "mi_acr_pull" {
  count                = var.environment == "prod" ? 1 : 0
  scope                = module.acr[0].resource_id
  role_definition_name = "AcrPull"
  principal_id         = module.identity.principal_id
}

resource "azurerm_role_assignment" "mi_kv_secrets_user" {
  scope                = module.key_vault.resource_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.identity.principal_id
}

resource "azurerm_role_assignment" "mi_ai_openai_user" {
  scope                = module.ai_foundry.resource_id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = module.identity.principal_id
}
