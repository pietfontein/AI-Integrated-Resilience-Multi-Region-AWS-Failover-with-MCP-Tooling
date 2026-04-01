################################################################################
# variables.tf — Hardened Input Sanitation Layer
# Principle: Fail-Closed on Invalid Input. No garbage enters state.
################################################################################

variable "environment" {
  description = "Deployment environment (dev/prod)"
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be either 'dev' or 'prod'. Fail closed on invalid input."
  }
}

variable "replica_count" {
  description = "Number of EC2/Container replicas per region"
  type        = number

  validation {
    condition     = var.replica_count >= 1 && var.replica_count <= 10
    error_message = "Replica count must be between 1 and 10 to ensure resource quotas and cost bounds."
  }
}

variable "bucket_name" {
  description = "S3 bucket for regional state assets"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9.-]{3,63}$", var.bucket_name))
    error_message = "Bucket name must be 3-63 chars, lowercase, following DNS-compliant sanitation."
  }
}

variable "primary_region" {
  description = "Primary AWS region (Cape Town — the engine)"
  type        = string
  default     = "af-south-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.primary_region))
    error_message = "Region must be a valid AWS region format (e.g. af-south-1)."
  }
}

variable "failover_region" {
  description = "Failover AWS region (Ireland — the emergency generator)"
  type        = string
  default     = "eu-west-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.failover_region))
    error_message = "Region must be a valid AWS region format (e.g. eu-west-1)."
  }
}

variable "project_name" {
  description = "Project identifier, used in resource naming"
  type        = string
  default     = "resilience-backbone"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,32}$", var.project_name))
    error_message = "Project name must be 3-32 chars, lowercase alphanumeric and hyphens only."
  }
}

variable "ec2_instance_type" {
  description = "EC2 instance type for application nodes"
  type        = string
  default     = "t3.micro"

  validation {
    condition = contains([
      "t3.micro", "t3.small", "t3.medium",
      "m5.large", "m5.xlarge"
    ], var.ec2_instance_type)
    error_message = "Instance type must be an approved size to enforce FinOps cost controls."
  }
}

variable "allowed_cidr_blocks" {
  description = "Allowlist of CIDR ranges that may reach the application layer"
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.allowed_cidr_blocks :
      can(cidrhost(cidr, 0))
    ])
    error_message = "All entries in allowed_cidr_blocks must be valid CIDR notation."
  }
}

variable "tags" {
  description = "Common resource tags applied to all infrastructure"
  type        = map(string)
  default     = {}

  validation {
    condition     = length(var.tags) <= 50
    error_message = "AWS enforces a maximum of 50 tags per resource."
  }
}
