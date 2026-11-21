variable "project" { type = string }
variable "suffix" { type = string }
variable "resource_group_name" { type = string }
variable "resource_group_id" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }

variable "alert_email" { type = string }
variable "budget_amount" { type = number }

variable "budget_start_date" {
  description = "First day of a month, RFC 3339. Azure requires the first of a month on or after the budget's creation month."
  type        = string
}

# What the workbook shows (workbook.tf).
variable "ingest_function_name" { type = string }
variable "eventhub_namespace_id" { type = string }
variable "eventhub_name" { type = string }
variable "servicebus_namespace_id" { type = string }
variable "queue_name" { type = string }
variable "postgres_server_id" { type = string }
variable "processor_app_id" { type = string }
variable "read_api_app_id" { type = string }
variable "finalize_job_id" { type = string }
