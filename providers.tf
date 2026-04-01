################################################################################
# providers.tf — Dual-Region Provider Configuration
# Two providers, one goal: no single point of failure.
################################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state — encrypted, versioned, region-agnostic
  backend "s3" {
    bucket         = "tf-state-resilience-backbone"
    key            = "global/terraform.tfstate"
    region         = "af-south-1"
    encrypt        = true
    dynamodb_table = "tf-state-lock"
  }
}

# ── Primary: Cape Town — where the load is served ────────────────────────────
provider "aws" {
  alias  = "cape_town"
  region = var.primary_region

  default_tags {
    tags = merge(var.tags, {
      Project     = var.project_name
      Environment = var.environment
      Region      = "primary"
      ManagedBy   = "terraform"
    })
  }
}

# ── Failover: Ireland — the silent standby ────────────────────────────────────
provider "aws" {
  alias  = "ireland"
  region = var.failover_region

  default_tags {
    tags = merge(var.tags, {
      Project     = var.project_name
      Environment = var.environment
      Region      = "failover"
      ManagedBy   = "terraform"
    })
  }
}

# ── Route 53 ARC requires us-west-2 — non-negotiable AWS constraint ───────────
provider "aws" {
  alias  = "arc_control_plane"
  region = "us-west-2"

  default_tags {
    tags = merge(var.tags, {
      Project   = var.project_name
      ManagedBy = "terraform"
      Purpose   = "arc-control-plane"
    })
  }
}
