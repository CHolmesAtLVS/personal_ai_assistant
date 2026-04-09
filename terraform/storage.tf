# storage.tf — ACA SMB storage account and shares removed 2026-04-09 (feature-aks-decommission-1.md TASK-011).
# Resources destroyed: azurerm_storage_account.openclaw_state (paadevocstate),
#   azurerm_storage_share.openclaw_state, azurerm_storage_share.openclaw_backup,
#   azurerm_container_app_environment_storage.openclaw_state,
#   azurerm_container_app_environment_storage.openclaw_backup.
# Pre-decommission backup taken to /tmp/pre-aca-decommission-dev-20260409 (44 files).
# NFS share (storage-aks.tf) is unaffected.
