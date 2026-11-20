output "eventhub_namespace_name" {
  value = azurerm_eventhub_namespace.this.name
}

output "eventhub_namespace_fqdn" {
  value = "${azurerm_eventhub_namespace.this.name}.servicebus.windows.net"
}

output "eventhub_name" {
  value = azurerm_eventhub.ingest.name
}

output "eventhub_id" {
  value = azurerm_eventhub.ingest.id
}

output "servicebus_namespace_name" {
  value = azurerm_servicebus_namespace.this.name
}

output "servicebus_namespace_fqdn" {
  value = "${azurerm_servicebus_namespace.this.name}.servicebus.windows.net"
}

output "queue_name" {
  value = azurerm_servicebus_queue.session_ready.name
}

output "queue_id" {
  value = azurerm_servicebus_queue.session_ready.id
}
