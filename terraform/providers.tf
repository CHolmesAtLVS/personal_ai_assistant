terraform {
  required_version = ">= 1.12"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.38"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.5"
    }
  }

  backend "azurerm" {}
}

provider "azurerm" {
  features {}
}
