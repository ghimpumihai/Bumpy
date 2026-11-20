variable "project" { type = string }
variable "suffix" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }
variable "tenant_id" { type = string }

variable "identities" {
  description = "User-assigned identities created in the root module, keyed ingest / worker / migrate / readapi."
  type = map(object({
    id           = string
    principal_id = string
    client_id    = string
  }))
}

variable "admin_object_ids" {
  type    = list(string)
  default = []
}

variable "log_analytics_workspace_id" { type = string }

variable "app_insights_connection_string" {
  type      = string
  sensitive = true
}

variable "aca_subnet_id" { type = string }

variable "postgres_fqdn" { type = string }
variable "postgres_database" { type = string }

variable "eventhub_namespace_fqdn" { type = string }
variable "eventhub_name" { type = string }
variable "servicebus_namespace_name" { type = string }
variable "servicebus_namespace_fqdn" { type = string }
variable "queue_name" { type = string }
variable "data_blob_endpoint" { type = string }

variable "cors_allowed_origins" {
  type = list(string)
}

variable "device_keys_secret_name" {
  type    = string
  default = "device-key-hashes"
}

variable "ingest_max_instances" {
  type    = number
  default = 10
}
