output "account_id" {
  value = azurerm_storage_account.data.id
}

output "account_name" {
  value = azurerm_storage_account.data.name
}

output "blob_endpoint" {
  value = azurerm_storage_account.data.primary_blob_endpoint
}

output "lake_container_id" {
  value = azurerm_storage_container.lake.id
}

output "sessions_container_id" {
  value = azurerm_storage_container.sessions.id
}
