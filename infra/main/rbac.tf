# Data-plane roles on the stream, the queue and the data lake. Roles on resources inside a module
# (ACR, Key Vault, function storage, Event Grid → queue) live in that module.

locals {
  id = azurerm_user_assigned_identity.this

  data_roles = {
    ingest_eventhub_send = { scope = module.messaging.eventhub_id, role = "Azure Event Hubs Data Sender", principal = local.id["ingest"].principal_id }
    ingest_lake_write    = { scope = module.storage.lake_container_id, role = "Storage Blob Data Contributor", principal = local.id["ingest"].principal_id }

    worker_eventhub_read = { scope = module.messaging.eventhub_id, role = "Azure Event Hubs Data Receiver", principal = local.id["worker"].principal_id }
    # Owner, not Sender + Receiver: the KEDA Service Bus scaler reads the queue's message count through
    # the management API, which needs the Manage right. Scoped to the one queue.
    worker_queue         = { scope = module.messaging.queue_id, role = "Azure Service Bus Data Owner", principal = local.id["worker"].principal_id }
    worker_sessions_read = { scope = module.storage.sessions_container_id, role = "Storage Blob Data Reader", principal = local.id["worker"].principal_id }
    # Read-only: finalize lists and downloads the raw archive, nothing in the processor writes there.
    worker_lake_read     = { scope = module.storage.lake_container_id, role = "Storage Blob Data Reader", principal = local.id["worker"].principal_id }
  }

  # Team members: laptop fallback upload (plan §5), day-0 Event Hubs test send (plan §16), reading the lake.
  admin_roles = merge([
    for oid in var.admin_object_ids : {
      "${oid}_sessions" = { scope = module.storage.sessions_container_id, role = "Storage Blob Data Contributor", principal = oid }
      "${oid}_lake"     = { scope = module.storage.lake_container_id, role = "Storage Blob Data Reader", principal = oid }
      "${oid}_eventhub" = { scope = module.messaging.eventhub_id, role = "Azure Event Hubs Data Sender", principal = oid }
    }
  ]...)
}

resource "azurerm_role_assignment" "data" {
  for_each             = local.data_roles
  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = each.value.principal
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "admins" {
  for_each             = local.admin_roles
  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = each.value.principal
}

resource "time_sleep" "data_rbac" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.data]
}
