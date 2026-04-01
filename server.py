#!/usr/bin/env python3
"""
mcp_server/server.py — Route 53 ARC Failover Assistant
=======================================================
An MCP (Model Context Protocol) server that exposes AWS Route 53 Application
Recovery Controller operations as AI-callable tools.

An AI agent can ask:
  "What is the readiness status of Cape Town?"
  "Trigger failover to Ireland."
  "Describe the VPC in the primary region."

Usage:
  python server.py

Requirements:
  pip install mcp boto3 pydantic
"""

import json
import logging
import os
import sys
from typing import Any

import boto3
from botocore.exceptions import ClientError, NoCredentialsError
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import TextContent, Tool

# ── Logging ────────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("arc-mcp-server")

# ── Configuration (override via environment variables) ─────────────────────────
CONFIG = {
    "primary_region":              os.environ.get("PRIMARY_REGION", "af-south-1"),
    "failover_region":             os.environ.get("FAILOVER_REGION", "eu-west-1"),
    "arc_control_plane_region":    "us-west-2",  # ARC is always in us-west-2
    "cluster_arn":                 os.environ.get("ARC_CLUSTER_ARN", ""),
    "primary_routing_control_arn": os.environ.get("PRIMARY_ROUTING_CONTROL_ARN", ""),
    "failover_routing_control_arn":os.environ.get("FAILOVER_ROUTING_CONTROL_ARN", ""),
    "primary_vpc_id":              os.environ.get("PRIMARY_VPC_ID", ""),
    "failover_vpc_id":             os.environ.get("FAILOVER_VPC_ID", ""),
}

# ── AWS Client Factory ─────────────────────────────────────────────────────────
def get_client(service: str, region: str):
    """
    Returns a boto3 client. Credentials are sourced from the standard chain:
    Instance Profile → ENV vars → ~/.aws/credentials
    Never hardcode credentials — fail loudly if none are found.
    """
    try:
        return boto3.client(service, region_name=region)
    except NoCredentialsError:
        log.error("No AWS credentials found. Configure via IAM role or environment.")
        raise


# ── Tool Implementations ────────────────────────────────────────────────────────

def get_regional_readiness() -> dict[str, Any]:
    """
    Queries both routing controls and returns a plain-English readiness status.
    This is the "What is the health of Cape Town?" tool.
    """
    client = get_client("route53-recovery-control-config", CONFIG["arc_control_plane_region"])

    results = {}
    controls = {
        "primary_cape_town":  CONFIG["primary_routing_control_arn"],
        "failover_ireland":   CONFIG["failover_routing_control_arn"],
    }

    for label, arn in controls.items():
        if not arn:
            results[label] = {"status": "UNKNOWN", "reason": "ARN not configured"}
            continue
        try:
            resp = client.describe_routing_control(RoutingControlArn=arn)
            rc   = resp["RoutingControl"]
            results[label] = {
                "name":   rc["Name"],
                "status": rc["Status"],  # "ENABLED" = traffic ON, "DISABLED" = traffic OFF
                "arn":    arn,
            }
        except ClientError as e:
            results[label] = {"status": "ERROR", "reason": str(e)}

    # Derive a plain-English summary
    primary_on  = results.get("primary_cape_town", {}).get("status") == "ENABLED"
    failover_on = results.get("failover_ireland", {}).get("status") == "ENABLED"

    if primary_on and not failover_on:
        summary = "NOMINAL — Cape Town (af-south-1) is active. Ireland is on warm standby."
    elif failover_on and not primary_on:
        summary = "FAILOVER ACTIVE — Ireland (eu-west-1) is serving traffic. Cape Town is offline."
    elif primary_on and failover_on:
        summary = "WARNING — Both regions show ENABLED. Safety rule may be preventing this state."
    else:
        summary = "CRITICAL — Both regions are DISABLED. No region is serving traffic."

    return {"summary": summary, "controls": results}


