# Data lake storage account (containers `lake` and `sessions`) and the Event Grid route that turns a
# finished fallback upload (`<sessionId>/_complete.json`) into a "session ready" message. Plan §5, D20, D28.

resource "azurerm_storage_account" "data" {
  name                            = "st${var.project}${var.suffix}"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true # login-protected public endpoint, no private endpoints (plan §6)
  tags                            = var.tags

  # D57: a deleted or overwritten trip blob can be restored for 14 days. Ingest never overwrites, but
  # finalize rewrites its parquet, so no immutability policy; old versions expire (management policy).
  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 14
    }

    container_delete_retention_policy {
      days = 14
    }
  }
}

resource "azurerm_storage_management_policy" "data" {
  storage_account_id = azurerm_storage_account.data.id

  rule {
    name    = "expire-old-versions"
    enabled = true

    filters {
      blob_types = ["blockBlob"]
    }

    actions {
      version {
        delete_after_days_since_creation = 14
      }
    }
  }
}

resource "azurerm_storage_container" "lake" {
  name                  = "lake"
  storage_account_id    = azurerm_storage_account.data.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "sessions" {
  name                  = "sessions"
  storage_account_id    = azurerm_storage_account.data.id
  container_access_type = "private"
}

# --- Event Grid: _complete.json → Service Bus queue ---------------------------------

resource "azurerm_eventgrid_system_topic" "data" {
  name                = "egst-${var.project}-data"
  resource_group_name = var.resource_group_name
  location            = var.location
  source_resource_id  = azurerm_storage_account.data.id
  topic_type          = "Microsoft.Storage.StorageAccounts"
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "eventgrid_to_queue" {
  scope                = var.session_ready_queue_id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_eventgrid_system_topic.data.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_eventgrid_system_topic_event_subscription" "upload_complete" {
  name                = "upload-complete-to-queue"
  system_topic        = azurerm_eventgrid_system_topic.data.name
  resource_group_name = var.resource_group_name

  included_event_types = ["Microsoft.Storage.BlobCreated"]

  subject_filter {
    subject_begins_with = "/blobServices/default/containers/${azurerm_storage_container.sessions.name}/blobs/"
    subject_ends_with   = "/_complete.json"
  }

  delivery_identity {
    type = "SystemAssigned"
  }

  service_bus_queue_endpoint_id = var.session_ready_queue_id

  retry_policy {
    max_delivery_attempts = 30
    event_time_to_live    = 1440
  }

  # Azure checks the sender role when the subscription is created; RBAC can take a minute to apply.
  depends_on = [time_sleep.eventgrid_rbac]
}

resource "time_sleep" "eventgrid_rbac" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.eventgrid_to_queue]
}
