data "azapi_resource" "ai_foundry" {
  resource_id            = module.ai_foundry.resource_id
  type                   = "Microsoft.CognitiveServices/accounts@2023-05-01"
  response_export_values = ["properties.endpoint", "properties.endpoints"]

  depends_on = [module.ai_foundry]
}

locals {
  # Azure OpenAI endpoint (openai.azure.com) — used as baseUrl for the
  # azure-openai provider via the /openai/v1/ path.
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
    azurerm_role_assignment.mi_state_blob_contributor,
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
    # Storage account primary key for azcopy in the init container (state-restore).
    # MSI cannot be used in init containers in Consumption-only ACA environments;
    # the account key is the required auth fallback (ASSUMPTION-001, feature-sidecar-sync-1.md).
    "openclaw-state-storage-key" = {
      name                = "openclaw-state-storage-key"
      identity            = module.identity.resource_id
      key_vault_secret_id = azurerm_key_vault_secret.openclaw_state_storage_key.versionless_id
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
    # Allow 30 s for the azcopy sidecar to complete its final sync on SIGTERM
    # before the pod is forcefully terminated (RISK-001, feature-sidecar-sync-1.md).
    termination_grace_period_seconds = 30
    volumes = [
      # REQ-001: disk-backed EmptyDir for state — full POSIX semantics, no EPERM on chmod.
      # Backed by the node's local ephemeral disk in ACA Consumption plan (up to 21 GiB).
      {
        name         = "openclaw-data"
        storage_type = "EmptyDir"
      },
      {
        name         = "openclaw-backup"
        storage_type = "AzureFile"
        storage_name = azurerm_container_app_environment_storage.openclaw_backup.name
      }
    ]
    # REQ-002: init container restores Blob → EmptyDir before main containers start.
    # ACA guarantees init containers complete before main containers are started.
    # AUTH NOTE: MSI cannot be used in init containers in Consumption-only ACA environments
    # (ACA platform restriction). STORAGE_ACCOUNT_KEY (from Key Vault secret ref) is used
    # for azcopy auth instead (ASSUMPTION-001, feature-sidecar-sync-1.md).
    # The || echo pattern ensures exit 0 on a failed restore (RISK-003): the gateway
    # starts with empty state rather than blocking indefinitely on an azcopy error.
    init_containers = [
      {
        name    = "state-restore"
        image   = "mcr.microsoft.com/azure-cli:2.69.0"
        cpu     = 0.25
        memory  = "0.5Gi"
        command = ["/bin/sh", "-c"]
        args = [
          "set -e; az storage blob download-batch --source openclaw-state --destination /data --account-name \"$STORAGE_ACCOUNT_NAME\" --account-key \"$STORAGE_ACCOUNT_KEY\" --overwrite --only-show-errors || echo 'Restore failed \u2014 starting with empty state'; chmod -R 700 /data; chown -R 1000:1000 /data; echo 'State restore complete.'"
        ]
        env = [
          {
            name  = "STORAGE_ACCOUNT_NAME"
            value = local.openclaw_state_storage_account_name
          },
          {
            name        = "STORAGE_ACCOUNT_KEY"
            secret_name = "openclaw-state-storage-key"
          },
        ]
        volume_mounts = [
          {
            name = "openclaw-data"
            path = "/data"
          }
        ]
      }
    ]
    containers = [
      {
        name  = "openclaw"
        image = local.openclaw_image
        # CON-001: reduced from 2.0/4.0Gi to accommodate sidecar + init container
        # within the ACA Consumption plan 2.0 CPU / 4.0 GiB pod maximum.
        # openclaw 1.5/3.0Gi + sidecar 0.25/0.5Gi + init 0.25/0.5Gi = 2.0/4.0Gi (valid).
        cpu    = 1.5
        memory = "3Gi"
        volume_mounts = [
          {
            name = "openclaw-data"
            path = "/home/node/.openclaw"
          },
          {
            name = "openclaw-backup"
            path = "/mnt/openclaw-backup"
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
          {
            # Suppress self-respawn overhead on startup (TASK-011).
            name  = "OPENCLAW_NO_RESPAWN"
            value = "1"
          },
          {
            # V8 compile cache persisted in ephemeral EmptyDir — rebuilds on cold start
            # but speeds up repeated CLI invocations within a running container (TASK-011).
            name  = "NODE_COMPILE_CACHE"
            value = "/var/tmp/openclaw-compile-cache"
          },
        ]
      },
      # REQ-003: azcopy sidecar — event-driven sync EmptyDir → Blob Storage.
      # Authenticates via Managed Identity (MSI works for regular sidecar containers;
      # restriction only applies to init containers in Consumption-only environments).
      # Design: 5-second poll with find -newer marker; SIGTERM triggers a final sync;
      # 60-minute reconciliation sync as a belt-and-suspenders backstop (CON-006).
      {
        name    = "state-sync"
        image   = "mcr.microsoft.com/azure-cli:2.69.0"
        cpu     = 0.25
        memory  = "0.5Gi"
        command = ["/bin/sh", "-c"]
        args = [
          "set -e; MARKER=/tmp/.last_sync; RECON_INTERVAL=3600; POLL_INTERVAL=5; touch \"$MARKER\"; echo \"Sync sidecar started (event-driven; reconciliation every $RECON_INTERVAL s).\"; last_recon=$(date +%s); _sigterm() { echo 'SIGTERM: running final sync...'; az storage blob upload-batch --source /data --destination openclaw-state --account-name \"$STORAGE_ACCOUNT_NAME\" --account-key \"$STORAGE_ACCOUNT_KEY\" --overwrite --only-show-errors 2>/dev/null || true; exit 0; }; trap '_sigterm' TERM; while true; do now=$(date +%s); if find /data -newer \"$MARKER\" -not -path '/data/.azure/*' -type f | grep -q .; then echo 'Changes detected - syncing...'; az storage blob upload-batch --source /data --destination openclaw-state --account-name \"$STORAGE_ACCOUNT_NAME\" --account-key \"$STORAGE_ACCOUNT_KEY\" --overwrite --only-show-errors; touch \"$MARKER\"; last_recon=$now; elif [ $(( now - last_recon )) -ge $RECON_INTERVAL ]; then echo 'Reconciliation sync...'; az storage blob upload-batch --source /data --destination openclaw-state --account-name \"$STORAGE_ACCOUNT_NAME\" --account-key \"$STORAGE_ACCOUNT_KEY\" --overwrite --only-show-errors; touch \"$MARKER\"; last_recon=$now; fi; sleep $POLL_INTERVAL & wait $!; done"
        ]
        env = [
          {
            # Storage account key injected from Key Vault — used for az storage blob upload-batch auth.
            name        = "STORAGE_ACCOUNT_KEY"
            secret_name = "openclaw-state-storage-key"
          },
          {
            name  = "STORAGE_ACCOUNT_NAME"
            value = local.openclaw_state_storage_account_name
          },
        ]
        volume_mounts = [
          {
            name = "openclaw-data"
            path = "/data"
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
