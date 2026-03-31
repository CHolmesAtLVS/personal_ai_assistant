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

# Embedding model deployment variables (Azure OpenAI endpoint).

variable "embedding_model_name" {
  description = "Deployment name for the text embedding model (for example: text-embedding-3-large)."
  type        = string
  default     = "text-embedding-3-large"

  validation {
    condition     = trim(var.embedding_model_name, " ") != ""
    error_message = "embedding_model_name must not be empty."
  }
}

variable "embedding_model_version" {
  description = "Version of the text embedding model to deploy."
  type        = string
  default     = "1"
}

variable "embedding_model_capacity" {
  description = "Tokens-per-minute capacity for the embedding model deployment (in thousands)."
  type        = number
  default     = 50

  validation {
    condition     = var.embedding_model_capacity > 0
    error_message = "embedding_model_capacity must be a positive integer greater than zero."
  }
}

# Grok model deployment variables (Azure AI Model Inference endpoint).

variable "grok4fast_model_name" {
  description = "Model name for grok-4-fast-reasoning, passed as AZURE_AI_DEPLOYMENT_GROK4FAST env var."
  type        = string
  default     = "grok-4-fast-reasoning"

  validation {
    condition     = trim(var.grok4fast_model_name, " ") != ""
    error_message = "grok4fast_model_name must not be empty."
  }
}

variable "grok3_model_name" {
  description = "Model name for grok-3, passed as AZURE_AI_DEPLOYMENT_GROK3 env var."
  type        = string
  default     = "grok-3"

  validation {
    condition     = trim(var.grok3_model_name, " ") != ""
    error_message = "grok3_model_name must not be empty."
  }
}

variable "grok3mini_model_name" {
  description = "Model name for grok-3-mini, passed as AZURE_AI_DEPLOYMENT_GROK3MINI env var."
  type        = string
  default     = "grok-3-mini"

  validation {
    condition     = trim(var.grok3mini_model_name, " ") != ""
    error_message = "grok3mini_model_name must not be empty."
  }
}

# vm_* variables removed — dev VM is no longer managed by Terraform.
