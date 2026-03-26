# AI Foundry: Hub, Project, AI Services, and model deployment.
# AVM pattern module: Azure/avm-ptn-aiml-ai-foundry/azurerm (~> 0.10)
module "ai_foundry" {
  source  = "Azure/avm-ptn-aiml-ai-foundry/azurerm"
  version = "~> 0.10"

  base_name                  = local.name_prefix
  location                   = var.location
  resource_group_resource_id = module.resource_group.resource_id
  tags                       = local.common_tags

  enable_telemetry = true

  ai_foundry = {
    name = local.ai_hub_name
  }

  create_byor = true

  key_vault_definition = {
    main = {
      existing_resource_id = module.key_vault.resource_id
    }
  }

  ai_projects = {
    main = {
      name         = local.ai_project_name
      display_name = local.ai_project_name
      description  = "AI Foundry project for ${var.project} ${var.environment}"
    }
  }

  ai_model_deployments = {
    main = {
      name = var.ai_model_name
      model = {
        format  = "OpenAI"
        name    = var.ai_model_name
        version = var.ai_model_version
      }
      scale = {
        type     = "GlobalStandard"
        capacity = var.ai_model_capacity
      }
    }
  }
}
