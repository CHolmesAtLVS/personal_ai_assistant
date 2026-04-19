module "aks" {
  source  = "Azure/avm-res-containerservice-managedcluster/azurerm"
  version = "~> 0.5"

  name             = "${local.name_prefix}-aks"
  parent_id        = module.resource_group.resource_id
  location         = var.location
  tags             = local.common_tags
  enable_telemetry = true

  kubernetes_version = var.aks_kubernetes_version

  sku = {
    name = "Base"
    tier = "Free"
  }

  oidc_issuer_profile = {
    enabled = true
  }

  security_profile = {
    workload_identity = {
      enabled = true
    }
  }

  network_profile = {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "azure"
    dns_service_ip      = "10.0.0.10"
    service_cidr        = "10.0.0.0/16"
  }

  default_agent_pool = {
    name            = "system"
    vm_size         = var.aks_node_vm_size
    count_of        = 1
    os_disk_size_gb = 30
    os_disk_type    = "Managed"
    node_taints     = ["CriticalAddonsOnly=true:NoSchedule"]
    node_labels     = { "role" = "system" }
  }

  agent_pools = {
    workload = {
      name            = "workload"
      vm_size         = var.aks_node_vm_size
      count_of        = 1
      os_disk_size_gb = 30
      os_disk_type    = "Managed"
      mode            = "User"
      node_labels     = { "role" = "workload" }
    }
  }

  managed_identities = {
    system_assigned            = false
    user_assigned_resource_ids = [module.aks_identity.resource_id]
  }

  addon_profile_key_vault_secrets_provider = {
    enabled = true
    config = {
      enable_secret_rotation = true
      rotation_poll_interval = "2m"
    }
  }

  addon_profile_oms_agent = {
    enabled = false
    config = {
      log_analytics_workspace_resource_id = module.logging.resource_id
      use_aad_auth                        = true
    }
  }

  api_server_access_profile = length(var.aks_api_authorized_ips) > 0 ? {
    authorized_ip_ranges = var.aks_api_authorized_ips
  } : null
}
