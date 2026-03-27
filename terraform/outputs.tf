output "container_app_fqdn" {
  description = "FQDN of the deployed OpenClaw Container App."
  value       = module.container_app.resource.ingress[0].fqdn
}

output "ai_services_endpoint" {
  description = "Endpoint URL for the AI Services account."
  value       = tostring(data.azapi_resource.ai_foundry.output.properties.endpoint)
}
