variable "project" { type = string }
variable "suffix" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }

variable "tenant_id" { type = string }
variable "subnet_id" { type = string }
variable "private_dns_zone_id" { type = string }

variable "admin_principal_id" {
  description = "Object (principal) ID of the migrate job's user-assigned identity; becomes the Entra admin `migrator`."
  type        = string
}

variable "database_name" {
  type    = string
  default = "roadride"
}
