resource "azurerm_monitor_action_group" "cost_alerts" {
  name                = local.action_group_name
  resource_group_name = module.resource_group.name
  short_name          = "cost-alerts"

  email_receiver {
    name          = "budget-notify"
    email_address = var.budget_alert_email
  }

  tags = local.common_tags

  depends_on = [module.resource_group]
}

resource "azurerm_consumption_budget_resource_group" "openclaw" {
  name              = local.budget_name
  resource_group_id = module.resource_group.id
  amount            = var.monthly_budget_amount
  time_grain        = "Monthly"

  time_period {
    start_date = "2026-04-01T00:00:00Z"
  }

  notification {
    operator       = "GreaterThan"
    threshold      = 50
    threshold_type = "Actual"
    contact_groups = [azurerm_monitor_action_group.cost_alerts.id]
  }

  notification {
    operator       = "GreaterThan"
    threshold      = 80
    threshold_type = "Actual"
    contact_groups = [azurerm_monitor_action_group.cost_alerts.id]
  }

  notification {
    operator       = "GreaterThan"
    threshold      = 100
    threshold_type = "Actual"
    contact_groups = [azurerm_monitor_action_group.cost_alerts.id]
  }

  notification {
    operator       = "GreaterThan"
    threshold      = 110
    threshold_type = "Forecasted"
    contact_groups = [azurerm_monitor_action_group.cost_alerts.id]
  }

  lifecycle {
    ignore_changes = [time_period]
  }

  depends_on = [module.resource_group]
}
