# AI-Integrated Resilience: Multi-Region AWS Failover with MCP Tooling

> **Built for South African engineers who refuse to let load shedding win.**

[![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.6-purple?logo=terraform)](https://terraform.io)
[![AWS](https://img.shields.io/badge/AWS-Multi--Region-orange?logo=amazonaws)](https://aws.amazon.com)
[![Python](https://img.shields.io/badge/Python-3.11%2B-blue?logo=python)](https://python.org)
[![MCP](https://img.shields.io/badge/MCP-AI--Native-green)](https://modelcontextprotocol.io)

---

## Why This Exists

In South Africa, **"High Availability" is not a luxury — it is a survival tactic.**

When Cape Town has a grid event, your application goes down. You lose revenue. You lose users. You lose trust. The only defence is a warm standby that can absorb traffic before anyone notices the primary region has gone quiet.

This project builds that defence — and goes one step further: it makes the failover mechanism **AI-native**, so an on-call engineer can ask a plain-English question and get a plain-English answer about the state of the system.

---

## Architecture Overview

```
                        ┌─────────────────────────────────────────┐
                        │         Route 53 ARC Control Plane       │
                        │              (us-west-2)                  │
                        │                                           │
                        │  ┌─────────────┐   ┌─────────────────┐  │
                        │  │  Cluster    │   │  Safety Rule    │  │
                        │  │  (5 nodes)  │   │  ATLEAST(1) ON  │  │
                        │  └──────┬──────┘   └────────┬────────┘  │
                        │         │                    │            │
                        │  ┌──────▼──────┐   ┌────────▼────────┐  │
                        │  │  Primary    │   │  Failover       │  │
                        │  │  Switch     │   │  Switch         │  │
                        │  │  [ON/OFF]   │   │  [ON/OFF]       │  │
                        │  └──────┬──────┘   └────────┬────────┘  │
                        └─────────┼────────────────────┼───────────┘
                                  │                    │
              ┌───────────────────▼──┐    ┌────────────▼──────────────┐
              │  Cape Town PRIMARY    │    │  Ireland FAILOVER         │
              │  af-south-1          │    │  eu-west-1                │
              │                      │    │                            │
              │  ALB                 │    │  ALB                       │
              │  ├── Private Subnet  │    │  ├── Private Subnet        │
              │  │   ├── EC2 app-1   │    │  │   ├── EC2 app-1         │
              │  │   └── EC2 app-2   │    │  │   └── EC2 app-2         │
              │  └── S3 State Bucket │───▶│  └── S3 Replica (IA)      │
              │       (versioned)    │    │       (cross-region)       │
              └──────────────────────┘    └────────────────────────────┘
                         │                              │
                         └──────────┐  ┌───────────────┘
                                    ▼  ▼
                            Route 53 DNS Record
                         app.resilience-backbone.example.com
                         (Failover policy — ARC health checks)

              ┌─────────────────────────────────────────────────────┐
              │           AI-Native Management Layer                 │
              │                                                       │
              │  You → Claude → MCP Server → AWS API → ARC          │
              │                                                       │
              │  "What is the readiness status of Cape Town?"        │
              │  "Trigger failover to Ireland — grid event in CT"    │
              │  "Describe the VPC in the primary region"            │
              └─────────────────────────────────────────────────────┘
```

---

## Project Structure

```
.
├── variables.tf                    # Hardened inputs — validation blocks, fail-closed
├── providers.tf                    # Dual-region + ARC control plane providers
├── main.tf                         # Module orchestration + S3 cross-region replication
├── arc.tf                          # Route 53 ARC: cluster, controls, safety rule, DNS
├── outputs.tf                      # ARNs and endpoints for MCP server integration
├── terraform.tfvars.example        # Safe example — never commit real tfvars
├── .gitignore
│
├── modules/
│   └── regional-stack/
│       ├── main.tf                 # VPC, subnets, NAT, ALB, EC2, S3, IAM
│       ├── variables.tf            # Module inputs
│       ├── outputs.tf              # vpc_id, alb_dns_name, bucket ARNs
│       └── userdata.sh             # EC2 bootstrap — health endpoint on :8080
│
└── mcp_server/
    ├── server.py                   # MCP server exposing ARC operations as AI tools
    ├── requirements.txt
    └── mcp_config.json             # Claude Desktop / Claude Code integration config
```

---

## The Security Layer

This project applies a **defence-in-depth** model. Every resource is hardened:

| Control | Implementation |
|---|---|
| Input validation | `validation {}` blocks on all Terraform variables — fail-closed |
| IMDSv2 enforced | `http_tokens = "required"` — IMDSv1 disabled on all EC2 |
| Encrypted storage | S3: `aws:kms` SSE. EC2 root volumes: `encrypted = true` |
| No public IPs | Instances in private subnets only. ALB is the only public endpoint |
| Least-privilege IAM | EC2 role: SSM only. S3 replication role: scoped to specific buckets |
| No bastion hosts | SSM Session Manager for shell access — no SSH keys in production |
| ALB header sanitisation | `drop_invalid_header_fields = true` |
| Deletion protection | ALB has `enable_deletion_protection = true` in `prod` |
| S3 public access blocked | All four public access block settings enabled |
| ARC safety rule | `ATLEAST(1)` constraint prevents both regions going dark simultaneously |

### Pre-Flight Security Check

Before `terraform apply`, run:

```bash
# 1. Generate the binary plan
terraform plan -out tfplan.binary

# 2. FinOps: check af-south-1 vs eu-west-1 data transfer costs
#    (This is where SA companies get surprised — cross-region replication fees)
infracost breakdown --path tfplan.binary --format table

# 3. Security baseline: IAM least-privilege audit
prowler aws -r af-south-1 -M json,html
```

---

## Deployment Guide

### Prerequisites

- Terraform >= 1.6
- AWS CLI configured with credentials for both regions
- Python 3.11+ (for MCP server)
- An S3 bucket + DynamoDB table for Terraform remote state (create once manually)

### Step 1 — Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

### Step 2 — Initialise and Validate

```bash
terraform init
terraform validate   # Catches syntax errors before any AWS call
terraform fmt -recursive
```

### Step 3 — Cost and Security Review

```bash
terraform plan -out tfplan.binary
infracost breakdown --path tfplan.binary --format table
```

### Step 4 — Deploy

```bash
terraform apply tfplan.binary
```

### Step 5 — Record Outputs

```bash
terraform output -json > outputs.json
# These ARNs feed directly into the MCP server config
```

### Step 6 — Configure the MCP Server

```bash
cd mcp_server
pip install -r requirements.txt

# Populate environment variables from terraform output
export ARC_CLUSTER_ARN=$(terraform output -raw arc_cluster_arn)
export PRIMARY_ROUTING_CONTROL_ARN=$(terraform output -raw primary_routing_control_arn)
export FAILOVER_ROUTING_CONTROL_ARN=$(terraform output -raw failover_routing_control_arn)
export PRIMARY_VPC_ID=$(terraform output -raw primary_vpc_id)
export FAILOVER_VPC_ID=$(terraform output -raw failover_vpc_id)

python server.py
```

### Step 7 — Connect to Claude

Copy `mcp_server/mcp_config.json` (with your ARNs filled in) to:
- **Claude Desktop**: `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Claude Code**: `.claude/mcp_config.json` in your project root

---

## The MCP Server — AI-Native Operations

The `mcp_server/server.py` exposes four tools that any MCP-compatible AI agent can call:

### `get_regional_readiness`
> *"What is the current readiness status of Cape Town?"*

Queries both routing controls and returns:
```json
{
  "summary": "NOMINAL — Cape Town (af-south-1) is active. Ireland is on warm standby.",
  "controls": {
    "primary_cape_town":  { "status": "ENABLED", ... },
    "failover_ireland":   { "status": "DISABLED", ... }
  }
}
```

### `trigger_failover`
> *"Trigger failover to Ireland — we have a grid event in Cape Town."*

Atomically flips both routing controls. The ARC safety rule guarantees exactly one region stays active. Requires an audit-trail reason string.

### `describe_vpc`
> *"Describe the infrastructure in the primary region."*

Returns the VPC CIDR, all subnets with AZ mapping, and every running EC2 instance — structured for incident triage.

### `get_cluster_readiness_summary`
> *"Is the ARC control plane itself healthy?"*

Checks the 5-node ARC cluster. If this fails, the circuit breaker itself is impaired.

---

## The Fail-Closed Test (Chaos Engineering)

Verify the system before you need it:

```bash
# 1. Confirm Cape Town is active
#    → Ask Claude: "What is the readiness status?"

# 2. Break the primary — simulate a grid event
aws ec2 stop-instances --instance-ids $(terraform output -json primary_instance_ids | jq -r '.[]') \
  --region af-south-1

# 3. Watch the ALB health checks fail (~30s)

# 4. Trigger failover via MCP
#    → Ask Claude: "Trigger failover to Ireland. Reason: load shedding stage 6 event in Cape Town."

# 5. Verify traffic is now flowing through Ireland
curl https://app.resilience-backbone.example.com/health
# → {"status": "healthy", "region": "failover", ...}

# 6. Fail back when Cape Town recovers
#    → Ask Claude: "Trigger failover to cape_town. Reason: primary region restored, failing back."
```

---

## FinOps Notes — The Africa Tax

> *"This is where SA companies get ruthlessly surprised."*

Running dual-region infrastructure from Cape Town carries specific cost implications:

| Cost Driver | Details |
|---|---|
| `af-south-1` compute | ~15–20% more expensive than `eu-west-1` per instance-hour |
| Cross-region data transfer | S3 replication from CT → Ireland: ~$0.09/GB. Budget this. |
| NAT Gateway | One per region. ~$0.045/hour + $0.045/GB processed. |
| ARC cluster | No additional charge — ARC itself is free; you pay for Route 53 health checks. |
| Warm standby vs active-active | This architecture runs `replica_count` instances in Ireland 24/7. Consider scaling to 1 replica in failover and auto-scaling on promotion. |

---

## AWS SAA-C03 Alignment

This project is a practical study companion for the AWS Solutions Architect Associate exam. It directly implements:

- **Route 53** — Failover routing policy, health checks
- **Route 53 ARC** — Routing controls, safety rules, cluster architecture
- **VPC design** — Public/private subnet split, NAT Gateway, Security Groups, NACLs
- **EC2** — IMDSv2, encrypted EBS, IAM instance profiles
- **S3** — Versioning, cross-region replication, KMS encryption, public access blocks
- **IAM** — Least privilege, service-linked roles, trust policies
- **ALB** — Target groups, health checks, deletion protection

---

## Licence

MIT — use it, learn from it, build on it.

---

*Built in South Africa. Designed to survive it.*
