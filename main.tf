variable "enabled_environments" {
    type    = list(string)
    default = ["dev", "prod"]
}

variable "all_environments" {
    type    = list(string)
    default = ["dev", "test", "prod"]
}

variable "regions" {
    type    = list(string)
    default = ["East US", "West Europe"]
}

variable "resource_flags" {
    description = "Flags to enable/disable resources"
    type = object({
        vnet              = bool
        app_gateway       = bool
        private_dns_zone  = bool
        aks               = bool
    })
    default = {
        vnet              = true
        app_gateway       = true
        private_dns_zone  = true
        aks               = true
    }
}

locals {
    active_environments = [env for env in var.all_environments if contains(var.enabled_environments, env)]
}

# Resource Group
resource "azurerm_resource_group" "main" {
    for_each = { for env in local.active_environments : env => env }
    name     = "rg-${each.key}"
    location = var.regions[0]
}

# Virtual Network
resource "azurerm_virtual_network" "main" {
    for_each = var.resource_flags.vnet ? { for env in local.active_environments : env => env } : {}
    name                = "vnet-${each.key}"
    address_space       = ["10.${100 + index(local.active_environments, each.key)}.0.0/16"]
    location            = var.regions[0]
    resource_group_name = azurerm_resource_group.main[each.key].name
}

# Application Gateway
resource "azurerm_public_ip" "appgw" {
    for_each = var.resource_flags.app_gateway ? { for env in local.active_environments : env => env } : {}
    name                = "pip-appgw-${each.key}"
    location            = var.regions[0]
    resource_group_name = azurerm_resource_group.main[each.key].name
    allocation_method   = "Dynamic"
    sku                 = "Standard"
}

resource "azurerm_application_gateway" "main" {
    for_each = var.resource_flags.app_gateway ? { for env in local.active_environments : env => env } : {}
    name                = "appgw-${each.key}"
    location            = var.regions[0]
    resource_group_name = azurerm_resource_group.main[each.key].name

    sku {
        name     = "Standard_v2"
        tier     = "Standard_v2"
        capacity = 2
    }

    gateway_ip_configuration {
        name      = "appgw-ipcfg"
        subnet_id = azurerm_subnet.appgw[each.key].id
    }

    frontend_port {
        name = "frontendPort"
        port = 80
    }

    frontend_ip_configuration {
        name                 = "frontendIP"
        public_ip_address_id = azurerm_public_ip.appgw[each.key].id
    }

    backend_address_pool {
        name = "backendPool"
    }

    backend_http_settings {
        name                  = "httpSettings"
        cookie_based_affinity = "Disabled"
        port                  = 80
        protocol              = "Http"
    }

    http_listener {
        name                           = "httpListener"
        frontend_ip_configuration_name = "frontendIP"
        frontend_port_name             = "frontendPort"
        protocol                       = "Http"
    }

    request_routing_rule {
        name                       = "rule1"
        rule_type                  = "Basic"
        http_listener_name         = "httpListener"
        backend_address_pool_name  = "backendPool"
        backend_http_settings_name = "httpSettings"
    }
}

resource "azurerm_subnet" "appgw" {
    for_each = var.resource_flags.app_gateway ? { for env in local.active_environments : env => env } : {}
    name                 = "subnet-appgw-${each.key}"
    resource_group_name  = azurerm_resource_group.main[each.key].name
    virtual_network_name = azurerm_virtual_network.main[each.key].name
    address_prefixes     = ["10.${100 + index(local.active_environments, each.key)}.1.0/24"]
}

# Private DNS Zone
resource "azurerm_private_dns_zone" "main" {
    for_each = var.resource_flags.private_dns_zone ? { for env in local.active_environments : env => env } : {}
    name                = "privatedns-${each.key}.local"
    resource_group_name = azurerm_resource_group.main[each.key].name
}

# Managed NAT Gateway for AKS Egress
resource "azurerm_nat_gateway" "main" {
    for_each = var.resource_flags.aks ? { for env in local.active_environments : env => env } : {}
    name                = "natgw-${each.key}"
    location            = var.regions[0]
    resource_group_name = azurerm_resource_group.main[each.key].name

    sku_name = "Standard"
    # No public_ip_address_ids or public_ip_prefix_ids for managed NAT Gateway
    # Azure will manage the outbound IPs automatically
}

resource "azurerm_subnet" "aks" {
    for_each = var.resource_flags.aks ? { for env in local.active_environments : env => env } : {}
    name                 = "subnet-aks-${each.key}"
    resource_group_name  = azurerm_resource_group.main[each.key].name
    virtual_network_name = azurerm_virtual_network.main[each.key].name
    address_prefixes     = ["10.${100 + index(local.active_environments, each.key)}.2.0/24"]

    delegation {
        name = "aks_delegation"
        service_delegation {
            name = "Microsoft.ContainerService/managedClusters"
            actions = [
                "Microsoft.Network/virtualNetworks/subnets/action"
            ]
        }
    }
}

resource "azurerm_subnet_nat_gateway_association" "aks" {
    for_each = var.resource_flags.aks ? { for env in local.active_environments : env => env } : {}
    subnet_id      = azurerm_subnet.aks[each.key].id
    nat_gateway_id = azurerm_nat_gateway.main[each.key].id
}