def trigger_failover(target_region: str, reason: str) -> dict[str, Any]:
    """
    Flips the ARC routing controls to redirect traffic.
    Requires explicit reason string for audit trail.

    WARNING: This is a production-impacting action. The safety rule in ARC
    prevents both regions from being off simultaneously.
    """
    if target_region not in ("ireland", "cape_town"):
        return {"success": False, "error": "target_region must be 'ireland' or 'cape_town'"}

    if not reason or len(reason.strip()) < 10:
        return {"success": False, "error": "Reason must be at least 10 characters for audit compliance."}

    # ARC state changes use a different endpoint: route53-recovery-cluster
    # This endpoint queries the 5 ARC cluster endpoints for consensus writes
    cluster_endpoints = _get_cluster_endpoints()
    if not cluster_endpoints:
        return {"success": False, "error": "Could not retrieve ARC cluster endpoints."}

    routing_updates = []
    if target_region == "ireland":
        routing_updates = [
            (CONFIG["primary_routing_control_arn"],  "Off"),
            (CONFIG["failover_routing_control_arn"], "On"),
        ]
    else:  # cape_town
        routing_updates = [
            (CONFIG["primary_routing_control_arn"],  "On"),
            (CONFIG["failover_routing_control_arn"], "Off"),
        ]

    # Write routing control states atomically via the cluster endpoint
    client = boto3.client(
        "route53-recovery-cluster",
        region_name=CONFIG["arc_control_plane_region"],
        endpoint_url=cluster_endpoints[0],  # Use first endpoint; retry on others if needed
    )

    try:
        client.update_routing_control_states(
            UpdateRoutingControlStateEntries=[
                {"RoutingControlArn": arn, "RoutingControlState": state}
                for arn, state in routing_updates
            ]
        )
        log.info("Failover triggered to %s. Reason: %s", target_region, reason)
        return {
            "success":       True,
            "active_region": target_region,
            "reason":        reason,
            "message":       f"Traffic redirected to {target_region}. DNS propagation: ~30-60s.",
        }
    except ClientError as e:
        return {"success": False, "error": str(e)}


