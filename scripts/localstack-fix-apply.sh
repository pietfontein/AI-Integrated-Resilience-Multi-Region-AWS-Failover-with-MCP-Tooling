#!/usr/bin/env bash
# Re-apply after ELBv2 failure: removes broken ALB resources from state and applies direct-EC2 mode.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

ENDPOINT="${LOCALSTACK_ENDPOINT:-http://127.0.0.1:4566}"
if ! curl -sf "${ENDPOINT}/_localstack/health" >/dev/null 2>&1; then
  echo "ERROR: LocalStack not running. Run: bash scripts/localstack-up.sh" >&2
  exit 1
fi

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=af-south-1

terraform init -backend-config=config/backend.localstack.hcl -reconfigure

# Drop failed / obsolete ALB objects from state (safe if enable_alb=false)
for addr in \
  'module.primary_stack.aws_lb.app' \
  'module.failover_stack.aws_lb.app' \
  'module.primary_stack.aws_lb_target_group.app' \
  'module.failover_stack.aws_lb_target_group.app' \
  'module.primary_stack.aws_lb_listener.http[0]' \
  'module.failover_stack.aws_lb_listener.http[0]' \
  'module.primary_stack.aws_security_group.alb' \
  'module.failover_stack.aws_security_group.alb'; do
  terraform state rm "${addr}" 2>/dev/null || true
done

terraform apply -var-file=terraform.localstack.tfvars -auto-approve

echo ""
terraform output
echo ""
echo "Health check:"
echo "  curl \"\$(terraform output -raw primary_health_url)\""
