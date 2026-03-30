variable "project" {
  description = "Short project slug used in naming."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project))
    error_message = "project must be lowercase alphanumeric plus hyphen only."
  }
}

variable "environment" {
  description = "Deployment environment slug (for example: dev, prod)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.environment))
    error_message = "environment must be lowercase alphanumeric plus hyphen only."
  }
}

variable "location" {
  description = "Azure region for resources."
  type        = string
}

variable "owner" {
  description = "Owner tag value."
  type        = string
}

variable "cost_center" {
  description = "Cost center tag value."
  type        = string
}

variable "extra_tags" {
  description = "Additional tags merged onto required tags."
  type        = map(string)
  default     = {}
}

variable "public_ip" {
  description = "Public IP in CIDR form (used by ingress restrictions)."
  type        = string
  sensitive   = true
}

variable "ai_model_name" {
  description = "Name of the AI model to deploy (for example: gpt-4o)."
  type        = string
  default     = "gpt-4o"
}

variable "ai_model_version" {
  description = "Version of the AI model to deploy."
  type        = string
  default     = "2024-11-20"
}

variable "ai_model_capacity" {
  description = "Tokens-per-minute capacity for the AI model deployment (in thousands)."
  type        = number
  default     = 10

  validation {
    condition     = var.ai_model_capacity > 0
    error_message = "ai_model_capacity must be a positive integer greater than zero."
  }
}

variable "openclaw_image_repository" {
  description = "Container image repository for OpenClaw runtime."
  type        = string
  default     = "ghcr.io/openclaw/openclaw"

  validation {
    condition     = trim(var.openclaw_image_repository, " ") != ""
    error_message = "openclaw_image_repository must not be empty."
  }
}

variable "openclaw_image_tag" {
  description = "Pinned container image tag for OpenClaw runtime. Do not use mutable tags such as latest."
  type        = string
  default     = "2026.2.26"

  validation {
    condition     = lower(var.openclaw_image_tag) != "latest"
    error_message = "openclaw_image_tag must be a pinned version and cannot be latest."
  }
}

variable "container_image" {
  description = "Deprecated legacy image override. Leave unset; OpenClaw image is computed from openclaw_image_repository and openclaw_image_tag."
  type        = string
  default     = null

  validation {
    condition     = var.container_image == null
    error_message = "container_image is deprecated. Use openclaw_image_repository and openclaw_image_tag instead."
  }
}

variable "container_image_acr_server" {
  description = "ACR login server to configure as a registry credential on the Container App. Set when container_image is sourced from ACR. Leave null when using a public image."
  type        = string
  default     = null
}

variable "openclaw_state_share_quota_gb" {
  description = "Quota in GiB for the Azure Files share mounted at /home/node/.openclaw."
  type        = number
  default     = 100

  validation {
    condition     = var.openclaw_state_share_quota_gb >= 10 && var.openclaw_state_share_quota_gb <= 102400
    error_message = "openclaw_state_share_quota_gb must be between 10 and 102400."
  }
}

variable "openclaw_control_ui_allowed_origins_json" {
  description = "JSON array of HTTPS origins allowed for the OpenClaw Control UI (for example '[\"https://myapp.example.com\"]'). Used in the gateway bootstrap configuration. WARNING: leaving this as an empty array '[]' will cause the OpenClaw gateway to fail to start when gateway.bind=lan — the FQDN must be set before enabling the Container App."
  type        = string
  default     = "[]"

  validation {
    condition = (
      can(jsondecode(var.openclaw_control_ui_allowed_origins_json)) &&
      can([for o in jsondecode(var.openclaw_control_ui_allowed_origins_json) : o]) &&
      alltrue([
        for origin in jsondecode(var.openclaw_control_ui_allowed_origins_json) :
        startswith(origin, "https://")
      ])
    )
    error_message = "openclaw_control_ui_allowed_origins_json must be a JSON array of HTTPS origins (for example '[\"https://myapp.example.com\"]'). Use [] for an empty allow list."
  }
}

variable "monthly_budget_amount" {
  description = "Monthly USD budget cap for the OpenClaw resource group."
  type        = number
  default     = 25

  validation {
    condition     = var.monthly_budget_amount > 0
    error_message = "monthly_budget_amount must be greater than zero."
  }
}

variable "budget_alert_email" {
  description = "Email address for budget alert notifications. Must be injected via GitHub Secret; do not set a default or supply via a committed .tfvars file."
  type        = string
  sensitive   = true
}

variable "openclaw_gateway_token_enabled" {
  description = "Enable gateway token injection from Key Vault secret into the Container App. Set to true only after the openclaw-gateway-token secret has been provisioned in Key Vault."
  type        = bool
  default     = false
}

variable "enable_dev_vm" {
  description = "Deploy the Windows dev VM in the current environment."
  type        = bool
  default     = false
}

variable "vm_admin_username" {
  description = "Administrator username for the Windows dev VM."
  type        = string
  default     = "azureadmin"
}

variable "vm_admin_password" {
  description = "Administrator password for the Windows dev VM. Set via TF_VAR_vm_admin_password in dev.tfvars."
  type        = string
  sensitive   = true
  default     = null
}

variable "vm_size" {
  description = "VM SKU — must support nested virtualisation for Docker Desktop WSL2 backend."
  type        = string
  default     = "Standard_D4s_v5"

  validation {
    condition     = length(var.vm_size) > 0
    error_message = "vm_size must not be empty."
  }
}
