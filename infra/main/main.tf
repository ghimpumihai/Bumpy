# The whole Road & Ride stack in one resource group (plan §12). The group itself, the state storage
# and the GitHub identities are created by ../bootstrap.

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "stack" {
  name = "rg-${var.project}"
}

# Keeps globally unique names (storage, Key Vault, ACR, namespaces, server, function) free of clashes.
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  rg       = data.azurerm_resource_group.stack.name
  location = var.location
  suffix   = random_string.suffix.result
  tags     = { project = var.project, managed_by = "terraform", stack = "main" }
}

module "observability" {
  source              = "../modules/observability"
  project             = var.project
  suffix              = local.suffix
  resource_group_name = local.rg
  resource_group_id   = data.azurerm_resource_group.stack.id
  location            = local.location
  tags                = local.tags
  alert_email         = var.alert_email
  budget_amount       = var.budget_amount
  budget_start_date   = var.budget_start_date
}

module "network" {
  source              = "../modules/network"
  project             = var.project
  nat_gateway_enabled = var.psql_nat_gateway_enabled
  resource_group_name = local.rg
  location            = local.location
  tags                = local.tags
}

module "messaging" {
  source                      = "../modules/messaging"
  project                     = var.project
  suffix                      = local.suffix
  resource_group_name         = local.rg
  location                    = local.location
  tags                        = local.tags
  eventhub_local_auth_enabled = var.eventhub_local_auth_enabled
}

module "storage" {
  source                 = "../modules/storage"
  project                = var.project
  suffix                 = local.suffix
  resource_group_name    = local.rg
  location               = local.location
  tags                   = local.tags
  session_ready_queue_id = module.messaging.queue_id
}

module "database" {
  source              = "../modules/database"
  project             = var.project
  suffix              = local.suffix
  resource_group_name = local.rg
  location            = local.location
  tags                = local.tags
  tenant_id           = data.azurerm_client_config.current.tenant_id
  subnet_id           = module.network.psql_subnet_id
  private_dns_zone_id = module.network.psql_private_dns_zone_id
  admin_principal_id  = azurerm_user_assigned_identity.this["migrate"].principal_id
}

module "web" {
  source              = "../modules/web"
  project             = var.project
  resource_group_name = local.rg
  location            = var.static_web_app_location
  tags                = local.tags
}

module "compute" {
  source              = "../modules/compute"
  project             = var.project
  suffix              = local.suffix
  resource_group_name = local.rg
  location            = local.location
  tags                = local.tags
  tenant_id           = data.azurerm_client_config.current.tenant_id

  identities = {
    for k, v in azurerm_user_assigned_identity.this : k => {
      id           = v.id
      principal_id = v.principal_id
      client_id    = v.client_id
    }
  }
  admin_object_ids = var.admin_object_ids

  log_analytics_workspace_id     = module.observability.log_analytics_workspace_id
  app_insights_connection_string = module.observability.app_insights_connection_string
  aca_subnet_id                  = module.network.aca_subnet_id

  postgres_fqdn     = module.database.fqdn
  postgres_database = module.database.database_name

  eventhub_namespace_fqdn   = module.messaging.eventhub_namespace_fqdn
  eventhub_name             = module.messaging.eventhub_name
  servicebus_namespace_name = module.messaging.servicebus_namespace_name
  servicebus_namespace_fqdn = module.messaging.servicebus_namespace_fqdn
  queue_name                = module.messaging.queue_name
  data_blob_endpoint        = module.storage.blob_endpoint

  cors_allowed_origins = concat([module.web.url], var.extra_cors_origins)

  # The finalize job's KEDA rule must be able to log in to Service Bus the moment it is created.
  depends_on = [time_sleep.data_rbac]
}
