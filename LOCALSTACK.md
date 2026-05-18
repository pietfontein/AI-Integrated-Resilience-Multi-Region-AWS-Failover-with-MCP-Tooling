# LocalStack development

Run the full **regional VPC + EC2 API + S3 + Route 53 API** stack on LocalStack without real AWS charges. Route 53 ARC and cross-region S3 replication are **disabled** in this mode.

LocalStack Community validates the AWS APIs and Terraform graph, but it does not run the EC2 userdata web server at the generated public IP unless you add a separate EC2 executor. Treat `/health` URLs as real-AWS checks.

## Prerequisites

- Docker Desktop (running and healthy)
- AWS CLI
- Terraform >= 1.6

Use **127.0.0.1** (not `localhost`) on Windows to avoid IPv6 `[::1]` connection refused errors.

```ini
# ~/.aws/config
[default]
region = us-east-1
endpoint_url = http://127.0.0.1:4566
```

## Quick start

```bash
# 1. Start LocalStack + create state bucket / lock table
bash scripts/localstack-up.sh

# 2. Deploy infrastructure
bash scripts/localstack-apply.sh

# 3. Smoke check the LocalStack outputs
terraform output -raw primary_vpc_id
terraform output -raw failover_vpc_id
terraform output -raw local_dns_name
```

## Tear down

```bash
bash scripts/localstack-down.sh
```

## Troubleshooting

### `unable to get image` / `500 Internal Server Error` / `short read: unexpected EOF`

Docker never started LocalStack. Terraform and `curl` will fail until the container is up.

```bash
# 1. Restart Docker Desktop (tray icon → Restart)

# 2. Clean partial downloads and retry pull
docker system prune -f
bash scripts/docker-pull-localstack.sh

# 3. Start stack
bash scripts/localstack-up.sh
bash scripts/localstack-apply.sh
```

The apply script uses `terraform plan -refresh=false` by default because LocalStack Community does not fully round-trip EC2 metadata options during refresh. Set `LOCALSTACK_REFRESH=1` only when you specifically want to debug provider refresh behavior.

Verify: `curl http://127.0.0.1:4566/_localstack/health`

### `connectex: connection refused` on port 4566

LocalStack is not running. Do **not** run `localstack-apply.sh` until `localstack-up.sh` succeeds.

### EC2 `/health` URL is not reachable

This is expected in LocalStack Community. Terraform creates EC2 API objects, but the generated public IP does not run `userdata.sh` as a reachable VM.

Use the output smoke checks for LocalStack:

```bash
terraform output -raw primary_vpc_id
terraform output -raw failover_vpc_id
terraform output -raw local_dns_name
```

Use the `/health` curl after a real AWS apply, or after configuring a LocalStack EC2 executor.

## MCP server (LocalStack)

`describe_vpc` works against LocalStack EC2. ARC tools return a stub message.

1. Apply Terraform, then copy VPC IDs into `mcp_server/mcp_config.localstack.json`.
2. Point Claude at that config (or set `LOCALSTACK_DEV=1` and `AWS_ENDPOINT_URL=http://localhost:4566`).

```bash
cd mcp_server
pip install -r requirements.txt
export AWS_ENDPOINT_URL=http://localhost:4566
export LOCALSTACK_DEV=1
export PRIMARY_VPC_ID=$(terraform output -raw primary_vpc_id)
export FAILOVER_VPC_ID=$(terraform output -raw failover_vpc_id)
python server.py
```

## Switching to real AWS later

```bash
terraform init -reconfigure   # drops LocalStack backend config
# create real backend: AWS_BOOTSTRAP_PROFILE=resilience-aws bash scripts/bootstrap-backend.sh
terraform apply -var-file=terraform.tfvars   # use_localstack defaults to false
```

## What LocalStack covers vs skips

| Component | LocalStack |
|-----------|------------|
| VPC, subnets, NAT, SG | Yes |
| EC2 API objects | Yes |
| EC2 userdata `/health` server | No by default |
| ALB / ELBv2 | **No** (Community) — use `enable_alb = false` |
| S3 buckets | Yes |
| S3 cross-region replication | Skipped |
| Route 53 ARC failover | Skipped |
| Route 53 A → primary EC2 | Yes (`.local` zone) |
