provider "azurerm" {
    version = "~>2.6.0"
    features {}
}

terraform {
    backend "azurerm" {
        resource_group_name  = "my-tfstate-rg"
        storage_account_name = "mytfstatestorage"
        container_name       = "tfstate"
        key                  = "shield.terraform.tfstate"
    }
}

resource "azurerm_resource_group" "berlin" {
    name = var.rgName
    location = var.Location
}

resource "azurerm_virtual_network" "mi_vnet" {
    name                = "mi-vnet"
    address_space       = ["10.10.0.0/16"]
    location            = azurerm_resource_group.berlin.location
    resource_group_name = azurerm_resource_group.berlin.name
}

resource "azurerm_subnet" "mi_subnet" {
    name                 = "mi-subnet"
    resource_group_name  = azurerm_resource_group.berlin.name
    virtual_network_name = azurerm_virtual_network.mi_vnet.name
    address_prefixes     = ["10.10.1.0/24"]
    delegation {
        name = "managedinstancedelegation"
        service_delegation {
            name = "Microsoft.Sql/managedInstances"
            actions = [
                "Microsoft.Network/virtualNetworks/subnets/action"
            ]
        }
    }
}

resource "azurerm_subnet" "jump_subnet" {
    name                 = "jump-subnet"
    resource_group_name  = azurerm_resource_group.berlin.name
    virtual_network_name = azurerm_virtual_network.mi_vnet.name
    address_prefixes     = ["10.10.2.0/24"]
}

locals {
    # UDR 
    mi_rt_routes = [
        {
            name           = "default"
            address_prefix = "0.0.0.0/0"
            next_hop_type  = "Internet"
        }
    ]
    # NSG Rules 
    mi_nsg_rules = [
        {
            name                       = "AllowOutboundToJump"
            priority                   = 100
            direction                  = "Outbound"
            access                     = "Allow"
            protocol                   = "*"
            source_port_range          = "*"
            destination_port_range     = "*"
            source_address_prefix      = "*"
            destination_address_prefix = azurerm_subnet.jump_subnet.address_prefixes[0]
        },
        {
            name                       = "AllowOutbound443"
            priority                   = 110
            direction                  = "Outbound"
            access                     = "Allow"
            protocol                   = "Tcp"
            source_port_range          = "*"
            destination_port_range     = "443"
            source_address_prefix      = "*"
            destination_address_prefix = "*"
        },
        {
            name                       = "AllowOutbound80"
            priority                   = 120
            direction                  = "Outbound"
            access                     = "Allow"
            protocol                   = "Tcp"
            source_port_range          = "*"
            destination_port_range     = "80"
            source_address_prefix      = "*"
            destination_address_prefix = "*"
        },
        // Required ports for SQL Managed Instance outbound (examples, adjust as needed)
        {
            name                       = "AllowOutboundSQLMI"
            priority                   = 130
            direction                  = "Outbound"
            access                     = "Allow"
            protocol                   = "Tcp"
            source_port_range          = "*"
            destination_port_range     = "1433"
            source_address_prefix      = "*"
            destination_address_prefix = "*"
        },
        {
            name                       = "DenyAllOutbound"
            priority                   = 4096
            direction                  = "Outbound"
            access                     = "Deny"
            protocol                   = "*"
            source_port_range          = "*"
            destination_port_range     = "*"
            source_address_prefix      = "*"
            destination_address_prefix = "*"
        }
    ]
}

resource "azurerm_network_security_group" "mi_nsg" {
    name                = "mi-nsg"
    location            = azurerm_resource_group.berlin.location
    resource_group_name = azurerm_resource_group.berlin.name

    dynamic "security_rule" {
        for_each = local.mi_nsg_rules
        content {
            name                       = security_rule.value.name
            priority                   = security_rule.value.priority
            direction                  = security_rule.value.direction
            access                     = security_rule.value.access
            protocol                   = security_rule.value.protocol
            source_port_range          = security_rule.value.source_port_range
            destination_port_range     = security_rule.value.destination_port_range
            source_address_prefix      = security_rule.value.source_address_prefix
            destination_address_prefix = security_rule.value.destination_address_prefix
        }
    }
}

resource "azurerm_subnet_network_security_group_association" "mi_subnet_nsg_assoc" {
    subnet_id                 = azurerm_subnet.mi_subnet.id
    network_security_group_id = azurerm_network_security_group.mi_nsg.id
}

