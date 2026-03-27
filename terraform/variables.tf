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

variable "container_image_tag" {
  description = "Tag of the container image to deploy."
  type        = string
  default     = "latest"
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
