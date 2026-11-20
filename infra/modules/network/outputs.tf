output "aca_subnet_id" {
  value = azurerm_subnet.aca.id
}

output "psql_subnet_id" {
  # Exposed only after the NSG is attached, so the server is never created on an open subnet.
  value = azurerm_subnet_network_security_group_association.psql.subnet_id
}

output "psql_private_dns_zone_id" {
  # Exposed via the link so the server waits for it (the provider requires the link first).
  value = azurerm_private_dns_zone_virtual_network_link.psql.private_dns_zone_name == "" ? "" : azurerm_private_dns_zone.psql.id
}
