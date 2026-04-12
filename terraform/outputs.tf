output "acr_login_server" {
  description = "Login server of the shared ACR. Null in non-prod environments."
  sensitive   = true
  value       = var.environment == "prod" ? module.acr[0].resource.login_server : null
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

output "embedding_deployment_name" {
  description = "Deployment name for the text embedding model (driven by var.embedding_model_name)."
  value       = var.embedding_model_name
}

output "aks_cluster_name" {
  description = "Name of the AKS cluster."
  sensitive   = false
  value       = module.aks.name
}

output "aks_oidc_issuer_url" {
  description = "OIDC issuer URL for the AKS cluster (used for Workload Identity federation)."
  sensitive   = true
  value       = module.aks.oidc_issuer_profile_issuer_url
}

output "aks_node_resource_group" {
  description = "Name of the AKS node resource group."
  sensitive   = false
  value       = module.aks.node_resource_group_name
}

output "instance_mi_client_ids" {
  description = "Map of instance name to Managed Identity client ID."
  sensitive   = true
  value       = { for inst, m in module.identity : inst => m.client_id }
}

output "kv_name" {
  description = "Name of the Key Vault holding per-instance gateway token secrets."
  sensitive   = true
  value       = local.kv_name
}
