data "azapi_resource" "ai_foundry" {
  resource_id            = module.ai_foundry.resource_id
  type                   = "Microsoft.CognitiveServices/accounts@2025-10-01-preview"
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

  enable_telemetry = true

  managed_identities = {
    user_assigned_resource_ids = toset([module.identity.resource_id])
  }

  registries = [
    {
      server   = module.acr.resource.login_server
      identity = module.identity.resource_id
    }
  ]

  template = {
    containers = [
      {
        name   = "openclaw"
        image  = var.container_image
        cpu    = 0.5
        memory = "1Gi"
        env = [
          {
            name  = "AZURE_OPENAI_ENDPOINT"
            value = data.azapi_resource.ai_foundry.output.properties.endpoint
          },
          {
            name  = "OPENCLAW_GATEWAY_BIND"
            value = "lan"
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
