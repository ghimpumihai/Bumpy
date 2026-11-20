output "stack_resource_group" {
  value = azurerm_resource_group.stack.name
}

output "tfstate_resource_group" {
  value = azurerm_resource_group.tfstate.name
}

output "tfstate_storage_account" {
  value = azurerm_storage_account.tfstate.name
}

output "tfstate_container" {
  value = azurerm_storage_container.tfstate.name
}

# Paste these into the GitHub repo variables (Settings → Secrets and variables → Actions → Variables).
output "github_variables" {
  value = {
    AZURE_TENANT_ID         = data.azurerm_client_config.current.tenant_id
    AZURE_SUBSCRIPTION_ID   = data.azurerm_client_config.current.subscription_id
    AZURE_CLIENT_ID_DEPLOY  = azurerm_user_assigned_identity.gh_deploy.client_id
    AZURE_CLIENT_ID_PLAN    = azurerm_user_assigned_identity.gh_plan.client_id
    TFSTATE_RESOURCE_GROUP  = azurerm_resource_group.tfstate.name
    TFSTATE_STORAGE_ACCOUNT = azurerm_storage_account.tfstate.name
    TFSTATE_CONTAINER       = azurerm_storage_container.tfstate.name
  }
}
