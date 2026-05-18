# LocalStack-only development — use with: scripts/localstack-apply.sh
use_localstack      = true
localstack_endpoint = "http://127.0.0.1:4566"
enable_alb          = false

environment         = "dev"
replica_count       = 1
bucket_name         = "resilience-state-local"
project_name        = "resilience-backbone"
ec2_instance_type   = "t3.micro"
acm_certificate_arn = ""

allowed_cidr_blocks = []

tags = {
  Owner = "local-dev"
}
