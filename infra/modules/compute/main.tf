# Everything that runs our code (plan §5, D23, D24, D34):
#   - Container Registry (images pulled by managed identity, admin user off),
#   - Key Vault (hashed device keys; the ingest function caches them and reloads them every few minutes),
#   - Container Apps environment in snet-aca with the processor, the read API and three jobs,
#   - the ingest Function app (Flex Consumption, outside the VNet) and its host storage.
#
# Terraform owns the resource definitions; CI ships images and code. The image fields are ignored
# after creation, so `plan` doesn't fight deploys (plan §12). Until CI pushes real images, the apps run
# Microsoft's public quickstart images.

locals {
  placeholder_app_image = "mcr.microsoft.com/k8se/quickstart:latest"
  placeholder_job_image = "mcr.microsoft.com/k8se/quickstart-jobs:latest"

  pg_env = {
    PGHOST     = var.postgres_fqdn
    PGDATABASE = var.postgres_database
    PGPORT     = "5432"
    PGSSLMODE  = "require"
  }

  worker_env = merge(local.pg_env, {
    AZURE_CLIENT_ID                       = var.identities.worker.client_id
    PGUSER                                = "writer"
    EVENTHUB_FULLY_QUALIFIED_NAMESPACE    = var.eventhub_namespace_fqdn
    EVENTHUB_NAME                         = var.eventhub_name
    SERVICEBUS_FULLY_QUALIFIED_NAMESPACE  = var.servicebus_namespace_fqdn
    SERVICEBUS_QUEUE_NAME                 = var.queue_name
    STORAGE_BLOB_ENDPOINT                 = var.data_blob_endpoint
    LAKE_CONTAINER                        = "lake"
    SESSIONS_CONTAINER                    = "sessions"
    APPLICATIONINSIGHTS_CONNECTION_STRING = var.app_insights_connection_string
  })
}

# --- Container Registry -------------------------------------------------------------

resource "azurerm_container_registry" "this" {
  name                = "acr${var.project}${var.suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard" # free for 12 months on the free account (plan §5)
  admin_enabled       = false
  tags                = var.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  for_each             = toset(["worker", "migrate", "readapi"])
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = var.identities[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

# --- Key Vault ----------------------------------------------------------------------

resource "azurerm_key_vault" "this" {
  name                       = "kv-${var.project}-${var.suffix}"
  resource_group_name        = var.resource_group_name
  location                   = var.location
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  tags                       = var.tags
}

resource "azurerm_role_assignment" "kv_ingest" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.identities.ingest.principal_id
  principal_type       = "ServicePrincipal"
}

# Team members write the device-key hashes with scripts/ (never Terraform, so they stay out of state).
resource "azurerm_role_assignment" "kv_admins" {
  for_each             = toset(var.admin_object_ids)
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = each.value
}

# RBAC changes take up to a minute to reach the data plane; apps created right after would fail to pull.
resource "time_sleep" "rbac" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.acr_pull, azurerm_role_assignment.kv_ingest]
}

# --- Container Apps environment -------------------------------------------------------

resource "azurerm_container_app_environment" "this" {
  name                           = "cae-${var.project}"
  resource_group_name            = var.resource_group_name
  location                       = var.location
  log_analytics_workspace_id     = var.log_analytics_workspace_id
  infrastructure_subnet_id       = var.aca_subnet_id
  internal_load_balancer_enabled = false # external: the read API needs public ingress
  tags                           = var.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  lifecycle {
    # Azure names the managed infrastructure resource group itself.
    ignore_changes = [infrastructure_resource_group_name]
  }
}

# --- Stream processor (long-running, no ingress) ---------------------------------------

resource "azurerm_container_app" "processor" {
  name                         = "ca-${var.project}-processor"
  resource_group_name          = var.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identities.worker.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = var.identities.worker.id
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "processor"
      image  = local.placeholder_app_image
      cpu    = 0.25
      memory = "0.5Gi"

      dynamic "env" {
        for_each = merge(local.worker_env, { RUN_MODE = "stream" })
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }

  depends_on = [time_sleep.rbac]
}

# --- Read API (public HTTPS ingress, reads as `reader`) ----------------------------------

