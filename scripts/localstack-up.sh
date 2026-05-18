#!/usr/bin/env bash
# Start LocalStack and bootstrap Terraform backend resources.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

export LOCALSTACK_ENDPOINT="${LOCALSTACK_ENDPOINT:-http://127.0.0.1:4566}"

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker is not running. Start Docker Desktop, wait until it is healthy, then retry." >&2
  exit 1
fi

bash scripts/docker-pull-localstack.sh

echo "Starting LocalStack at ${LOCALSTACK_ENDPOINT}..."
if ! docker compose up -d; then
  echo "ERROR: docker compose up failed." >&2
  echo "Try: Docker Desktop → Restart. Then: docker pull localstack/localstack:latest" >&2
  exit 1
fi

if ! docker compose ps --status running | grep -q localstack; then
  echo "ERROR: LocalStack container is not running. Check: docker compose logs localstack" >&2
  exit 1
fi

bash scripts/bootstrap-localstack.sh

echo ""
echo "LocalStack is up at ${LOCALSTACK_ENDPOINT}"
echo "  bash scripts/localstack-apply.sh"
