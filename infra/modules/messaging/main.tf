# Event Hubs Basic (the live stream) and Service Bus Basic (the "session ready" queue). Plan §5, D22, D28.
# Key-based access is off on both: every client logs in with its managed identity.

resource "azurerm_eventhub_namespace" "this" {
  name                          = "evhns-${var.project}-${var.suffix}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  sku                           = "Basic"
  capacity                      = 1
  local_authentication_enabled  = var.eventhub_local_auth_enabled
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true
  tags                          = var.tags
}

resource "azurerm_eventhub" "ingest" {
  name              = "ingest"
  namespace_id      = azurerm_eventhub_namespace.this.id
  partition_count   = 2
  message_retention = 1 # Basic allows 1 day
}

resource "azurerm_servicebus_namespace" "this" {
  name                          = "sbns-${var.project}-${var.suffix}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  sku                           = "Basic"
  local_auth_enabled            = false
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true
  tags                          = var.tags
}

resource "azurerm_servicebus_queue" "session_ready" {
  name                                 = "session-ready"
  namespace_id                         = azurerm_servicebus_namespace.this.id
  max_delivery_count                   = 5
  lock_duration                        = "PT5M"
  dead_lettering_on_message_expiration = true
  default_message_ttl                  = "P7D"
}
