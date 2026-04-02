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

# Grants the Managed Identity access to the Azure AI Model Inference endpoint
# (required for Grok/xAI models served via services.ai.azure.com/models).
# Cognitive Services OpenAI User only covers the openai.azure.com endpoint;
# Cognitive Services User covers all Cognitive Services APIs including AI Inference.
resource "azurerm_role_assignment" "mi_ai_inference_user" {
  scope                = module.ai_foundry.resource_id
  role_definition_name = "Cognitive Services User"
  principal_id         = module.identity.principal_id
}

# Grants the CI/CD Service Principal write access to Key Vault secrets so
# Terraform can manage the openclaw-gateway-token secret (azurerm_key_vault_secret).
# Bound to the object ID of the identity running Terraform (the CI SP in CI/CD;
# a developer's identity when running locally). Scope is the environment Key Vault.
resource "azurerm_role_assignment" "ci_sp_kv_secrets_officer" {
  scope                = module.key_vault.resource_id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Grants the Managed Identity Storage Blob Data Contributor on the openclaw-state blob
# container only (least-privilege — not on the entire storage account).
# Required by the azcopy sidecar container for outbound sync (EmptyDir → Blob).
# SEC-001: scoped to the blob container resource, not the storage account.
resource "azurerm_role_assignment" "mi_state_blob_contributor" {
  scope                = azurerm_storage_container.openclaw_state_blob.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = module.identity.principal_id
}