def describe_vpc(region_label: str) -> dict[str, Any]:
    """
    Returns a structured description of the VPC in the specified region.
    This is the "Describe the VPC you just built" tool — great for interviews.
    """
    region_map = {
        "primary":  (CONFIG["primary_region"],  CONFIG["primary_vpc_id"]),
        "failover": (CONFIG["failover_region"], CONFIG["failover_vpc_id"]),
    }

    if region_label not in region_map:
        return {"error": "region_label must be 'primary' or 'failover'"}

    region, vpc_id = region_map[region_label]

    if not vpc_id:
        return {"error": f"VPC ID for {region_label} not configured. Set {region_label.upper()}_VPC_ID env var."}

    ec2 = get_client("ec2", region)

    try:
        # VPC details
        vpc_resp = ec2.describe_vpcs(VpcIds=[vpc_id])
        vpc      = vpc_resp["Vpcs"][0]

        # Subnets
        subnet_resp = ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])
        subnets = [
            {
                "id":                s["SubnetId"],
                "cidr":              s["CidrBlock"],
                "az":                s["AvailabilityZone"],
                "type":              "public" if s.get("MapPublicIpOnLaunch") else "private",
                "available_ips":     s["AvailableIpAddressCount"],
            }
            for s in subnet_resp["Subnets"]
        ]

        # Running instances in this VPC
        instance_resp = ec2.describe_instances(
            Filters=[
                {"Name": "vpc-id",       "Values": [vpc_id]},
                {"Name": "instance-state-name", "Values": ["running", "stopped"]},
            ]
        )
        instances = []
        for reservation in instance_resp["Reservations"]:
            for inst in reservation["Instances"]:
                name = next(
                    (t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"),
                    "unnamed"
                )
                instances.append({
                    "id":            inst["InstanceId"],
                    "name":          name,
                    "type":          inst["InstanceType"],
                    "state":         inst["State"]["Name"],
                    "private_ip":    inst.get("PrivateIpAddress", "N/A"),
                    "az":            inst["Placement"]["AvailabilityZone"],
                })

        return {
            "region":       region,
            "region_label": region_label,
            "vpc": {
                "id":    vpc["VpcId"],
                "cidr":  vpc["CidrBlock"],
                "state": vpc["State"],
                "tags":  {t["Key"]: t["Value"] for t in vpc.get("Tags", [])},
            },
            "subnets":   subnets,
            "instances": instances,
            "summary": (
                f"{region_label.upper()} VPC in {region}: "
                f"CIDR {vpc['CidrBlock']}, "
                f"{len(subnets)} subnets, "
                f"{len(instances)} instances."
            ),
        }

    except ClientError as e:
        return {"error": str(e)}


def get_cluster_readiness_summary() -> dict[str, Any]:
    """
    Returns the ARC cluster's endpoint health — are the control plane nodes reachable?
    """
    client = get_client("route53-recovery-control-config", CONFIG["arc_control_plane_region"])
    try:
        resp    = client.describe_cluster(ClusterArn=CONFIG["cluster_arn"])
        cluster = resp["Cluster"]
        return {
            "name":      cluster["Name"],
            "status":    cluster["Status"],
            "endpoints": cluster.get("ClusterEndpoints", []),
        }
    except ClientError as e:
        return {"error": str(e)}


def _get_cluster_endpoints() -> list[str]:
    summary = get_cluster_readiness_summary()
    return [ep["Endpoint"] for ep in summary.get("endpoints", [])]


# ── MCP Server Setup ───────────────────────────────────────────────────────────

app = Server("arc-failover-assistant")

TOOLS = [
    Tool(
        name="get_regional_readiness",
        description=(
            "Query the current readiness status of both AWS regions. "
            "Returns which region (Cape Town or Ireland) is actively serving traffic "
            "and a plain-English summary. Use this first before any failover decision."
        ),
        inputSchema={"type": "object", "properties": {}, "required": []},
    ),
    Tool(
        name="trigger_failover",
        description=(
            "Redirect all application traffic to the specified region by flipping "
            "the Route 53 ARC routing controls. "
            "Use 'ireland' to fail over, 'cape_town' to fail back. "
            "A reason is mandatory for audit compliance."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "target_region": {
                    "type":        "string",
                    "enum":        ["ireland", "cape_town"],
                    "description": "The region to activate.",
                },
                "reason": {
                    "type":        "string",
                    "minLength":   10,
                    "description": "Reason for the failover (min 10 chars, written to audit log).",
                },
            },
            "required": ["target_region", "reason"],
        },
    ),
    Tool(
        name="describe_vpc",
        description=(
            "Return a detailed description of the VPC, subnets, and running EC2 instances "
            "in the specified region. Great for operational visibility and incident triage."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "region_label": {
                    "type":        "string",
                    "enum":        ["primary", "failover"],
                    "description": "'primary' = Cape Town (af-south-1), 'failover' = Ireland (eu-west-1).",
                }
            },
            "required": ["region_label"],
        },
    ),
    Tool(
        name="get_cluster_readiness_summary",
        description=(
            "Check the health of the ARC control plane cluster itself. "
            "If this returns errors, the failover mechanism may be compromised."
        ),
        inputSchema={"type": "object", "properties": {}, "required": []},
    ),
]


@app.list_tools()
async def list_tools():
    return TOOLS


@app.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    log.info("Tool called: %s | args: %s", name, arguments)

    try:
        if name == "get_regional_readiness":
            result = get_regional_readiness()

        elif name == "trigger_failover":
            result = trigger_failover(
                target_region=arguments["target_region"],
                reason=arguments["reason"],
            )

        elif name == "describe_vpc":
            result = describe_vpc(region_label=arguments["region_label"])

        elif name == "get_cluster_readiness_summary":
            result = get_cluster_readiness_summary()

        else:
            result = {"error": f"Unknown tool: {name}"}

    except Exception as e:
        log.exception("Unhandled error in tool %s", name)
        result = {"error": f"Internal error: {str(e)}"}

    return [TextContent(type="text", text=json.dumps(result, indent=2))]


# ── Entrypoint ─────────────────────────────────────────────────────────────────

async def main():
    log.info("ARC Failover MCP Server starting...")
    log.info("Primary region:  %s", CONFIG["primary_region"])
    log.info("Failover region: %s", CONFIG["failover_region"])

    async with stdio_server() as (read_stream, write_stream):
        await app.run(read_stream, write_stream, app.create_initialization_options())


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
