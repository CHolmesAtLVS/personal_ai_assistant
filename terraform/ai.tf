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
    # gpt-4o retained until Grok deployments are validated in dev (GUD-002).
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

    # Embeddings — Azure OpenAI endpoint (text-embedding-3-large).
    embedding = {
      name = var.embedding_model_name
      model = {
        format  = "OpenAI"
        name    = var.embedding_model_name
        version = var.embedding_model_version
      }
      scale = {
        type     = "GlobalStandard"
        capacity = var.embedding_model_capacity
      }
    }

    # Grok chat models — Azure AI Model Inference endpoint (OpenAI-compatible serving).
    # NOTE (TASK-002): format = "OpenAI" is used because Grok is served via the
    # OpenAI-compatible AI Model Inference API. Confirm this against the AVM module
    # source before applying. If the module rejects non-native format values, switch
    # to a raw azurerm_cognitive_account_deployment resource for these entries.
    "grok-4-fast-reasoning" = {
      name = var.grok4fast_model_name
      model = {
        format  = "OpenAI"
        name    = var.grok4fast_model_name
        version = var.grok4fast_model_version
      }
      scale = {
        type     = "GlobalStandard"
        capacity = var.grok4fast_model_capacity
      }
    }

    "grok-3" = {
      name = var.grok3_model_name
      model = {
        format  = "OpenAI"
        name    = var.grok3_model_name
        version = var.grok3_model_version
      }
      scale = {
        type     = "GlobalStandard"
        capacity = var.grok3_model_capacity
      }
    }

    "grok-3-mini" = {
      name = var.grok3mini_model_name
      model = {
        format  = "OpenAI"
        name    = var.grok3mini_model_name
        version = var.grok3mini_model_version
      }
      scale = {
        type     = "GlobalStandard"
        capacity = var.grok3mini_model_capacity
      }
    }
  }
}
