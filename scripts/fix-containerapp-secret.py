#!/usr/bin/env python3
"""
Strips the broken 'openclaw-state-storage-key' secret and any containers that
reference it from a Container App JSON body read from stdin.  Outputs the PATCH
body on stdout.  Exits 0 with empty stdout if the secret is not present.

Usage:
  az rest --method GET --url <containerapp_url> | python3 scripts/fix-containerapp-secret.py \
    | az rest --method PATCH --url <containerapp_url> --headers "Content-Type=application/json" --body @-
"""
import json
import sys

SECRET_NAME = "openclaw-state-storage-key"

data = json.load(sys.stdin)
cfg = data.get("properties", {}).get("configuration", {})
tmpl = data.get("properties", {}).get("template", {})

secrets = cfg.get("secrets", [])
if not any(s.get("name") == SECRET_NAME for s in secrets):
    sys.exit(0)


def drop_referencing(containers):
    return [
        c for c in containers
        if not any(
            e.get("secretRef") == SECRET_NAME or e.get("name") == "STORAGE_ACCOUNT_KEY"
            for e in c.get("env", [])
        )
    ]


cfg["secrets"] = [s for s in secrets if s.get("name") != SECRET_NAME]
tmpl["initContainers"] = drop_referencing(tmpl.get("initContainers", []))
main = [c for c in tmpl.get("containers", []) if c.get("name") == "openclaw"]
extra = drop_referencing(
    [c for c in tmpl.get("containers", []) if c.get("name") != "openclaw"]
)
tmpl["containers"] = main + extra

print(json.dumps({"properties": {"configuration": cfg, "template": tmpl}}))
