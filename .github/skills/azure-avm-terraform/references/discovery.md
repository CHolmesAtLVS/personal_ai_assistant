# Module Discovery

Use these sources to find Azure Verified Modules (AVM).

## AVM Index

Browse all available Terraform resource modules:
- `https://azure.github.io/Azure-Verified-Modules/indexes/terraform/tf-resource-modules/`

## Terraform Registry

- Search `avm` plus the Azure resource name.
- Filter by Partner tag.
- Prefer modules published under `Azure/*`.

## Naming Conventions

| Type     | Pattern                                        |
|----------|------------------------------------------------|
| Resource | `Azure/avm-res-{service}-{resource}/azurerm`   |
| Pattern  | `Azure/avm-ptn-{pattern}/azurerm`              |
| Utility  | `Azure/avm-utl-{utility}/azurerm`              |

## GitHub Source

Browse module source and examples directly:
- `https://github.com/Azure/terraform-azurerm-avm-res-{service}-{resource}`

## Selection Tips

1. Match the exact Azure resource scope first.
2. Prefer resource modules over pattern modules for narrow changes.
3. Use pattern modules for multi-resource architectural patterns.
4. Confirm example coverage for your use case before selecting.
