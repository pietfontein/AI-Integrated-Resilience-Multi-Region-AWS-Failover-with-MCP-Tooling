#!/usr/bin/env bash
# One-time bootstrap for Terraform remote state on REAL AWS.
#
# For LocalStack dev, use: bash scripts/localstack-up.sh
#
# Requires a REAL AWS profile (not LocalStack). Your ~/.aws/config may point
# default at localhost:4566 — use a separate profile for this project:
#
#   aws configure --profile resilience-aws
#   AWS_BOOTSTRAP_PROFILE=resilience-aws bash scripts/bootstrap-backend.sh
#
set -euo pipefail

BUCKET="${TF_STATE_BUCKET:-tf-state-resilience-backbone}"
TABLE="${TF_LOCK_TABLE:-tf-state-lock}"
REGION="${TF_STATE_REGION:-af-south-1}"
PROFILE="${AWS_BOOTSTRAP_PROFILE:-}"
CREATE_DDB_LOCK_TABLE="${CREATE_DDB_LOCK_TABLE:-0}"

aws_cli() {
  if [[ -n "${PROFILE}" ]]; then
    aws --profile "${PROFILE}" "$@"
  else
    aws "$@"
  fi
}

endpoint_url() {
  if [[ -n "${PROFILE}" ]]; then
    aws configure get endpoint_url --profile "${PROFILE}" 2>/dev/null || true
  else
    aws configure get endpoint_url 2>/dev/null || true
  fi
}

EP="$(endpoint_url)"
if [[ "${EP}" == *"4566"* ]] || [[ "${EP}" == *"localhost"* ]]; then
  cat <<'EOF' >&2
ERROR: AWS CLI is configured for LocalStack (endpoint_url points to localhost:4566).

This bootstrap script creates real S3 + DynamoDB resources in AWS.

Fix — create a profile without endpoint_url, then re-run:

  aws configure --profile resilience-aws
  # Enter real Access Key, Secret Key, region af-south-1

  AWS_BOOTSTRAP_PROFILE=resilience-aws bash scripts/bootstrap-backend.sh

Or temporarily comment out "endpoint_url" in ~/.aws/config [default], run bootstrap,
then restore it for LocalStack work.
EOF
  exit 1
fi

if [[ -n "${AWS_ENDPOINT_URL:-}" ]] && [[ "${AWS_ENDPOINT_URL}" == *"4566"* ]]; then
  echo "ERROR: Unset AWS_ENDPOINT_URL (currently points at LocalStack) or use AWS_BOOTSTRAP_PROFILE." >&2
  exit 1
fi

echo "Using AWS profile: ${PROFILE:-default}"
echo "Creating S3 bucket: ${BUCKET} (${REGION})"

if aws_cli s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "Bucket already exists."
else
  aws_cli s3api create-bucket \
    --bucket "${BUCKET}" \
    --region "${REGION}" \
    --create-bucket-configuration "LocationConstraint=${REGION}"
fi

aws_cli s3api put-bucket-versioning \
  --bucket "${BUCKET}" \
  --versioning-configuration Status=Enabled

aws_cli s3api put-bucket-encryption \
  --bucket "${BUCKET}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

if [[ "${CREATE_DDB_LOCK_TABLE}" == "1" ]]; then
  echo "Creating legacy DynamoDB lock table: ${TABLE}"
  if aws_cli dynamodb describe-table --table-name "${TABLE}" --region "${REGION}" >/dev/null 2>&1; then
    echo "Table already exists."
  else
    aws_cli dynamodb create-table \
      --table-name "${TABLE}" \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region "${REGION}"
  fi
else
  echo "Skipping DynamoDB lock table; Terraform uses the S3 native lockfile backend."
fi

echo "Done. For Terraform, use the same profile:"
echo "  export AWS_PROFILE=${PROFILE:-default}"
echo "  cp config/backend.aws.example.hcl config/backend.aws.hcl"
echo "  terraform init -backend-config=config/backend.aws.hcl"