resource "azurerm_route_table" "mi_rt" {
    name                = "mi-rt"
    location            = azurerm_resource_group.berlin.location
    resource_group_name = azurerm_resource_group.berlin.name

    dynamic "route" {
        for_each = local.mi_rt_routes
        content {
            name           = route.value.name
            address_prefix = route.value.address_prefix
            next_hop_type  = route.value.next_hop_type
        }
    }
}

resource "azurerm_subnet_route_table_association" "mi_subnet_rt_assoc" {
    subnet_id      = azurerm_subnet.mi_subnet.id
    route_table_id = azurerm_route_table.mi_rt.id
}

resource "azurerm_sql_managed_instance" "mi" {
    name                         = var.sql_mi_name
    resource_group_name          = azurerm_resource_group.berlin.name
    location                     = azurerm_resource_group.berlin.location
    subnet_id                    = azurerm_subnet.mi_subnet.id
    administrator_login          = var.sql_admin_username
    administrator_login_password = var.sql_admin_password
    license_type                 = var.sql_mi_license_type
    sku_name                     = var.sql_mi_sku_name
    storage_size_in_gb           = var.sql_mi_storage_size_in_gb
    vcores                       = var.sql_mi_vcores
    public_data_endpoint_enabled = var.sql_mi_public_data_endpoint_enabled
    tags = var.sql_mi_tags
}


resource "azurerm_network_security_group" "jumpbox_nsg" {
    name                = "jumpbox-nsg"
    location            = azurerm_resource_group.berlin.location
    resource_group_name = azurerm_resource_group.berlin.name

    security_rule {
        name                       = "AllowInboundFromMI"
        priority                   = 100
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "*"
        source_port_range          = "*"
        destination_port_range     = "*"
        source_address_prefix      = azurerm_subnet.mi_subnet.address_prefixes[0]
        destination_address_prefix = "*"
    }

    security_rule {
        name                       = "AllowOutboundToMI"
        priority                   = 100
        direction                  = "Outbound"
        access                     = "Allow"
        protocol                   = "*"
        source_port_range          = "*"
        destination_port_range     = "*"
        source_address_prefix      = "*"
        destination_address_prefix = azurerm_subnet.mi_subnet.address_prefixes[0]
    }

    security_rule {
        name                       = "AllowRDP"
        priority                   = 200
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "3389"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }
}

resource "azurerm_subnet_network_security_group_association" "jumpbox_subnet_nsg_assoc" {
    subnet_id                 = azurerm_subnet.jump_subnet.id
    network_security_group_id = azurerm_network_security_group.jumpbox_nsg.id
}

resource "azurerm_network_interface" "jumpbox_nic" {
    name                = "jumpbox-nic"
    location            = azurerm_resource_group.berlin.location
    resource_group_name = azurerm_resource_group.berlin.name

    ip_configuration {
        name                          = "internal"
        subnet_id                     = azurerm_subnet.jump_subnet.id
        private_ip_address_allocation = "Dynamic"
        public_ip_address_id          = azurerm_public_ip.jumpbox_public_ip.id
    }
}

resource "azurerm_public_ip" "jumpbox_public_ip" {
    name                = "jumpbox-public-ip"
    location            = azurerm_resource_group.berlin.location
    resource_group_name = azurerm_resource_group.berlin.name
    allocation_method   = "Dynamic"
    sku                 = "Basic"
}

resource "azurerm_windows_virtual_machine" "jumpbox" {
    name                = "jumpbox-vm"
    resource_group_name = azurerm_resource_group.berlin.name
    location            = azurerm_resource_group.berlin.location
    size                = "Standard_B2ms"
    admin_username      = var.jumpbox_admin_username
    admin_password      = var.jumpbox_admin_password
    network_interface_ids = [
        azurerm_network_interface.jumpbox_nic.id
    ]
    os_disk {
        caching              = "ReadWrite"
        storage_account_type = "Standard_LRS"
        name                 = "jumpbox-osdisk"
    }
    source_image_reference {
        publisher = "MicrosoftWindowsServer"
        offer     = "WindowsServer"
        sku       = "2019-Datacenter"
        version   = "latest"
    }
    tags = var.jumpbox_tags
}