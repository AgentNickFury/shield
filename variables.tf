# variable "rgName" {
#    type = "string"
#    default = "tokyo"
#    description = "Name of the resource group"
#}

#variable "Location" {
#    type = "string"
#    default = "East us2"
#    description = "Location of the resource group"
#}


variable "rgName" {
    type        = string
    default     = "tokyo"
    description = "Name of the resource group"
    validation {
        condition     = length(var.rgName) > 3 && length(var.rgName) < 50
        error_message = "The resource group name must be between 4 and 50 characters."
    }
}

variable "location" {
    type        = string
    default     = "East US2"
    description = "Location of the resource group"
    validation {
        condition     = contains(["East US", "East US2", "West US", "West Europe"], var.location)
        error_message = "The location must be one of the allowed Azure regions."
    }
}

variable "tags" {
    type        = map(string)
    default     = {
        environment = "production"
        owner       = "admin"
    }
    description = "A map of tags to assign to resources."
}

variable "admin_password" {
    type        = string
    description = "The admin password for the virtual machine."
    sensitive   = true
    validation {
        condition     = length(var.admin_password) >= 12 && regex("[A-Z]", var.admin_password) && regex("[0-9]", var.admin_password)
        error_message = "The admin password must be at least 12 characters long and include at least one uppercase letter and one number."
    }
}

variable "allowed_ips" {
    type        = list(string)
    description = "A list of IP addresses allowed to access the system."
    default     = ["192.168.1.1", "10.0.0.1"]
    validation {
        condition     = length(var.allowed_ips) > 0
        error_message = "You must provide at least one IP address."
    }
}