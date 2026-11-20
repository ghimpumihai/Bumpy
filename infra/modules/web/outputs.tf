output "name" {
  value = azurerm_static_web_app.dashboard.name
}

output "url" {
  value = "https://${azurerm_static_web_app.dashboard.default_host_name}"
}
