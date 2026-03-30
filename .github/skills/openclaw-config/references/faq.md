# Common Config Issues

Reference: [docs.openclaw.ai/help/faq](https://docs.openclaw.ai/help/faq)

| Symptom | Fix |
|---|---|
| `gateway.bind: "lan"` set but nothing listens / UI shows unauthorized | Set `gateway.auth: token` and provide `OPENCLAW_GATEWAY_TOKEN` |
| Env vars disappeared after starting via service | Service manager doesn't inherit shell env; inject via `env` block, `.env` file, or service unit `Environment=` |
| `COPILOT_GITHUB_TOKEN` set but models shows "Shell env: off" | Shell env import disabled by default; enable with `OPENCLAW_LOAD_SHELL_ENV=1` or `env.shellEnv.enabled: true` |
| `config.apply` wiped my config | Use `config.apply` with caution; keep a backup of `openclaw.json` |
| `web_fetch` TLS failures with nvm Node | Set `NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt` in process env before starting |
| Gateway refuses to start | Config validation failed; run `openclaw doctor --non-interactive` to identify invalid fields |
| "No credentials found for profile" | API key env var not set or not visible to gateway process; check env var injection |
| Gateway up but replies never arrive | Check channel connectivity: `openclaw channels status --probe`; check model config: `openclaw status --deep` |
