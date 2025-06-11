#######################################
# Terraform configuration for deploying a secure SQL Server VM on Azure
# This file provisions:
# - Resource group
# - Virtual network and subnet
# - Network security group with rules for RDP and SQL
# - Public IP and network interface
# - Windows VM with SQL Server
# - Outputs for public IP and admin password
#######################################

############## variables
#######################################
variable "location" {
    description = "Azure region for resources"
    default     = "North Europe"

    validation {
        condition     = contains(["North Europe", "West Europe"], var.location)
        error_message = "The location must be one of: East US, East US 2, West US, West US 2, Central US, North Europe, West Europe."
    }
}

variable "admin_username" {
    description = "Admin username for SQL Server VM"
    default     = "sqladminuser"

    validation {
        condition     = length(var.admin_username) >= 5 && length(var.admin_username) <= 20
        error_message = "The admin_username must be between 5 and 20 characters in length."
    }
}

variable "rdp_allowed_ip" {
    description = "IP allowed to RDP (set to your public IP)"
    default     = "10.0.164.1/32"
}

variable "sql_allowed_ip" {
    description = "IP allowed to access SQL (set to your public IP or subnet)"
    default     = "10.0.164.1/32"
}

#######################################
############## locals
#######################################

locals {
    resource_group_name      = "sqlserver-rg"
    environment             = "production"
    workload                = "sqlserver"
    vnet_name               = "sqlserver-vnet"
    vnet_address_space      = ["10.0.0.0/16"]
    subnet_name             = "sqlserver-subnet"
    subnet_address_prefixes = ["10.0.1.0/24"]
    nsg_name                = "sqlserver-nsg"
    public_ip_name          = "sqlserver-pip"
    nic_name                = "sqlserver-nic"
    vm_name                 = "sqlserver-vm"
    vm_size                 = "Standard_DS2_v2"
    computer_name           = "sqlvm"
    os_disk_name            = "sqlserver-osdisk"
    os_disk_size_gb         = 128
    os_disk_type            = "Premium_LRS"
    sql_publisher           = "MicrosoftSQLServer"
    sql_offer               = "SQL2019-WS2019"
    sql_sku                 = "Standard"
    sql_version             = "latest"
    license_type            = "Windows_Server"
    timezone                = "Pacific Standard Time"
    # Define NSG rules for RDP and SQL access
    nsg_rules = [
      {
        # Allow RDP from specified IP
        name                       = "Allow-RDP"
        priority                   = 1001
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "3389"
        source_address_prefix      = var.rdp_allowed_ip
        destination_address_prefix = "*"
      },
      {
        # Allow SQL from specified IP
        name                       = "Allow-SQL"
        priority                   = 1002
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "1433"
        source_address_prefix      = var.sql_allowed_ip
        destination_address_prefix = "*"
      }
    ]
}

#######################################
############## resources
#######################################

# Generate a strong random password for the SQL Server admin user
resource "random_password" "sql_admin" {
    length  = 16   # Password length of 16 characters
    special = true # Include special characters for increased security
}

# Create a resource group
resource "azurerm_resource_group" "sql_rg" {
    name     = local.resource_group_name
    location = var.location
    tags = {
        environment = local.environment
        workload    = local.workload
    }

    lifecycle {
        ignore_changes = [tags]
    }
}

# Create a virtual network
resource "azurerm_virtual_network" "sql_vnet" {
    name                = local.vnet_name
    address_space       = local.vnet_address_space
    location            = azurerm_resource_group.sql_rg.location
    resource_group_name = azurerm_resource_group.sql_rg.name
    dns_servers         = [] # Optionally specify custom DNS servers, e.g., ["10.0.0.4", "10.0.0.5"]
    bgp_community       = null # Optionally specify a BGP community
    flow_timeout_in_minutes = null # Optionally specify flow timeout
    tags                = azurerm_resource_group.sql_rg.tags

    dynamic "subnet" {
      for_each = local.subnet_address_prefixes
      content {
        name           = local.subnet_name
        address_prefix = subnet.value
      }
    }
}

