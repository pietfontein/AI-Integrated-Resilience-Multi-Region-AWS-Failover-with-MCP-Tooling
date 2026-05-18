################################################################################
# providers.tf — Dual-Region Provider Configuration
################################################################################

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Real AWS: terraform init -backend-config=config/backend.aws.hcl
  # LocalStack: terraform init -backend-config=config/backend.localstack.hcl
  backend "s3" {}
}

provider "aws" {
  alias  = "cape_town"
  region = var.primary_region

  access_key = var.use_localstack ? "test" : null
  secret_key = var.use_localstack ? "test" : null

  s3_use_path_style           = var.use_localstack
  skip_credentials_validation = var.use_localstack
  skip_metadata_api_check     = var.use_localstack
  skip_requesting_account_id  = var.use_localstack

  dynamic "endpoints" {
    for_each = var.use_localstack ? [var.localstack_endpoint] : []
    content {
      apigateway = endpoints.value
      dynamodb   = endpoints.value
      ec2        = endpoints.value
      elb        = endpoints.value
      elbv2      = endpoints.value
      iam        = endpoints.value
      route53    = endpoints.value
      s3         = endpoints.value
      sts        = endpoints.value
      ssm        = endpoints.value
    }
  }

  default_tags {
    tags = merge(var.tags, {
      Project     = var.project_name
      Environment = var.environment
      Region      = "primary"
      ManagedBy   = "terraform"
    })
  }
}

provider "aws" {
  alias  = "ireland"
  region = var.failover_region

  access_key = var.use_localstack ? "test" : null
  secret_key = var.use_localstack ? "test" : null

  s3_use_path_style           = var.use_localstack
  skip_credentials_validation = var.use_localstack
  skip_metadata_api_check     = var.use_localstack
  skip_requesting_account_id  = var.use_localstack

  dynamic "endpoints" {
    for_each = var.use_localstack ? [var.localstack_endpoint] : []
    content {
      apigateway = endpoints.value
      dynamodb   = endpoints.value
      ec2        = endpoints.value
      elb        = endpoints.value
      elbv2      = endpoints.value
      iam        = endpoints.value
      route53    = endpoints.value
      s3         = endpoints.value
      sts        = endpoints.value
      ssm        = endpoints.value
    }
  }

  default_tags {
    tags = merge(var.tags, {
      Project     = var.project_name
      Environment = var.environment
      Region      = "failover"
      ManagedBy   = "terraform"
    })
  }
}

provider "aws" {
  alias  = "arc_control_plane"
  region = "us-west-2"

  access_key = var.use_localstack ? "test" : null
  secret_key = var.use_localstack ? "test" : null

  s3_use_path_style           = var.use_localstack
  skip_credentials_validation = var.use_localstack
  skip_metadata_api_check     = var.use_localstack
  skip_requesting_account_id  = var.use_localstack

  dynamic "endpoints" {
    for_each = var.use_localstack ? [var.localstack_endpoint] : []
    content {
      apigateway = endpoints.value
      dynamodb   = endpoints.value
      ec2        = endpoints.value
      elb        = endpoints.value
      elbv2      = endpoints.value
      iam        = endpoints.value
      route53    = endpoints.value
      s3         = endpoints.value
      sts        = endpoints.value
      ssm        = endpoints.value
    }
  }

  default_tags {
    tags = merge(var.tags, {
      Project   = var.project_name
      ManagedBy = "terraform"
      Purpose   = "arc-control-plane"
    })
  }
}
