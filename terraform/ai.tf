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
  }
}

# Grok model deployments are managed as standalone azapi_resource resources rather than
# inside the AVM module's ai_model_deployments map. This allows depends_on chaining to
# enforce strict serialization: Azure Cognitive Services accounts reject concurrent PUT
# operations on model deployments with 409 RequestConflict.
# The chain is: module.ai_foundry (embedding + gpt-4o) → grok4fast → grok3 → grok3mini.

resource "azapi_resource" "grok4fast" {
  type      = "Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview"
  name      = var.grok4fast_model_name
  parent_id = module.ai_foundry.resource_id

  body = {
    sku = {
      name     = "GlobalStandard"
      capacity = var.grok4fast_model_capacity
    }
    properties = {
      model = {
        format  = "OpenAI"
        name    = var.grok4fast_model_name
        version = var.grok4fast_model_version
      }
    }
  }

  depends_on = [module.ai_foundry]
}

resource "azapi_resource" "grok3" {
  type      = "Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview"
  name      = var.grok3_model_name
  parent_id = module.ai_foundry.resource_id

  body = {
    sku = {
      name     = "GlobalStandard"
      capacity = var.grok3_model_capacity
    }
    properties = {
      model = {
        format  = "OpenAI"
        name    = var.grok3_model_name
        version = var.grok3_model_version
      }
    }
  }

  depends_on = [azapi_resource.grok4fast]
}

resource "azapi_resource" "grok3mini" {
  type      = "Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview"
  name      = var.grok3mini_model_name
  parent_id = module.ai_foundry.resource_id

  body = {
    sku = {
      name     = "GlobalStandard"
      capacity = var.grok3mini_model_capacity
    }
    properties = {
      model = {
        format  = "OpenAI"
        name    = var.grok3mini_model_name
        version = var.grok3mini_model_version
      }
    }
  }

  depends_on = [azapi_resource.grok3]
}
