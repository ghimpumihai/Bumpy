output "resource_group" {
  value = local.rg
}

# What goes in the iPhone app's upload settings and in REPLAY_API_URL: https://<host>, no path
# (the app appends api/ingest itself, UploadSettings.swift).
output "ingest_base_url" {
  value = module.compute.ingest_base_url
}

# https://<host>/api/ingest: the POST endpoint, for manual checks.
output "ingest_batch_url" {
  value = module.compute.ingest_batch_url
}

# Written into dashboard/public/config.json as {"apiBase": ...} by the dashboard deploy.
output "read_api_url" {
  value = module.compute.read_api_url
}

output "dashboard_url" {
  value = module.web.url
}

output "static_web_app_name" {
  value = module.web.name
}

output "acr_login_server" {
  value = module.compute.acr_login_server
}

output "acr_name" {
  value = module.compute.acr_name
}

output "key_vault_name" {
  value = module.compute.key_vault_name
}

output "storage_account_name" {
  value = module.storage.account_name
}

output "postgres_fqdn" {
  value = module.database.fqdn
}

output "postgres_database" {
  value = module.database.database_name
}

output "eventhub_namespace_fqdn" {
  value = module.messaging.eventhub_namespace_fqdn
}

output "ingest_function_name" {
  value = module.compute.ingest_function_name
}

output "container_apps" {
  value = {
    environment = module.compute.container_app_environment_name
    processor   = module.compute.processor_name
    read_api    = module.compute.read_api_name
    jobs        = module.compute.job_names
  }
}

# The migrate job needs these to create the `writer` and `reader` roles (pgaadauth_create_principal_with_oid).
output "identity_object_ids" {
  value = { for k, v in azurerm_user_assigned_identity.this : k => v.principal_id }
}
