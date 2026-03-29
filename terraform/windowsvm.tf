locals {
  vm_setup_script = join("; ", [
    "$ProgressPreference = 'SilentlyContinue'",
    "Set-ExecutionPolicy Bypass -Scope Process -Force",
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12",
    "Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))",
    "& \"$env:ProgramData\\chocolatey\\bin\\choco.exe\" install vscode -y --no-progress",
    "& \"$env:ProgramData\\chocolatey\\bin\\choco.exe\" install docker-desktop -y --no-progress"
  ])
}

module "vm_nsg" {
  source  = "Azure/avm-res-network-networksecuritygroup/azurerm"
  version = "~> 0.3"
  count   = var.enable_dev_vm ? 1 : 0

  name                = local.vm_nsg_name
  location            = var.location
  resource_group_name = module.resource_group.name
  tags                = local.common_tags
  enable_telemetry    = true

  security_rules = {
    allow_rdp_inbound = {
      name                       = "AllowRdpFromHomeIP"
      priority                   = 100
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "3389"
      source_address_prefix      = var.public_ip
      destination_address_prefix = "*"
    }
  }
}

module "vm_pip" {
  source  = "Azure/avm-res-network-publicipaddress/azurerm"
  version = "~> 0.1"
  count   = var.enable_dev_vm ? 1 : 0

  name                = local.vm_pip_name
  location            = var.location
  resource_group_name = module.resource_group.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
  enable_telemetry    = true
}

module "vm_vnet" {
  source  = "Azure/avm-res-network-virtualnetwork/azurerm"
  version = "~> 0.8"
  count   = var.enable_dev_vm ? 1 : 0

  name             = local.vm_vnet_name
  location         = var.location
  parent_id        = module.resource_group.resource_id
  address_space    = ["10.10.0.0/24"]
  tags             = local.common_tags
  enable_telemetry = true

  subnets = {
    vm_subnet = {
      name             = "${local.name_prefix}-vm-snet"
      address_prefixes = ["10.10.0.0/24"]
      network_security_group = {
        id = module.vm_nsg[0].resource_id
      }
    }
  }
}

module "vm" {
  source  = "Azure/avm-res-compute-virtualmachine/azurerm"
  version = "~> 0.19"
  count   = var.enable_dev_vm ? 1 : 0

  name                = local.vm_name
  location            = var.location
  resource_group_name = module.resource_group.name
  tags                = local.common_tags
  enable_telemetry    = true

  os_type  = "Windows"
  sku_size = var.vm_size
  zone     = null

  generate_admin_password_or_ssh_key = false
  admin_username                     = var.vm_admin_username
  admin_password                     = var.vm_admin_password

  os_disk = {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference = {
    publisher = "MicrosoftWindowsDesktop"
    offer     = "windows-11"
    sku       = "win11-24h2-pro"
    version   = "latest"
  }

  network_interfaces = {
    nic_0 = {
      name = local.vm_nic_name
      ip_configurations = {
        ipconfig_0 = {
          name                          = "ipconfig0"
          private_ip_subnet_resource_id = module.vm_vnet[0].subnets["vm_subnet"].resource_id
          public_ip_address_resource_id = module.vm_pip[0].resource_id
          is_primary                    = true
        }
      }
    }
  }

  depends_on = [module.vm_vnet, module.vm_pip]
}

resource "azurerm_virtual_machine_extension" "vm_setup" {
  count                = var.enable_dev_vm ? 1 : 0
  name                 = "install-dev-tools"
  virtual_machine_id   = module.vm[0].resource_id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"
  tags                 = local.common_tags

  settings = jsonencode({
    commandToExecute = "powershell -ExecutionPolicy Bypass -Command \"${replace(local.vm_setup_script, "\"", "\\\"")}\" "
  })

  depends_on = [module.vm]
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "vm" {
  count              = var.enable_dev_vm ? 1 : 0
  virtual_machine_id = module.vm[0].resource_id
  location           = var.location
  enabled            = true
  tags               = local.common_tags

  daily_recurrence_time = "2100"
  timezone              = "UTC"

  notification_settings {
    enabled = false
  }
}
