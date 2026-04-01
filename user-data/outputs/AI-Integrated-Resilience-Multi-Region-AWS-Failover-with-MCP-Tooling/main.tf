################################################################################
# main.tf — Regional Stack Orchestrator
# Calls the same reusable module for both regions.
# DRY principle: one module definition, two instantiations.
################################################################################

# ── Primary Regional Stack: Cape Town (af-south-1) ───────────────────────────
module "primary_stack" {
  source = "./modules/regional-stack"

  providers = {
    aws = aws.cape_town
  }

  project_name      = var.project_name
  environment       = var.environment
  region_label      = "primary"
  region_name       = var.primary_region
  replica_count     = var.replica_count
  instance_type     = var.ec2_instance_type
  bucket_name       = "${var.bucket_name}-primary"
  allowed_cidr_blocks = var.allowed_cidr_blocks

  # VPC CIDR split: primary owns 10.0.0.0/16, failover owns 10.1.0.0/16
  # Non-overlapping so we can peer them later for replication traffic
  vpc_cidr           = "10.0.0.0/16"
  public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]

  tags = var.tags
}

# ── Failover Regional Stack: Ireland (eu-west-1) ─────────────────────────────
module "failover_stack" {
  source = "./modules/regional-stack"

  providers = {
    aws = aws.ireland
  }

  project_name      = var.project_name
  environment       = var.environment
  region_label      = "failover"
  region_name       = var.failover_region
  replica_count     = var.replica_count
  instance_type     = var.ec2_instance_type
  bucket_name       = "${var.bucket_name}-failover"
  allowed_cidr_blocks = var.allowed_cidr_blocks

  vpc_cidr           = "10.1.0.0/16"
  public_subnet_cidrs  = ["10.1.1.0/24", "10.1.2.0/24"]
  private_subnet_cidrs = ["10.1.10.0/24", "10.1.11.0/24"]

  tags = var.tags
}

# ── S3 Cross-Region Replication: Cape Town → Ireland ─────────────────────────
# State assets are continuously replicated so failover has warm data on day 0.
resource "aws_s3_bucket_replication_configuration" "state_replication" {
  provider = aws.cape_town
  bucket   = module.primary_stack.state_bucket_id
  role     = aws_iam_role.replication_role.arn

  rule {
    id     = "replicate-all-to-ireland"
    status = "Enabled"

    filter {} # Replicate all objects — no prefix filter

    destination {
      bucket        = module.failover_stack.state_bucket_arn
      storage_class = "STANDARD_IA" # Cost optimisation: IA for warm standby
    }

    delete_marker_replication {
      status = "Enabled"
    }
  }

  depends_on = [
    module.primary_stack,
    module.failover_stack,
  ]
}

# ── IAM Role for S3 Replication (Least Privilege) ────────────────────────────
resource "aws_iam_role" "replication_role" {
  provider = aws.cape_town
  name     = "${var.project_name}-s3-replication-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "replication_policy" {
  provider = aws.cape_town
  name     = "s3-replication-least-privilege"
  role     = aws_iam_role.replication_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ]
        Resource = module.primary_stack.state_bucket_arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Resource = "${module.primary_stack.state_bucket_arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ]
        Resource = "${module.failover_stack.state_bucket_arn}/*"
      }
    ]
  })
}
