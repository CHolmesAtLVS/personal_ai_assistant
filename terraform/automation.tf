# Dev-only Automation Account for nightly AKS cluster stop/morning start.
# All resources are gated on var.environment == "dev"; prod is unaffected.

resource "azurerm_automation_account" "dev_cluster_scheduler" {
  count = var.environment == "dev" ? 1 : 0

  name                = "${local.name_prefix}-auto"
  location            = var.location
  resource_group_name = module.resource_group.name
  sku_name            = "Basic"
  tags                = local.common_tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_definition" "aks_stop_start" {
  count = var.environment == "dev" ? 1 : 0

  name  = "${local.name_prefix}-aks-stop-start"
  scope = module.aks.resource_id

  permissions {
    actions = [
      "Microsoft.ContainerService/managedClusters/stop/action",
      "Microsoft.ContainerService/managedClusters/start/action",
      "Microsoft.ContainerService/managedClusters/read",
    ]
  }
}

resource "azurerm_role_assignment" "automation_aks_stop_start" {
  count = var.environment == "dev" ? 1 : 0

  scope              = module.aks.resource_id
  role_definition_id = azurerm_role_definition.aks_stop_start[0].role_definition_resource_id
  principal_id       = azurerm_automation_account.dev_cluster_scheduler[0].identity[0].principal_id

  depends_on = [azurerm_automation_account.dev_cluster_scheduler]
}

resource "azurerm_automation_variable_string" "aks_rg" {
  count = var.environment == "dev" ? 1 : 0

  name                    = "AKS_RESOURCE_GROUP"
  resource_group_name     = module.resource_group.name
  automation_account_name = azurerm_automation_account.dev_cluster_scheduler[0].name
  value                   = module.resource_group.name
}

resource "azurerm_automation_variable_string" "aks_cluster_name" {
  count = var.environment == "dev" ? 1 : 0

  name                    = "AKS_CLUSTER_NAME"
  resource_group_name     = module.resource_group.name
  automation_account_name = azurerm_automation_account.dev_cluster_scheduler[0].name
  value                   = module.aks.name
}

resource "azurerm_automation_runbook" "stop_dev_cluster" {
  count = var.environment == "dev" ? 1 : 0

  name                    = "${local.name_prefix}-stop-cluster"
  location                = var.location
  resource_group_name     = module.resource_group.name
  automation_account_name = azurerm_automation_account.dev_cluster_scheduler[0].name
  runbook_type            = "PowerShell72"
  log_verbose             = false
  log_progress            = false
  content                 = file("${path.module}/../scripts/automation/stop-dev-cluster.ps1")
  tags                    = local.common_tags
}

resource "azurerm_automation_runbook" "start_dev_cluster" {
  count = var.environment == "dev" ? 1 : 0

  name                    = "${local.name_prefix}-start-cluster"
  location                = var.location
  resource_group_name     = module.resource_group.name
  automation_account_name = azurerm_automation_account.dev_cluster_scheduler[0].name
  runbook_type            = "PowerShell72"
  log_verbose             = false
  log_progress            = false
  content                 = file("${path.module}/../scripts/automation/start-dev-cluster.ps1")
  tags                    = local.common_tags
}

resource "azurerm_automation_schedule" "nightly_stop" {
  count = var.environment == "dev" ? 1 : 0

  name                    = "${local.name_prefix}-nightly-stop"
  resource_group_name     = module.resource_group.name
  automation_account_name = azurerm_automation_account.dev_cluster_scheduler[0].name
  frequency               = "Day"
  interval                = 1
  timezone                = "America/Denver"
  # Computed to always be > 5 min in the future on first apply; ignored on subsequent applies.
  start_time = formatdate("YYYY-MM-DDT02:00:00-06:00", timeadd(plantimestamp(), "24h"))

  lifecycle {
    ignore_changes = [start_time]
  }
}

resource "azurerm_automation_schedule" "morning_start" {
  count = var.environment == "dev" ? 1 : 0

  name                    = "${local.name_prefix}-morning-start"
  resource_group_name     = module.resource_group.name
  automation_account_name = azurerm_automation_account.dev_cluster_scheduler[0].name
  frequency               = "Week"
  interval                = 1
  timezone                = "America/Denver"
  # Computed to always be > 5 min in the future on first apply; ignored on subsequent applies.
  start_time = formatdate("YYYY-MM-DDT07:00:00-06:00", timeadd(plantimestamp(), "24h"))
  week_days  = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]

  lifecycle {
    ignore_changes = [start_time]
  }
}

resource "azurerm_automation_job_schedule" "stop_link" {
  count = var.environment == "dev" ? 1 : 0

  resource_group_name     = module.resource_group.name
  automation_account_name = azurerm_automation_account.dev_cluster_scheduler[0].name
  runbook_name            = azurerm_automation_runbook.stop_dev_cluster[0].name
  schedule_name           = azurerm_automation_schedule.nightly_stop[0].name
}

resource "azurerm_automation_job_schedule" "start_link" {
  count = var.environment == "dev" ? 1 : 0

  resource_group_name     = module.resource_group.name
  automation_account_name = azurerm_automation_account.dev_cluster_scheduler[0].name
  runbook_name            = azurerm_automation_runbook.start_dev_cluster[0].name
  schedule_name           = azurerm_automation_schedule.morning_start[0].name
}
