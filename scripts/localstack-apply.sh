#!/usr/bin/env bash
# Plan and apply the stack against LocalStack.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

ENDPOINT="${LOCALSTACK_ENDPOINT:-http://127.0.0.1:4566}"

if ! curl -sf "${ENDPOINT}/_localstack/health" >/dev/null 2>&1; then
  echo "ERROR: LocalStack is not running at ${ENDPOINT}" >&2
  echo "Run first: bash scripts/localstack-up.sh" >&2
  exit 1
fi

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=af-south-1

terraform init -backend-config=config/backend.localstack.hcl -reconfigure

PLAN_ARGS=(-var-file=terraform.localstack.tfvars -out=tfplan.localstack)
if [[ "${LOCALSTACK_REFRESH:-0}" != "1" ]]; then
  PLAN_ARGS=(-refresh=false "${PLAN_ARGS[@]}")
fi

terraform plan "${PLAN_ARGS[@]}"
terraform apply tfplan.localstack

echo ""
echo "=== LocalStack outputs ==="
terraform output

echo ""
echo "=== LocalStack smoke checks ==="
terraform output -raw primary_vpc_id >/dev/null
terraform output -raw failover_vpc_id >/dev/null
terraform output -raw local_dns_name >/dev/null
echo "Terraform outputs are available for both regional VPCs and local DNS."
echo "Note: LocalStack Community creates EC2 API objects but does not run userdata,"
echo "so the /health URL is a real-AWS check unless you add a LocalStack EC2 executor."
