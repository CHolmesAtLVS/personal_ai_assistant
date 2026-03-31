{
  "gateway": {
    "mode": "local",
    "port": 18789,
    "bind": "lan",
    "auth": {
      "mode": "token",
      "token": "${OPENCLAW_GATEWAY_TOKEN}"
    },
    "controlUi": {
      "allowedOrigins": ["https://${APP_FQDN}"]
    }
  },
  "models": {
    "providers": {
      "azure-foundry": {
        "baseUrl": "${AZURE_AI_INFERENCE_ENDPOINT}",
        "auth": "api-key",
        "apiKey": "${AZURE_AI_API_KEY}",
        "api": "openai-completions",
        "models": [
          { "id": "${AZURE_AI_DEPLOYMENT_GROK4FAST}", "name": "${AZURE_AI_DEPLOYMENT_GROK4FAST}" },
          { "id": "${AZURE_AI_DEPLOYMENT_GROK3}", "name": "${AZURE_AI_DEPLOYMENT_GROK3}" },
          { "id": "${AZURE_AI_DEPLOYMENT_GROK3MINI}", "name": "${AZURE_AI_DEPLOYMENT_GROK3MINI}" }
        ]
      },
      "azure-openai": {
        "baseUrl": "${AZURE_OPENAI_ENDPOINT}",
        "auth": "api-key",
        "apiKey": "${AZURE_AI_API_KEY}",
        "api": "openai-completions",
        "models": [
          { "id": "${AZURE_OPENAI_DEPLOYMENT_EMBEDDING}", "name": "${AZURE_OPENAI_DEPLOYMENT_EMBEDDING}" }
        ]
      }
    }
  },
  "tools": {
    "profile": "full"
  },
  "update": {
    "checkOnStart": false
  },
  "agents": {
    "defaults": {
      "models": {
        "azure-foundry/${AZURE_AI_DEPLOYMENT_GROK4FAST}": {
          "alias": "grok",
          "params": {}
        },
        "azure-foundry/${AZURE_AI_DEPLOYMENT_GROK3}": {
          "alias": "grok-3",
          "params": {}
        },
        "azure-foundry/${AZURE_AI_DEPLOYMENT_GROK3MINI}": {
          "alias": "grok-mini",
          "params": {}
        }
      },
      "model": {
        "primary": "azure-foundry/${AZURE_AI_DEPLOYMENT_GROK4FAST}",
        "fallbacks": ["azure-foundry/${AZURE_AI_DEPLOYMENT_GROK3}"]
      }
    }
  }
}
