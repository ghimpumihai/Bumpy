# Static Web Apps (Free) for the dashboard (plan §5, D31). The deploy workflow fetches the deployment
# token with `az staticwebapp secrets list` after its OIDC login, so it is never stored in GitHub.

resource "azurerm_static_web_app" "dashboard" {
  name                = "stapp-${var.project}-dashboard"
  resource_group_name = var.resource_group_name
  location            = var.location # Static Web Apps only exists in a few regions; North Europe isn't one
  sku_tier            = "Free"
  sku_size            = "Free"
  tags                = var.tags

  # Not set here, but Azure has values for them and keeps them after an apply that clears them, so every
  # plan would show the same change.
  lifecycle {
    ignore_changes = [repository_branch, repository_url]
  }
}
