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
        "apiKey": "${AZURE_AI_API_KEY}",
        "api": "openai-completions",
        "models": [
          { "id": "${AZURE_OPENAI_DEPLOYMENT_CHAT}", "name": "${AZURE_OPENAI_DEPLOYMENT_CHAT}", "input": ["text", "image"], "contextWindow": 128000, "maxTokens": 16384 }
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
      "model": {
        "primary": "azure-openai/${AZURE_OPENAI_DEPLOYMENT_CHAT}",
        "fallbacks": []
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