resource "azurerm_container_app" "read_api" {
  name                         = "ca-${var.project}-read-api"
  resource_group_name          = var.resource_group_name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identities.readapi.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = var.identities.readapi.id
  }

  ingress {
    external_enabled = true
    # 80 is where the placeholder image listens, so a fresh app starts healthy. The real read-api image
    # runs as non-root and listens on 8000; deploy-services switches the port together with the image
    # (READ_API_PORT) and Terraform then leaves it alone (ignore_changes below).
    target_port = 80
    transport   = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1 # no cold start for the live view
    max_replicas = 2

    container {
      name   = "read-api"
      image  = local.placeholder_app_image
      cpu    = 0.25
      memory = "0.5Gi"

      dynamic "env" {
        for_each = merge(local.pg_env, {
          AZURE_CLIENT_ID                       = var.identities.readapi.client_id
          PGUSER                                = "reader"
          CORS_ALLOWED_ORIGINS                  = join(",", var.cors_allowed_origins)
          APPLICATIONINSIGHTS_CONNECTION_STRING = var.app_insights_connection_string
        })
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }

  lifecycle {
    # Image and port belong to the deployed code (deploy-services), not to Terraform.
    ignore_changes = [template[0].container[0].image, ingress[0].target_port]
  }

  depends_on = [time_sleep.rbac]
}

# --- Jobs ----------------------------------------------------------------------------

# Finalize: started by KEDA when "session ready" lands in the queue (plan §5).
resource "azurerm_container_app_job" "finalize" {
  name                         = "caj-${var.project}-finalize"
  resource_group_name          = var.resource_group_name
  location                     = var.location
  container_app_environment_id = azurerm_container_app_environment.this.id
  workload_profile_name        = "Consumption"
  replica_timeout_in_seconds   = 1800
  replica_retry_limit          = 1
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identities.worker.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = var.identities.worker.id
  }

  event_trigger_config {
    parallelism              = 1
    replica_completion_count = 1

    scale {
      min_executions              = 0
      max_executions              = 3
      polling_interval_in_seconds = 30

      rules {
        name             = "session-ready-queue"
        custom_rule_type = "azure-servicebus"
        identity_id      = var.identities.worker.id
        metadata = {
          namespace    = var.servicebus_namespace_name
          queueName    = var.queue_name
          messageCount = "1"
        }
      }
    }
  }

  template {
    container {
      name   = "finalize"
      image  = local.placeholder_job_image
      cpu    = 1
      memory = "2Gi"

      dynamic "env" {
        for_each = merge(local.worker_env, { RUN_MODE = "finalize" })
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }

  depends_on = [time_sleep.rbac]
}

# Aggregate: re-run the cross-session aggregation by hand or from CI.
resource "azurerm_container_app_job" "aggregate" {
  name                         = "caj-${var.project}-aggregate"
  resource_group_name          = var.resource_group_name
  location                     = var.location
  container_app_environment_id = azurerm_container_app_environment.this.id
  workload_profile_name        = "Consumption"
  replica_timeout_in_seconds   = 1800
  replica_retry_limit          = 0
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identities.worker.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = var.identities.worker.id
  }

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  template {
    container {
      name   = "aggregate"
      image  = local.placeholder_job_image
      cpu    = 1
      memory = "2Gi"

      dynamic "env" {
        for_each = merge(local.worker_env, { RUN_MODE = "aggregate" })
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }

  depends_on = [time_sleep.rbac]
}

# Migrate: run by CI before every services deploy; logs in as the Entra admin `migrator` and creates
# the `writer` / `reader` roles from these object IDs (plan §5 "Database logins").
resource "azurerm_container_app_job" "migrate" {
  name                         = "caj-${var.project}-migrate"
  resource_group_name          = var.resource_group_name
  location                     = var.location
  container_app_environment_id = azurerm_container_app_environment.this.id
  workload_profile_name        = "Consumption"
  replica_timeout_in_seconds   = 600
  replica_retry_limit          = 0
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identities.migrate.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = var.identities.migrate.id
  }

  manual_trigger_config {
    parallelism              = 1
    replica_completion_count = 1
  }

  template {
    container {
      name   = "migrate"
      image  = local.placeholder_job_image
      cpu    = 0.5
      memory = "1Gi"

      dynamic "env" {
        for_each = merge(local.pg_env, {
          RUN_MODE         = "migrate"
          AZURE_CLIENT_ID  = var.identities.migrate.client_id
          PGUSER           = "migrator"
          WRITER_OBJECT_ID = var.identities.worker.principal_id
          READER_OBJECT_ID = var.identities.readapi.principal_id
        })
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [template[0].container[0].image]
  }

  depends_on = [time_sleep.rbac]
}

# --- Ingest Function (Flex Consumption, outside the VNet) -------------------------------

# Host storage + deployment package container, separate from the data account so the ingest
# identity only gets Owner here and plain write on `lake`.
resource "azurerm_storage_account" "func" {
  name                            = "st${var.project}fn${var.suffix}"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  tags                            = var.tags
}

resource "azurerm_storage_container" "func_deploy" {
  name                  = "deployment"
  storage_account_id    = azurerm_storage_account.func.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "func_storage" {
  scope                = azurerm_storage_account.func.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = var.identities.ingest.principal_id
  principal_type       = "ServicePrincipal"
}

resource "time_sleep" "func_rbac" {
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.func_storage]
}

resource "azurerm_service_plan" "func" {
  name                = "asp-${var.project}-ingest"
  resource_group_name = var.resource_group_name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = var.tags
}

resource "azurerm_function_app_flex_consumption" "ingest" {
  name                = "func-${var.project}-ingest-${var.suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  service_plan_id     = azurerm_service_plan.func.id
  https_only          = true
  tags                = var.tags

  runtime_name           = "python"
  runtime_version        = "3.12"
  instance_memory_in_mb  = 512
  maximum_instance_count = var.ingest_max_instances # caps the bill under a flood of bad requests

  storage_container_type            = "blobContainer"
  storage_container_endpoint        = "${azurerm_storage_account.func.primary_blob_endpoint}${azurerm_storage_container.func_deploy.name}"
  storage_authentication_type       = "UserAssignedIdentity"
  storage_user_assigned_identity_id = var.identities.ingest.id

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identities.ingest.id]
  }

  site_config {
    application_insights_connection_string = var.app_insights_connection_string
    minimum_tls_version                    = "1.2"
  }

  # Identity-based host storage (keys are off on the account). azurerm 4.x (checked in v4.81.0) also
  # writes a plain `AzureWebJobsStorage=DefaultEndpointsProtocol=https;AccountName=<acct>;AccountKey=;...`
  # on every create and every update of this resource, whatever storage_authentication_type says
  # (hashicorp/terraform-provider-azurerm#29149, #33211). The host prefers that key-based string over the
  # `__` settings below, can't use it (no key) and never starts. So it is deleted after every apply
  # (infra/tf.ps1 apply, terraform-apply.yml) and before every deploy (deploy-ingest.yml); see
  # infra/README.md "Function host storage". Setting it here instead would show a diff on every plan.
  app_settings = {
    "AzureWebJobsStorage__accountName" = azurerm_storage_account.func.name
    "AzureWebJobsStorage__credential"  = "managedidentity"
    "AzureWebJobsStorage__clientId"    = var.identities.ingest.client_id

    AZURE_CLIENT_ID                    = var.identities.ingest.client_id
    EVENTHUB_FULLY_QUALIFIED_NAMESPACE = var.eventhub_namespace_fqdn
    EVENTHUB_NAME                      = var.eventhub_name
    STORAGE_BLOB_ENDPOINT              = var.data_blob_endpoint
    LAKE_CONTAINER                     = "lake"
    KEY_VAULT_URI                      = azurerm_key_vault.this.vault_uri
    DEVICE_KEYS_SECRET_NAME            = var.device_keys_secret_name
    # Largest *decompressed* body in bytes (413 above it): 200 KB, MAX_INFLATED in
    # services/ingest/ingest_core/contract.py. The code may only lower it (an Event Hubs Basic event is at
    # most 256 KB); the 20 MiB cap on the compressed body (MAX_BODY) is fixed in code.
    MAX_BODY_BYTES = "204800"
  }

  depends_on = [time_sleep.func_rbac]
}
