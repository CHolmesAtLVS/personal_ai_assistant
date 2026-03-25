# Best Practices

## Implementation

1. Start from official AVM example blocks.
2. Replace local source (`../../`) with the registry source string.
3. Pin module version explicitly.
4. Set `enable_telemetry` as required by the module.
5. Keep variable surfaces minimal — pass only required inputs.
6. Expose only outputs needed by downstream resources.

## Security

- Never place secrets in Terraform source code or committed `.tfvars` files.
- Prefer managed identity over service principals with embedded credentials.
- Preserve IP-restricted ingress and HTTPS settings unless explicitly asked to change them.
- Keep infrastructure declarative and auditable.

## Quality Gates

Run for every change, in order:

```bash
terraform fmt
terraform validate
terraform plan
```

Only proceed to `apply` after reviewing the plan output.

## Review Checklist

- [ ] Module source uses AVM registry naming convention
- [ ] Module version is pinned to an exact version
- [ ] Provider versions are pinned and compatible with the module
- [ ] `enable_telemetry` is set
- [ ] No hardcoded secrets or tenant/subscription identifiers
- [ ] `terraform fmt` passes with no changes
- [ ] `terraform validate` passes cleanly
- [ ] Minimal inputs/outputs — nothing surplus to requirements
