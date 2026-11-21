# Log Analytics + Application Insights, an email action group, a spending budget and the monitoring
# workbook (workbook.tf) (plan §5 "Running and watching it"). No alert rules yet.

resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.project}-${var.suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 0.5
  tags                = var.tags
}

resource "azurerm_application_insights" "this" {
  name                = "appi-${var.project}-${var.suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "web"
  tags                = var.tags
}

resource "azurerm_monitor_action_group" "email" {
  name                = "ag-${var.project}-email"
  resource_group_name = var.resource_group_name
  short_name          = substr(var.project, 0, 12)
  tags                = var.tags

  email_receiver {
    name                    = "team"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

resource "azurerm_consumption_budget_resource_group" "this" {
  name              = "budget-${var.project}"
  resource_group_id = var.resource_group_id
  amount            = var.budget_amount
  time_grain        = "Monthly"

  time_period {
    start_date = var.budget_start_date
  }

  # $20 and $50 with the default amount of 50 (plan §5 "Cost Management budget").
  notification {
    enabled        = true
    operator       = "GreaterThanOrEqualTo"
    threshold      = 40
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    operator       = "GreaterThanOrEqualTo"
    threshold      = 100
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    operator       = "GreaterThanOrEqualTo"
    threshold      = 100
    threshold_type = "Forecasted"
    contact_groups = [azurerm_monitor_action_group.email.id]
  }

  lifecycle {
    # Azure moves start_date forward by itself; don't fight it.
    ignore_changes = [time_period]
  }
}
