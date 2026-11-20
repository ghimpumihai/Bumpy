variable "project" { type = string }
variable "suffix" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }

variable "eventhub_local_auth_enabled" {
  description = "Fallback switch from plan §5: set true only if the day-0 test shows Event Hubs Basic refuses Entra login."
  type        = bool
  default     = false
}
