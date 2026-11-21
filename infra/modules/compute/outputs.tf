output "acr_login_server" {
  value = azurerm_container_registry.this.login_server
}

output "acr_name" {
  value = azurerm_container_registry.this.name
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}

output "container_app_environment_name" {
  value = azurerm_container_app_environment.this.name
}

output "processor_name" {
  value = azurerm_container_app.processor.name
}

output "read_api_name" {
  value = azurerm_container_app.read_api.name
}

output "read_api_url" {
  value = "https://${azurerm_container_app.read_api.ingress[0].fqdn}"
}

output "job_names" {
  value = {
    finalize  = azurerm_container_app_job.finalize.name
    aggregate = azurerm_container_app_job.aggregate.name
    migrate   = azurerm_container_app_job.migrate.name
  }
}

output "ingest_function_name" {
  value = azurerm_function_app_flex_consumption.ingest.name
}

# Host only: the iPhone app and tools/replay add /api/ingest themselves.
output "ingest_base_url" {
  value = "https://${azurerm_function_app_flex_consumption.ingest.default_hostname}"
}

# The batch endpoint itself, for curl / Invoke-WebRequest checks.
output "ingest_batch_url" {
  value = "https://${azurerm_function_app_flex_consumption.ingest.default_hostname}/api/ingest"
}
