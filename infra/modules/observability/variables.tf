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
