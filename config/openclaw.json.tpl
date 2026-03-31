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
      "azure-openai": {
        "baseUrl": "${AZURE_OPENAI_ENDPOINT}/deployments/${AZURE_OPENAI_DEPLOYMENT_CHAT}",
        "authHeader": false,
        "headers": {
          "api-key": "${AZURE_AI_API_KEY}"
        },
        "api": "openai-completions",
        "models": [
          { "id": "${AZURE_OPENAI_DEPLOYMENT_CHAT}", "name": "${AZURE_OPENAI_DEPLOYMENT_CHAT}", "input": ["text", "image"], "contextWindow": 128000, "maxTokens": 16384 }
        ]
      },
      "azure-foundry": {
        "baseUrl": "${AZURE_AI_INFERENCE_ENDPOINT}",
        "apiKey": "${AZURE_AI_API_KEY}",
        "authHeader": false,
        "headers": {
          "api-key": "${AZURE_AI_API_KEY}"
        },
        "api": "openai-completions",
        "models": [
          { "id": "${AZURE_AI_DEPLOYMENT_GROK4FAST}", "name": "${AZURE_AI_DEPLOYMENT_GROK4FAST}", "reasoning": true, "input": ["text", "image"], "contextWindow": 128000, "maxTokens": 128000, "compat": { "supportsStore": false } },
          { "id": "${AZURE_AI_DEPLOYMENT_GROK3}", "name": "${AZURE_AI_DEPLOYMENT_GROK3}", "reasoning": true, "input": ["text"], "contextWindow": 131072, "maxTokens": 131072, "compat": { "supportsStore": false } },
          { "id": "${AZURE_AI_DEPLOYMENT_GROK3MINI}", "name": "${AZURE_AI_DEPLOYMENT_GROK3MINI}", "reasoning": false, "input": ["text"], "contextWindow": 131072, "maxTokens": 131072, "compat": { "supportsStore": false } }
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
        "primary": "azure-openai/${AZURE_OPENAI_DEPLOYMENT_CHAT}",
        "fallbacks": ["azure-foundry/${AZURE_AI_DEPLOYMENT_GROK4FAST}", "azure-foundry/${AZURE_AI_DEPLOYMENT_GROK3}"]
      },
      "memorySearch": {
        "provider": "openai",
        "remote": {
          "baseUrl": "${AZURE_OPENAI_ENDPOINT}/deployments/${AZURE_OPENAI_DEPLOYMENT_EMBEDDING}",
          "apiKey": "${AZURE_AI_API_KEY}"
        },
        "model": "${AZURE_OPENAI_DEPLOYMENT_EMBEDDING}"
      }
    }
  }
}
