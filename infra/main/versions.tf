terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.40"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # Partial config: resource_group_name, storage_account_name, container_name and key come from
  # `-backend-config` (infra/tf.ps1 locally, repo variables in CI). Storage keys are off, so Entra login.
  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  # subscription_id / tenant_id come from ARM_SUBSCRIPTION_ID / ARM_TENANT_ID (.env locally, OIDC in CI).
  storage_use_azuread             = true
  resource_provider_registrations = "none" # done once by infra/bootstrap

  features {
    storage {
      # Keys are off on every account; skip data-plane calls the provider would make with them.
      data_plane_available = false
    }
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}
