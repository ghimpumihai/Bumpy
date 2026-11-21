variable "project" {
  description = "Must match the bootstrap's project (the resource group is rg-<project>)."
  type        = string
  default     = "roadride"
  validation {
    condition     = can(regex("^[a-z0-9]{3,10}$", var.project))
    error_message = "project must be 3-10 lowercase letters or digits (it ends up in storage account names)."
  }
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
  sensitive   = true # kept out of plan output, which the CI plan shows on a public repo
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
  description = "First day of the month the budget starts, RFC 3339. Default (null): the first day of the month of the apply that creates it; Azure rejects a start in an earlier month. Later changes are ignored (observability module)."
  type        = string
  default     = null
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