# Create a subnet within the virtual network
resource "azurerm_subnet" "sql_subnet" {
    name                 = local.subnet_name
    resource_group_name  = azurerm_resource_group.sql_rg.name
    virtual_network_name = azurerm_virtual_network.sql_vnet.name
    address_prefixes     = local.subnet_address_prefixes
}

# Create a network security group with rules for RDP and SQL
resource "azurerm_network_security_group" "sql_nsg" {
    name                = local.nsg_name
    location            = azurerm_resource_group.sql_rg.location
    resource_group_name = azurerm_resource_group.sql_rg.name

    dynamic "security_rule" {
      for_each = local.nsg_rules
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

# Create a public IP address for the VM
resource "azurerm_public_ip" "sql_pip" {
    name                = local.public_ip_name
    location            = azurerm_resource_group.sql_rg.location
    resource_group_name = azurerm_resource_group.sql_rg.name
    allocation_method   = "Static"
    sku                 = "Standard"
    tags                = azurerm_resource_group.sql_rg.tags
}

# Create a network interface and associate it with the subnet and public IP
resource "azurerm_network_interface" "sql_nic" {
    name                = local.nic_name
    location            = azurerm_resource_group.sql_rg.location
    resource_group_name = azurerm_resource_group.sql_rg.name

    dynamic "ip_configuration" {
      for_each = [1]
      content {
        name                          = "internal"
        subnet_id                     = azurerm_subnet.sql_subnet.id
        private_ip_address_allocation = "Dynamic"
        public_ip_address_id          = azurerm_public_ip.sql_pip.id
      }
    }
    tags = azurerm_resource_group.sql_rg.tags
}

# Associate the network interface with the network security group
resource "azurerm_network_interface_security_group_association" "sql_nic_nsg" {
    network_interface_id      = azurerm_network_interface.sql_nic.id
    network_security_group_id = azurerm_network_security_group.sql_nsg.id
}

# Create the Windows VM with SQL Server
resource "azurerm_windows_virtual_machine" "sql_vm" {
    name                = local.vm_name
    resource_group_name = azurerm_resource_group.sql_rg.name
    location            = azurerm_resource_group.sql_rg.location
    size                = local.vm_size
    admin_username      = var.admin_username
    admin_password      = random_password.sql_admin.result
    network_interface_ids = [
        azurerm_network_interface.sql_nic.id,
    ]
    computer_name = local.computer_name

    os_disk {
        caching              = "ReadWrite"
        storage_account_type = local.os_disk_type
        disk_size_gb         = local.os_disk_size_gb
        name                 = local.os_disk_name
    }

    source_image_reference {
        publisher = local.sql_publisher
        offer     = local.sql_offer
        sku       = local.sql_sku
        version   = local.sql_version
    }

    license_type               = local.license_type
    enable_automatic_updates   = true
    timezone                   = local.timezone
    provision_vm_agent         = true
    tags                       = azurerm_resource_group.sql_rg.tags

    boot_diagnostics {
        storage_account_uri = null
    }
}

# Output the public IP address of the SQL Server VM
output "sql_vm_public_ip" {
    value       = azurerm_public_ip.sql_pip.ip_address
    description = "Public IP address of the SQL Server VM"
}

# Output the admin password for the SQL Server VM (sensitive)
output "sql_vm_admin_password" {
    value       = random_password.sql_admin.result
    sensitive   = true
    description = "Admin password for the SQL Server VM"
}

# Install SQL Server Management Studio (SSMS) using a custom script extension
resource "azurerm_virtual_machine_extension" "ssms_install" {
    name                 = "InstallSSMS"
    virtual_machine_id   = azurerm_windows_virtual_machine.sql_vm.id
    publisher            = "Microsoft.Compute"
    type                 = "CustomScriptExtension"
    type_handler_version = "1.10"

    settings = <<SETTINGS
        {
            "commandToExecute": "powershell -ExecutionPolicy Unrestricted -Command \"Invoke-WebRequest -Uri https://aka.ms/ssms -OutFile C:\\SSMS-Setup.exe; Start-Process -FilePath C:\\SSMS-Setup.exe -ArgumentList '/install','/quiet','/norestart' -Wait\""
        }
SETTINGS
}