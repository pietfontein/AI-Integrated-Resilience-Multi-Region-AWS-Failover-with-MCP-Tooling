#!/usr/bin/env bash
# Bootstrap S3 + DynamoDB on LocalStack for Terraform remote state.
set -euo pipefail

ENDPOINT="${LOCALSTACK_ENDPOINT:-http://127.0.0.1:4566}"
BUCKET="${TF_STATE_BUCKET:-tf-state-resilience-backbone}"
TABLE="${TF_LOCK_TABLE:-tf-state-lock}"
REGION="${TF_STATE_REGION:-af-south-1}"

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION="${REGION}"

AWS_CLI_MODE=""
if command -v aws >/dev/null 2>&1; then
  AWS_CLI_MODE="host"
elif docker ps --format '{{.Names}}' | grep -qx resilience-localstack \
  && docker exec resilience-localstack awslocal --version >/dev/null 2>&1; then
  AWS_CLI_MODE="container"
else
  echo "ERROR: AWS CLI not found on host and awslocal is not available in the LocalStack container." >&2
  echo "Install AWS CLI, or confirm the resilience-localstack container is running." >&2
  exit 1
fi

aws_cli() {
  if [[ "${AWS_CLI_MODE}" == "host" ]]; then
    aws --endpoint-url="${ENDPOINT}" "$@"
  else
    docker exec \
      -e AWS_ACCESS_KEY_ID=test \
      -e AWS_SECRET_ACCESS_KEY=test \
      -e AWS_DEFAULT_REGION="${REGION}" \
      resilience-localstack awslocal "$@"
  fi
}

echo "Waiting for LocalStack at ${ENDPOINT}..."
for i in $(seq 1 45); do
  if curl -sf "${ENDPOINT}/_localstack/health" >/dev/null 2>&1; then
    echo "LocalStack is ready."
    break
  fi
  if [[ "${i}" -eq 45 ]]; then
    echo "ERROR: LocalStack not reachable at ${ENDPOINT}" >&2
    echo "  docker compose ps" >&2
    echo "  docker compose logs localstack" >&2
    exit 1
  fi
  sleep 2
done

echo "Creating S3 state bucket: ${BUCKET}"
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

echo "Creating DynamoDB lock table: ${TABLE} (optional; Terraform may use S3 lockfile)"
if aws_cli dynamodb describe-table --table-name "${TABLE}" --region "${REGION}" >/dev/null 2>&1; then
  echo "Table already exists."
else
  aws_cli dynamodb create-table \
    --table-name "${TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}" 2>/dev/null || echo "DynamoDB table skipped (not required with use_lockfile)."
fi

echo "LocalStack backend ready."
