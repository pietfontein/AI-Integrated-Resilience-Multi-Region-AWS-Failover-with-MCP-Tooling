# AI-Integrated Resilience: Multi-Region AWS Failover with MCP Tooling

> *Built for South Africa. Hardened for the world.*

---

## Why This Exists

South Africa has a problem that most AWS architecture tutorials ignore: **load shedding**.

When Eskom flips a switch, your "highly available" single-region application in `af-south-1` goes dark with it. The business loses revenue. The on-call engineer gets a 3am call. The post-mortem says "we need redundancy" — and six months later, nothing has changed.

This project builds the architecture that changes that. A **Warm Standby** system where Cape Town (`af-south-1`) is your primary engine and Ireland (`eu-west-1`) is your emergency generator — always warm, always ready, activated in seconds.

The twist: **an AI can manage and trigger the failover** via a custom MCP server. No runbook hunting. No CLI commands under pressure. Plain English.

---

## Architecture Overview

```
                    ┌─────────────────────────────────┐
                    │      Route 53 ARC Cluster        │
                    │   (Control Plane: us-west-2)     │
                    │                                  │
                    │  ┌──────────┐  ┌──────────────┐ │
                    │  │ Primary  │  │   Standby    │ │
                    │  │ Switch   │  │   Switch     │ │
                    │  │  [ON]    │  │   [OFF]      │ │
                    │  └────┬─────┘  └──────┬───────┘ │
                    │       │               │         │
                    │  Safety Rule: ≥1 must be ON      │
                    └───────┼───────────────┼─────────┘
                            │               │
              ┌─────────────▼──┐    ┌───────▼──────────────┐
              │  Cape Town     │    │  Ireland              │
              │  af-south-1    │    │  eu-west-1            │
              │  [PRIMARY]     │    │  [WARM STANDBY]       │
              │                │    │                       │
              │  VPC           │    │  VPC (clone)          │
              │  ALB           │    │  ALB                  │
              │  ASG (2 EC2)   │    │  ASG (2 EC2)          │
              │  S3 Bucket ────┼────┼─► S3 Replica          │
              └────────────────┘    └───────────────────────┘
                            ▲
                            │  AI queries status
                            │  AI triggers failover
                    ┌───────┴────────┐
                    │  MCP Server    │
                    │  (Python)      │
                    └───────┬────────┘
                            │
                    ┌───────▼────────┐
                    │  Claude / AI   │
                    │  "What is the  │
                    │  Cape Town     │
                    │  status?"      │
                    └────────────────┘
```

**Failover sequence (automated, ~30 seconds):**
1. ARC health check detects Cape Town routing control is `Off`
2. Route 53 stops resolving `api.domain` to the Cape Town ALB
3. Route 53 starts resolving to the Ireland ALB (already warm)
4. S3 replication ensures state assets are available in Ireland

---

## Project Structure

```
.
├── main.tf                    # Orchestrator — calls the regional module twice
├── variables.tf               # Hardened inputs with validation blocks
├── arc.tf                     # Route 53 ARC: circuit breakers and safety rules
├── outputs.tf                 # Surface ARNs for the MCP server
├── terraform.tfvars.example   # Config template (never commit the real file)
├── modules/
│   └── regional-stack/        # Reusable VPC + ALB + ASG module
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
├── mcp_server/
│   ├── server.py              # Python MCP server — the AI interface
│   ├── requirements.txt
│   └── .env.example           # Populated from terraform output
└── .github/
    └── workflows/
        └── ci.yml             # Terraform validate + tfsec + Infracost on PR
```

---

## Security Design Decisions

| Decision | Why |
|---|---|
| IMDSv2 enforced on all EC2 | Blocks SSRF-based metadata attacks (CVE class) |
| No SSH by default — SSM only | No open port 22, no key management surface |
| S3 public access blocked + KMS | State assets never accidentally public |
| `validation {}` on all variables | Fail closed — invalid input never reaches AWS |
| Safety rule: ≥1 region always ON | Prevents AI or automation causing a total blackout |
| IAM Least Privilege on all roles | Prowler won't flag you; auditors won't either |

---

## FinOps Notes

