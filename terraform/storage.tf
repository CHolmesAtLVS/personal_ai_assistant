# storage.tf — ACA SMB storage account and shares removed 2026-04-09 (feature-aks-decommission-1.md TASK-011).
# Removed resource addresses:
#   azurerm_storage_account.openclaw_state
#   azurerm_storage_share.openclaw_state
#   azurerm_storage_share.openclaw_backup
#   azurerm_container_app_environment_storage.openclaw_state
#   azurerm_container_app_environment_storage.openclaw_backup
# NFS share configuration in storage-aks.tf is unchanged.
