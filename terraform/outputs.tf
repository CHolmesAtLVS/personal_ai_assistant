output "acr_login_server" {
  description = "Login server of the shared ACR. Null in non-prod environments."
  sensitive   = true
  value       = var.environment == "prod" ? module.acr[0].resource.login_server : null
}

output "container_app_fqdn" {
  description = "FQDN of the deployed OpenClaw Container App."
  sensitive   = true
  value       = module.container_app.fqdn_url
}

output "azure_openai_endpoint" {
  description = "Azure OpenAI Legacy API endpoint URL (openai.azure.com) for the AI Services account."
  sensitive   = true
  value       = local.azure_openai_endpoint
}

output "ai_services_endpoint" {
  description = "Endpoint URL for the AI Services account."
  sensitive   = true
  value       = tostring(data.azapi_resource.ai_foundry.output.properties.endpoint)
}

output "openclaw_state_storage_account_name" {
  description = "Storage account name that hosts the OpenClaw state Azure Files share."
  value       = azurerm_storage_account.openclaw_state.name
}

output "openclaw_state_file_share_name" {
  description = "Azure Files share name mounted to /home/node/.openclaw."
  value       = azurerm_storage_share.openclaw_state.name
}

output "embedding_deployment_name" {
  description = "Deployment name for the text embedding model (driven by var.embedding_model_name)."
  value       = var.embedding_model_name
}

output "codex_deployment_name" {
  description = "Deployment name for the codex model (driven by var.codex_model_name)."
  value       = var.codex_model_name
}
