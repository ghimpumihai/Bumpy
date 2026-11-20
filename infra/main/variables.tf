variable "project" {
  description = "Must match the bootstrap's project (the resource group is rg-<project>)."
  type        = string
  default     = "roadride"
}

variable "location" {
  type    = string
  default = "northeurope"
}

variable "static_web_app_location" {
  description = "Static Web Apps region (westeurope refused new customers on 2026-11-20). Content is served globally either way."
  type        = string
  default     = "eastus2"
}

variable "psql_nat_gateway_enabled" {
  description = "Give the database subnet a NAT gateway (~$1/day) if default outbound access can't reach Entra ID."
  type        = bool
  default     = false
}

variable "alert_email" {
  description = "Where budget and error alerts go."
  type        = string
}

variable "admin_object_ids" {
  description = "Entra object IDs of team members: Key Vault secrets, fallback uploads, day-0 Event Hubs test."
  type        = list(string)
  default     = []
}

variable "budget_amount" {
  description = "Monthly budget in the billing currency; alerts at 40 % and 100 % ($20 and $50 by default)."
  type        = number
  default     = 50
}

variable "budget_start_date" {
  description = "First day of the month the budget starts, RFC 3339."
  type        = string
  default     = "2026-11-01T00:00:00Z"
}

variable "eventhub_local_auth_enabled" {
  description = "Plan §5 fallback: true only if Event Hubs Basic refuses managed-identity login on day 0."
  type        = bool
  default     = false
}

variable "extra_cors_origins" {
  description = "Extra origins allowed to call the read API, e.g. the local Vite dev server."
  type        = list(string)
  default     = ["http://localhost:5173"]
}
