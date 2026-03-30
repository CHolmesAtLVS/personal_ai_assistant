{
  "gateway": {
    "mode": "local",
    "port": 18789,
    "bind": "lan",
    "auth": {
      "mode": "token"
    },
    "controlUi": {
      "allowedOrigins": ["https://${APP_FQDN}"]
    }
  }
}
