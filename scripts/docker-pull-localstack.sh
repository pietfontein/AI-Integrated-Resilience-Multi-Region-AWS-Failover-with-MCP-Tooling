#!/usr/bin/env bash
# Retry LocalStack image pull (common fix for "short read" / 500 errors on Windows).
set -euo pipefail

IMAGE="${LOCALSTACK_IMAGE:-localstack/localstack:4.4.0}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Start Docker Desktop first." >&2
  exit 1
fi

for attempt in $(seq 1 "${MAX_ATTEMPTS}"); do
  echo "Pulling ${IMAGE} (attempt ${attempt}/${MAX_ATTEMPTS})..."
  if docker pull "${IMAGE}"; then
    echo "Pull succeeded."
    exit 0
  fi
  echo "Pull failed; waiting 10s before retry..."
  sleep 10
done

echo "ERROR: Could not pull ${IMAGE} after ${MAX_ATTEMPTS} attempts." >&2
echo "Try:" >&2
echo "  1. Docker Desktop → Restart" >&2
echo "  2. Settings → Resources → increase disk image size if low on space" >&2
echo "  3. docker system prune -f   (removes broken partial layers)" >&2
echo "  4. Re-run: bash scripts/docker-pull-localstack.sh" >&2
exit 1
