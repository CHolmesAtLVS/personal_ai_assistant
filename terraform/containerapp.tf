data "azapi_resource" "ai_foundry" {
  resource_id            = module.ai_foundry.resource_id
  type                   = "Microsoft.CognitiveServices/accounts@2023-05-01"
  response_export_values = ["properties.endpoint", "properties.endpoints"]

  depends_on = [module.ai_foundry]
}

locals {
  # Azure AI Model Inference endpoint for Grok (xAI) models.
  # Key "Azure AI Model Inference API" is the standard name in properties.endpoints.
  # Confirm with az resource show or the Azure portal if the apply fails on this reference.
  ai_inference_endpoint = format(
    "%s/models",
    trimsuffix(tostring(data.azapi_resource.ai_foundry.output.properties.endpoints["Azure AI Model Inference API"]), "/")
  )
}

module "container_apps_environment" {
  source  = "Azure/avm-res-app-managedenvironment/azurerm"
  version = "~> 0.3"

  name                = local.cae_name
  location            = var.location
  resource_group_name = module.resource_group.name
  tags                = local.common_tags

  enable_telemetry = true

  zone_redundancy_enabled = false

  log_analytics_workspace = {
    resource_id = module.logging.resource_id
  }
}

module "container_app" {
  source  = "Azure/avm-res-app-containerapp/azurerm"
  version = "~> 0.3"

  name                                  = local.app_name
  resource_group_name                   = module.resource_group.name
  container_app_environment_resource_id = module.container_apps_environment.resource_id
  revision_mode                         = "Single"
  tags                                  = local.common_tags

  depends_on = [
    azurerm_role_assignment.mi_acr_pull,
    azurerm_role_assignment.mi_kv_secrets_user,
    azurerm_role_assignment.mi_ai_openai_user,
    azurerm_role_assignment.mi_ai_inference_user,
  ]

  enable_telemetry = true

  managed_identities = {
    user_assigned_resource_ids = toset([module.identity.resource_id])
  }

  secrets = {
    "openclaw-gateway-token" = {
      name                = "openclaw-gateway-token"
      identity            = module.identity.resource_id
      key_vault_secret_id = azurerm_key_vault_secret.openclaw_gateway_token.versionless_id
    }
  }

  registries = var.container_image_acr_server != null ? [
    {
      server   = var.container_image_acr_server
      identity = module.identity.resource_id
    }
  ] : null

  template = {
    min_replicas = 0
    volumes = [
      {
        name         = "openclaw-state"
        storage_type = "AzureFile"
        storage_name = azurerm_container_app_environment_storage.openclaw_state.name
      }
    ]
    containers = [
      {
        name   = "openclaw"
        image  = local.openclaw_image
        cpu    = 2
        memory = "4Gi"
        volume_mounts = [
          {
            name = "openclaw-state"
            path = "/home/node/.openclaw"
          }
        ]
        liveness_probes = [
          {
            transport               = "HTTP"
            port                    = 18789
            path                    = "/healthz"
            initial_delay           = 10
            interval_seconds        = 30
            timeout                 = 5
            failure_count_threshold = 3
          }
        ]
        readiness_probes = [
          {
            transport               = "HTTP"
            port                    = 18789
            path                    = "/readyz"
            interval_seconds        = 10
            timeout                 = 5
            failure_count_threshold = 3
            success_count_threshold = 1
          }
        ]
        env = [
          {
            name  = "AZURE_OPENAI_ENDPOINT"
            value = tostring(data.azapi_resource.ai_foundry.output.properties.endpoint)
          },
          {
            name  = "AZURE_AI_INFERENCE_ENDPOINT"
            value = local.ai_inference_endpoint
          },
          {
            name  = "AZURE_OPENAI_DEPLOYMENT_EMBEDDING"
            value = var.embedding_model_name
          },
          {
            name  = "AZURE_AI_DEPLOYMENT_GROK4FAST"
            value = var.grok4fast_model_name
          },
          {
            name  = "AZURE_AI_DEPLOYMENT_GROK3"
            value = var.grok3_model_name
          },
          {
            name  = "AZURE_AI_DEPLOYMENT_GROK3MINI"
            value = var.grok3mini_model_name
          },
          {
            # Ensures gateway starts on the correct port even before openclaw.json is seeded.
            name  = "OPENCLAW_GATEWAY_PORT"
            value = "18789"
          },
          {
            name        = "OPENCLAW_GATEWAY_TOKEN"
            secret_name = "openclaw-gateway-token"
          },
        ]
      }
    ]
  }

  ingress = {
    allow_insecure_connections = false
    external_enabled           = true
    target_port                = 18789
    transport                  = "auto"
    ip_security_restriction = [
      {
        action           = "Allow"
        ip_address_range = var.public_ip
        name             = "home-ip-allowlist"
      }
    ]
    traffic_weight = [
      {
        latest_revision = true
        percentage      = 100
      }
    ]
  }
}
