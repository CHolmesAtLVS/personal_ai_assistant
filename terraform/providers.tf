terraform {
  required_version = ">= 1.12"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.46"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }

  backend "azurerm" {}
}

provider "azurerm" {
  features {}
}

# ── Helm provider ────────────────────────────────────────────────────────────
# Connects to the AKS cluster using the user kubeconfig emitted by the AKS
# module. On the very first apply (cluster does not yet exist), run:
#   terraform apply -target=module.aks
# then re-run terraform apply to apply the helm releases.
# On all subsequent applies the cluster is in state and this is automatic.
locals {
  # kube_config is null before the cluster is created; try() returns safe
  # defaults so Terraform can produce a plan even on first run.
  _kube = try(yamldecode(nonsensitive(module.aks.kube_config)), null)
}

provider "helm" {
  kubernetes {
    host                   = try(local._kube.clusters[0].cluster.server, "")
    cluster_ca_certificate = try(base64decode(local._kube.clusters[0].cluster["certificate-authority-data"]), "")
    client_certificate     = try(base64decode(local._kube.users[0].user["client-certificate-data"]), "")
    client_key             = try(base64decode(local._kube.users[0].user["client-key-data"]), "")
  }
}
