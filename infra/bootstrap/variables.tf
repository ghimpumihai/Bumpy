variable "project" {
  description = "Short name used in every resource name (lowercase letters and digits only)."
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

variable "admin_object_ids" {
  description = "Entra object IDs of team members who run Terraform or upload from a laptop."
  type        = list(string)
  default     = []
}

# Public GitHub names and never-changing IDs for the immutable OIDC subject (plan §5). A repo rename changes
# the subject: update github_repo and apply, or every Azure login from Actions fails.
variable "github_owner" {
  type    = string
  default = "ghimpumihai"
}

variable "github_owner_id" {
  type    = string
  default = "163877193"
}

variable "github_repo" {
  type    = string
  default = "Bumpy"
}

variable "github_repo_id" {
  type    = string
  default = "1465690625"
}
