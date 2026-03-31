# Secret Injection Patterns

Reference: [docs.openclaw.ai/gateway/configuration-reference](https://docs.openclaw.ai/gateway/configuration-reference) (Secrets section)

## `${VAR_NAME}` substitution

Reference process env vars in any config string value:

```jsonc
{
  "models": {
    "providers": {
      "my-provider": {
        "apiKey": "${MY_API_KEY}"
      }
    }
  }
}
```

Resolved from process env at config activation time.

## SecretRef objects

For fields that accept structured secret references:

```jsonc
{
  "source": "env",
  "provider": "default",
  "id": "MY_API_KEY"
}
```

Also resolves from process env.

## Choosing between them

- Use `${VAR}` for string fields (apiKey, URL, etc.)
- Use SecretRef for dedicated secret-typed fields that explicitly accept it
- Both resolve at activation time; SecretRef gives more metadata to the gateway
