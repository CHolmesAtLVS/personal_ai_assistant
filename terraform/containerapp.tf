data "azapi_resource" "ai_foundry" {
  resource_id            = module.ai_foundry.resource_id
  type                   = "Microsoft.CognitiveServices/accounts@2023-05-01"
  response_export_values = ["properties.endpoint", "properties.endpoints"]

  depends_on = [module.ai_foundry]
}

locals {
  # Azure OpenAI endpoint (openai.azure.com) — used as baseUrl for both the
  # azure-openai and azure-openai-codex providers via the /openai/v1/ path.
  azure_openai_endpoint = trimsuffix(
    tostring(data.azapi_resource.ai_foundry.output.properties.endpoints["Azure OpenAI Legacy API - Latest moniker"]),
    "/"
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
    "azure-ai-api-key" = {
      name                = "azure-ai-api-key"
      identity            = module.identity.resource_id
      key_vault_secret_id = azurerm_key_vault_secret.azure_ai_api_key.versionless_id
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
            value = local.azure_openai_endpoint
          },
          {
            name  = "AZURE_OPENAI_DEPLOYMENT_EMBEDDING"
            value = var.embedding_model_name
          },
          {
            name  = "AZURE_OPENAI_DEPLOYMENT_CHAT"
            value = var.ai_model_name
          },
          {
            name  = "AZURE_OPENAI_DEPLOYMENT_CODEX"
            value = var.codex_model_name
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
          {
            # AZURE_AI_API_KEY authenticates to the Azure OpenAI endpoint.
            # Managed Identity is not supported for this endpoint; the key is stored in
            # Key Vault and injected via secret reference (same pattern as OPENCLAW_GATEWAY_TOKEN).
            name        = "AZURE_AI_API_KEY"
            secret_name = "azure-ai-api-key"
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