# AKS Cluster
resource "azurerm_kubernetes_cluster" "main" {
    for_each = var.resource_flags.aks ? { for env in local.active_environments : env => env } : {}
    name                = "aks-${each.key}"
    location            = var.regions[0]
    resource_group_name = azurerm_resource_group.main[each.key].name
    dns_prefix          = "aks-${each.key}"

    default_node_pool {
        name            = "default"
        node_count      = 1
        vm_size         = "Standard_DS2_v2"
        vnet_subnet_id  = azurerm_subnet.aks[each.key].id
        outbound_type   = "managedNATGateway"
    }

    identity {
        type = "SystemAssigned"
    }

    network_profile {
        network_plugin      = "azure"
        dns_service_ip      = "10.2.0.10"
        service_cidr        = "10.2.0.0/24"
        docker_bridge_cidr  = "172.17.0.1/16"
    }
}

# Role Assignment Example (AKS to Private DNS Zone)
resource "azurerm_role_assignment" "aks_dns" {
    for_each = var.resource_flags.aks && var.resource_flags.private_dns_zone ? { for env in local.active_environments : env => env } : {}
    scope                = azurerm_private_dns_zone.main[each.key].id
    role_definition_name = "Private DNS Zone Contributor"
    principal_id         = azurerm_kubernetes_cluster.main[each.key].identity[0].principal_id
}

# Azure Backup for AKS (Backup Vault + Backup Policy + Backup Instance)

# Creates a Backup Vault for AKS backups in each environment
resource "azurerm_data_protection_backup_vault" "aks" {
    for_each            = var.resource_flags.aks ? { for env in local.active_environments : env => env } : {}
    name                = "backupvault-aks-${each.key}"
    location            = var.regions[0]
    resource_group_name = azurerm_resource_group.main[each.key].name
    datastore_type      = "VaultStore"
    redundancy          = "LocallyRedundant"
}

# Defines a backup policy for AKS clusters (daily backup, 30 days retention)
resource "azurerm_data_protection_backup_policy_kubernetes_cluster" "aks" {
    for_each            = var.resource_flags.aks ? { for env in local.active_environments : env => env } : {}
    name                = "backup-policy-aks-${each.key}"
    vault_id            = azurerm_data_protection_backup_vault.aks[each.key].id

    backup_repeating_time_intervals = ["R/2024-01-01T00:00:00+00:00/P1D"] # Daily backup
    default_retention_duration      = "P30D" # 30 days retention
}

# Associates the AKS cluster with the backup vault and policy to enable backups
resource "azurerm_data_protection_backup_instance_kubernetes_cluster" "aks" {
    for_each            = var.resource_flags.aks ? { for env in local.active_environments : env => env } : {}
    name                = "backupinstance-aks-${each.key}"
    location            = var.regions[0]
    resource_group_name = azurerm_resource_group.main[each.key].name
    vault_id            = azurerm_data_protection_backup_vault.aks[each.key].id

    kubernetes_cluster_id = azurerm_kubernetes_cluster.main[each.key].id
    backup_policy_id      = azurerm_data_protection_backup_policy_kubernetes_cluster.aks[each.key].id
}

# Azure Cache for Redis
resource "azurerm_redis_cache" "main" {
    for_each            = { for env in local.active_environments : env => env }
    name                = "redis-${each.key}"
    location            = var.regions[0]
    resource_group_name = azurerm_resource_group.main[each.key].name
    capacity            = 1
    family              = "C"
    sku_name            = "Basic"
    enable_non_ssl_port = false

    redis_configuration {
        maxmemory_policy = "allkeys-lru"
    }
}

# Private Endpoint for Redis Cache
resource "azurerm_private_endpoint" "redis" {
    for_each            = { for env in local.active_environments : env => env }
    name                = "pe-redis-${each.key}"
    location            = var.regions[0]
    resource_group_name = azurerm_resource_group.main[each.key].name
    subnet_id           = azurerm_subnet.appgw[each.key].id

    private_service_connection {
        name                           = "psc-redis-${each.key}"
        private_connection_resource_id = azurerm_redis_cache.main[each.key].id
        subresource_names              = ["redisCache"]
        is_manual_connection           = false
    }
}

# Private DNS Zone for Redis Cache
resource "azurerm_private_dns_zone" "redis" {
    for_each            = { for env in local.active_environments : env => env }
    name                = "privatelink.redis.cache.windows.net"
    resource_group_name = azurerm_resource_group.main[each.key].name
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
    for_each              = { for env in local.active_environments : env => env }
    name                  = "vnet-link-redis-${each.key}"
    resource_group_name   = azurerm_resource_group.main[each.key].name
    private_dns_zone_name = azurerm_private_dns_zone.redis[each.key].name
    virtual_network_id    = azurerm_virtual_network.main[each.key].id
}

resource "azurerm_private_dns_a_record" "redis" {
    for_each              = { for env in local.active_environments : env => env }
    name                  = azurerm_redis_cache.main[each.key].name
    zone_name             = azurerm_private_dns_zone.redis[each.key].name
    resource_group_name   = azurerm_resource_group.main[each.key].name
    ttl                   = 300
    records               = [azurerm_private_endpoint.redis[each.key].private_service_connection[0].private_ip_address]
}