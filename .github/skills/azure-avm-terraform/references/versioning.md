# Versioning

Pin both module and provider versions for deterministic plans.

## Finding the Latest Module Version

- Registry page: `https://registry.terraform.io/modules/Azure/{module}/azurerm/latest`
- Versions API: `https://registry.terraform.io/v1/modules/Azure/{module}/azurerm/versions`

## Module Version Pinning

```hcl
module "example" {
  source  = "Azure/avm-res-<service>-<resource>/azurerm"
  version = "x.y.z"
}
```

Always pin to an exact version (`x.y.z`), not a range, for infrastructure stability.

## Provider Version Pinning

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
```

Verify the AVM module's `required_providers` constraints before choosing a provider version range.

## Validation Sequence

After any version change:

1. `terraform fmt`
2. `terraform validate`
3. `terraform plan` (review before applying)
