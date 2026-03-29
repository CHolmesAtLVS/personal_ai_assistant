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
