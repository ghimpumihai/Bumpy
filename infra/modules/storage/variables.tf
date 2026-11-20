variable "project" { type = string }
variable "suffix" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }

variable "session_ready_queue_id" {
  description = "Service Bus queue that Event Grid delivers upload-complete events to."
  type        = string
}