**Watch the data transfer line item.** This is where SA companies get surprised:

- `af-south-1` has **higher egress costs** than most regions
- S3 cross-region replication (Cape Town → Ireland) incurs per-GB transfer fees
- The standby ASG runs at `desired_capacity = replica_count` — size this intentionally
- Use `infracost breakdown` before every `terraform apply` (CI enforces this on PRs)

Approximate warm standby cost: the standby EC2 instances are the main cost driver. In `dev`, `t3.micro` keeps this minimal.

---

## Getting Started

### Prerequisites

- AWS CLI configured with a profile that has sufficient IAM permissions
- Terraform >= 1.6.0
- Python 3.11+
- `infracost` CLI (for cost validation)
- `prowler` (for security baseline)

### 1. Deploy the Infrastructure

```bash
# Clone the repo
git clone https://github.com/your-username/AI-Integrated-Resilience-Multi-Region-AWS-Failover-with-MCP-Tooling
cd AI-Integrated-Resilience-Multi-Region-AWS-Failover-with-MCP-Tooling

# Configure your inputs
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# Plan — generate the binary plan for cost and security scanning
terraform init
terraform plan -out tfplan.binary

# FinOps gate — review before you apply
infracost breakdown --path tfplan.binary --format table

# Security baseline — fail-fast on IAM issues
prowler aws -r af-south-1 -M json,html

# Apply after you've reviewed the above
terraform apply tfplan.binary
```

### 2. Wire the MCP Server

```bash
cd mcp_server

# Populate env from Terraform outputs
terraform output -json mcp_server_config | python3 -c "
import json, sys
config = json.load(sys.stdin)
for k, v in config.items():
    print(f'export {k}={v}')
" > .env.sh
source .env.sh

# Install and run
pip install -r requirements.txt
python server.py
```

### 3. Connect to Claude (or any MCP-compatible AI)

Add to your Claude Desktop `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "arc-failover-assistant": {
      "command": "python",
      "args": ["/path/to/mcp_server/server.py"],
      "env": {
        "ARC_CLUSTER_ARN": "arn:aws:...",
        "PRIMARY_REGION": "af-south-1",
        "STANDBY_REGION": "eu-west-1"
      }
    }
  }
}
```

Then ask Claude:

> *"What is the current readiness status of our Cape Town region?"*

> *"Describe the VPC in the primary region."*

> *"Trigger a failover from Cape Town to Ireland and confirm."*

---

## The Fail-Closed Test

This is the demo that matters in interviews:

```bash
# 1. Manually disable the primary routing control (simulates Cape Town outage)
aws route53-recovery-cluster update-routing-control-state \
  --routing-control-arn $(terraform output -raw arc_primary_routing_control_arn) \
  --routing-control-state Off \
  --endpoint-url https://af-south-1.route53-recovery-cluster.amazonaws.com/v1

# 2. Watch the AI detect it
# Ask Claude: "What is the regional readiness status?"
# Expected: alert_level=red, Ireland is now active

# 3. Fail back via the AI
# Ask Claude: "Trigger a failover in direction standby_to_primary with confirm=true"

# 4. Verify normal state restored
# Ask Claude: "Get regional readiness status"
# Expected: alert_level=green, Cape Town active
```

---

## CI/CD Pipeline

Every Pull Request automatically runs:

1. **`terraform fmt -check`** — enforces consistent formatting
2. **`terraform validate`** — catches syntax errors before merge
3. **`tfsec`** — security scan; fails the PR on HIGH severity findings
4. **Infracost** — posts a cost delta comment on the PR

---

## Learning Objectives (AWS SAA Alignment)

This project maps directly to SAA exam domains:

| SAA Domain | What You Built |
|---|---|
| Resilient Architectures | Warm Standby, ARC routing controls, safety rules |
| High-Performing Architectures | ALB + ASG, multi-AZ subnets |
| Secure Architectures | IMDSv2, SSM over SSH, S3 encryption, least privilege IAM |
| Cost-Optimised Architectures | STANDARD_IA for standby S3, bounded replica_count validation |

---

## License

MIT — use it, fork it, improve it. If it saves your app during load shedding, that's enough.
