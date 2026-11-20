variable "project" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }

variable "nat_gateway_enabled" {
  type    = bool
  default = false
}

variable "address_space" {
  type    = string
  default = "10.20.0.0/24"
}
