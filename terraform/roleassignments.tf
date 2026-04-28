# AcrPull is only created when ACR exists (prod only).
resource "azurerm_role_assignment" "mi_acr_pull" {
  for_each = var.environment == "prod" ? local.instances : toset([])

  scope                = module.acr[0].resource_id
  role_definition_name = "AcrPull"
  principal_id         = module.identity[each.key].principal_id
}

resource "azurerm_role_assignment" "mi_kv_secrets_user" {
  for_each = local.instances

  scope                = module.key_vault.resource_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = module.identity[each.key].principal_id
}

resource "azurerm_role_assignment" "mi_ai_openai_user" {
  for_each = local.instances

  scope                = module.ai_foundry.resource_id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = module.identity[each.key].principal_id
}

# Grants the Managed Identity access to the Azure AI Model Inference endpoint
# (required for Grok/xAI models served via services.ai.azure.com/models).
# Cognitive Services OpenAI User only covers the openai.azure.com endpoint;
# Cognitive Services User covers all Cognitive Services APIs including AI Inference.
resource "azurerm_role_assignment" "mi_ai_inference_user" {
  for_each = local.instances

  scope                = module.ai_foundry.resource_id
  role_definition_name = "Cognitive Services User"
  principal_id         = module.identity[each.key].principal_id
}

# Grants the CI/CD Service Principal write access to Key Vault secrets so
# Terraform can manage the openclaw-gateway-token secret (azurerm_key_vault_secret).
# Uses var.ci_sp_object_id (set in central tfvars) so this assignment always targets
# the CI SP regardless of who runs Terraform locally. The CI SP object ID is stored
# in the central tfvars file in Azure Blob Storage and never committed to source code.
resource "azurerm_role_assignment" "ci_sp_kv_secrets_officer" {
  scope                = module.key_vault.resource_id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.ci_sp_object_id
}
