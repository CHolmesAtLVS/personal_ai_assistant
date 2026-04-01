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
        "baseUrl": "${AZURE_OPENAI_ENDPOINT}/openai/v1/",
        "apiKey": "${AZURE_AI_API_KEY}",
        "api": "openai-completions",
        "models": [
          {
            "id": "${AZURE_OPENAI_DEPLOYMENT_CHAT}",
            "name": "${AZURE_OPENAI_DEPLOYMENT_CHAT}",
            "input": ["text", "image"],
            "contextWindow": 128000,
            "maxTokens": 16384
          }
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
      "models": {
        "azure-openai/${AZURE_OPENAI_DEPLOYMENT_CHAT}": {}
      },
      "memorySearch": {
        "provider": "openai",
        "remote": {
          "baseUrl": "${AZURE_OPENAI_ENDPOINT}/openai/v1/",
          "apiKey": "${AZURE_AI_API_KEY}"
        },
        "model": "${AZURE_OPENAI_DEPLOYMENT_EMBEDDING}"
      }
    }
  }
}
