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
        "auth": "token",
        "api": "openai-completions",
        "models": [
          "${AZURE_AI_DEPLOYMENT_GROK4FAST}",
          "${AZURE_AI_DEPLOYMENT_GROK3}",
          "${AZURE_AI_DEPLOYMENT_GROK3MINI}"
        ]
      }
    }
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
