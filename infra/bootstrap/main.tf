# Run once by hand (plan §12). Creates what the main stack needs before it can run:
#   - the stack's resource group (so CI can be scoped to it and `terraform destroy` empties it),
#   - the storage account + container that hold the main stack's Terraform state,
#   - the GitHub Actions identities with OIDC federated credentials (plan §5, D36),
#   - the team's Entra group (Owner on the project resource groups),
#   - resource provider registration (done by the provider block below).
# Its own state stays local (terraform.tfstate in this folder, gitignored).

terraform {
  required_version = ">= 1.9"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.69"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {
    storage {
      # Storage keys are off; don't let the provider make data-plane calls that would need them.
      data_plane_available = false
    }
  }
  storage_use_azuread             = true
  resource_provider_registrations = "core"
  resource_providers_to_register = [
    "Microsoft.App",
    "Microsoft.ContainerRegistry",
    "Microsoft.DBforPostgreSQL",
    "Microsoft.EventGrid",
    "Microsoft.EventHub",
    "Microsoft.KeyVault",
    "Microsoft.ManagedIdentity",
    "Microsoft.OperationalInsights",
    "Microsoft.Insights",
    "Microsoft.ServiceBus",
    "Microsoft.Storage",
    "Microsoft.Web",
    "Microsoft.Consumption",
  ]
}

data "azurerm_client_config" "current" {}

# Bootstrap runs with a person's login; the CI identities have no Microsoft Graph rights to manage groups.
provider "azuread" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

# --- Stack resource group -------------------------------------------------------------

resource "azurerm_resource_group" "stack" {
  name     = "rg-${var.project}"
  location = var.location
  tags     = local.tags
}

# --- Terraform state ------------------------------------------------------------------

resource "azurerm_resource_group" "tfstate" {
  name     = "rg-${var.project}-tfstate"
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "tfstate" {
  name                            = "st${var.project}tf${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.tfstate.name
  location                        = azurerm_resource_group.tfstate.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 7
    }
  }

  tags = local.tags
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# Whoever runs bootstrap (and the listed admins) can read and lock the state from a laptop.
resource "azurerm_role_assignment" "tfstate_admins" {
  for_each             = toset(concat([data.azurerm_client_config.current.object_id], var.admin_object_ids))
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value
}

# --- Team group (D39) -----------------------------------------------------------------
# Owner covers the control plane only; data-plane roles (blobs, Event Hubs, Key Vault secrets) come from
# putting this group's object ID into TF_VAR_admin_object_ids for the main stack.

resource "azuread_group" "team" {
  display_name     = "${var.project}-team"
  description      = "Road & Ride team: Owner on the project resource groups."
  security_enabled = true
  owners           = [data.azurerm_client_config.current.object_id]
}

resource "azurerm_role_assignment" "team_owner" {
  for_each = {
    stack   = azurerm_resource_group.stack.id
    tfstate = azurerm_resource_group.tfstate.id
  }
  scope                = each.value
  role_definition_name = "Owner"
  principal_id         = azuread_group.team.object_id
  principal_type       = "Group"
}

# Separate from tfstate_admins: the group's ID is unknown until it exists, so it can't be a for_each key.
resource "azurerm_role_assignment" "team_tfstate" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azuread_group.team.object_id
  principal_type       = "Group"
}

# --- GitHub Actions identities (OIDC, no stored secrets) ------------------------------

locals {
  tags = { project = var.project, managed_by = "terraform", stack = "bootstrap" }

  # GitHub immutable subject claims (repo created after 2026-07-15), plan §5 / D36.
  gh_repo_prefix = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}"
}

resource "azurerm_user_assigned_identity" "gh_deploy" {
  name                = "id-${var.project}-gh-deploy"
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location
  tags                = local.tags
}

resource "azurerm_user_assigned_identity" "gh_plan" {
  name                = "id-${var.project}-gh-plan"
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "gh_deploy" {
  name      = "github-prod-environment"
  parent_id = azurerm_user_assigned_identity.gh_deploy.id
  audience  = ["api://AzureADTokenExchange"]
  issuer    = "https://token.actions.githubusercontent.com"
  subject   = "${local.gh_repo_prefix}:environment:prod"
}

resource "azurerm_federated_identity_credential" "gh_plan" {
  name      = "github-pull-request"
  parent_id = azurerm_user_assigned_identity.gh_plan.id
  audience  = ["api://AzureADTokenExchange"]
  issuer    = "https://token.actions.githubusercontent.com"
  subject   = "${local.gh_repo_prefix}:pull_request"
}

# Deploy: Terraform creates role assignments, so it needs RBAC Administrator as well (plan §12).
resource "azurerm_role_assignment" "gh_deploy_contributor" {
  scope                = azurerm_resource_group.stack.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.gh_deploy.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "gh_deploy_rbac_admin" {
  scope                = azurerm_resource_group.stack.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.gh_deploy.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "gh_deploy_state" {
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.gh_deploy.principal_id
  principal_type       = "ServicePrincipal"
}

# Plan (pull requests): read-only on the stack, but must take the state lease.
resource "azurerm_role_assignment" "gh_plan_reader" {
  scope                = azurerm_resource_group.stack.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.gh_plan.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "gh_plan_state" {
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.gh_plan.principal_id
  principal_type       = "ServicePrincipal"
}
