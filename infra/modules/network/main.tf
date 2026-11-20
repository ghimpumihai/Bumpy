# VNet with two delegated subnets, the database NSG and the private DNS zone (plan §5 "VNet", D35).

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.project}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.address_space]
  tags                = var.tags
}

# Container Apps (workload profiles) needs at least a /27, and the size can't change later.
resource "azurerm_subnet" "aca" {
  name                 = "snet-aca"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.address_space, 3, 0)] # 10.20.0.0/27

  delegation {
    name = "aca"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "psql" {
  name                 = "snet-psql"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.address_space, 4, 2)] # 10.20.0.32/28

  # New VNets are private by default since 2026-03-31; the server must still reach Entra ID
  # to validate login tokens, and we have no NAT gateway (D35).
  default_outbound_access_enabled = true

  # Flexible Server adds this endpoint itself (backups/WAL to Storage); declare it so plans don't remove it.
  service_endpoints = ["Microsoft.Storage"]

  delegation {
    name = "psql"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_network_security_group" "psql" {
  name                = "nsg-${var.project}-psql"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  security_rule {
    name                       = "allow-postgres-from-aca"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = azurerm_subnet.aca.address_prefixes[0]
    destination_address_prefix = azurerm_subnet.psql.address_prefixes[0]
  }

  security_rule {
    name                       = "deny-other-vnet-inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  # Entra token validation (plan §5 "Database logins").
  security_rule {
    name                       = "allow-entra-outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureActiveDirectory"
  }
}

resource "azurerm_subnet_network_security_group_association" "psql" {
  subnet_id                 = azurerm_subnet.psql.id
  network_security_group_id = azurerm_network_security_group.psql.id
}

# Optional fallback: explicit outbound for the database subnet, in case default outbound access
# doesn't reach Entra ID (error AadAuthPrincipalCreationFailed when creating the Entra admin).
resource "azurerm_public_ip" "nat" {
  count               = var.nat_gateway_enabled ? 1 : 0
  name                = "pip-${var.project}-nat"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "psql" {
  count               = var.nat_gateway_enabled ? 1 : 0
  name                = "ng-${var.project}-psql"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "psql" {
  count                = var.nat_gateway_enabled ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.psql[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "psql" {
  count          = var.nat_gateway_enabled ? 1 : 0
  subnet_id      = azurerm_subnet.psql.id
  nat_gateway_id = azurerm_nat_gateway.psql[0].id
}

# VNet-integrated Flexible Server needs a zone ending in .postgres.database.azure.com.
resource "azurerm_private_dns_zone" "psql" {
  name                = "${var.project}.private.postgres.database.azure.com"
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "psql" {
  name                  = "psql-to-vnet"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.psql.name
  virtual_network_id    = azurerm_virtual_network.this.id
  registration_enabled  = false
  tags                  = var.tags
}
