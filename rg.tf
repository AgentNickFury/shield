provider "azurerm" {
    version = "~>2.6.0"
    features {}
}

resource "azurerm_resource_group" "berlin" {
    name = var.rgName
    location = var.Location
}