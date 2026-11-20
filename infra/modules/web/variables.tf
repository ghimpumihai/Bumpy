variable "project" { type = string }
variable "resource_group_name" { type = string }
variable "tags" { type = map(string) }

variable "location" {
  description = "One of the Static Web Apps regions: westeurope, eastus2, centralus, westus2, eastasia."
  type        = string
  default     = "eastus2"
}
