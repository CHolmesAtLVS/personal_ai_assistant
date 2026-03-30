data "azapi_resource" "ai_foundry" {
  resource_id            = module.ai_foundry.resource_id
  type                   = "Microsoft.CognitiveServices/accounts@2023-05-01"
  response_export_values = ["properties.endpoint"]

  depends_on = [module.ai_foundry]
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
  ]

  enable_telemetry = true

  managed_identities = {
    user_assigned_resource_ids = toset([module.identity.resource_id])
  }

  secrets = {
    "openclaw-gateway-token" = {
      name                = "openclaw-gateway-token"
      identity            = module.identity.resource_id
      key_vault_secret_id = local.openclaw_gateway_token_kv_secret_id
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
        cpu    = 0.5
        memory = "1Gi"
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
            name  = "OPENCLAW_GATEWAY_BIND"
            value = "lan"
          },
          {
            name        = "OPENCLAW_GATEWAY_TOKEN"
            secret_name = "openclaw-gateway-token"
          },
          {
            name  = "OPENCLAW_CONTROL_UI_ALLOWED_ORIGINS"
            value = var.openclaw_control_ui_allowed_origins_json
          }
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
