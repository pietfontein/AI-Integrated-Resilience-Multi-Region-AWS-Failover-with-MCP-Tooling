#!/usr/bin/env python3
"""
mcp_server/server.py — The Failover Assistant MCP Server

Connects an AI to your Route 53 ARC cluster and regional VPCs.
An AI can now ask: "What is the readiness status of Cape Town?"
...and trigger a controlled failover via a plain English command.

Usage:
    pip install -r requirements.txt
    export AWS_PROFILE=your-profile
    export ARC_CLUSTER_ARN=arn:aws:route53-recovery-control::...
    export PRIMARY_REGION=af-south-1
    export STANDBY_REGION=eu-west-1
    python server.py
"""

import json
import logging
import os
import sys
from datetime import datetime, timezone
from typing import Any

import boto3
from botocore.exceptions import ClientError
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import (
    CallToolResult,
    TextContent,
    Tool,
)

# ── Logging ────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("arc-mcp-server")

# ── Config from environment (populated by Terraform outputs) ───────────
CONFIG = {
    "arc_cluster_arn": os.environ.get("ARC_CLUSTER_ARN", ""),
    "primary_routing_control_arn": os.environ.get("ARC_PRIMARY_ROUTING_CONTROL_ARN", ""),
    "standby_routing_control_arn": os.environ.get("ARC_STANDBY_ROUTING_CONTROL_ARN", ""),
    "primary_region": os.environ.get("PRIMARY_REGION", "af-south-1"),
    "standby_region": os.environ.get("STANDBY_REGION", "eu-west-1"),
    "primary_vpc_id": os.environ.get("PRIMARY_VPC_ID", ""),
    "standby_vpc_id": os.environ.get("STANDBY_VPC_ID", ""),
}

# ARC data plane endpoints — required for routing control state changes
# These are fixed AWS endpoints, not region-specific
ARC_DATA_PLANE_ENDPOINTS = [
    "https://af-south-1.route53-recovery-cluster.amazonaws.com/v1",
    "https://eu-west-1.route53-recovery-cluster.amazonaws.com/v1",
    "https://us-west-2.route53-recovery-cluster.amazonaws.com/v1",
]


def get_arc_client():
    """ARC control plane — always us-west-2."""
    return boto3.client("route53-recovery-control-config", region_name="us-west-2")


def get_arc_cluster_client(endpoint: str):
    """ARC data plane — for reading/writing routing control state."""
    return boto3.client(
        "route53-recovery-cluster",
        endpoint_url=endpoint,
        region_name="us-west-2",
    )


def get_ec2_client(region: str):
    return boto3.client("ec2", region_name=region)


def get_routing_control_state(routing_control_arn: str) -> dict:
    """
    Query the routing control state across all ARC data plane endpoints.
    ARC uses a quorum model — we try each endpoint until one responds.
    """
    for endpoint in ARC_DATA_PLANE_ENDPOINTS:
        try:
            client = get_arc_cluster_client(endpoint)
            response = client.get_routing_control_state(
                RoutingControlArn=routing_control_arn
            )
            return {
                "state": response["RoutingControlState"],
                "arn": routing_control_arn,
                "endpoint_used": endpoint,
            }
        except ClientError as e:
            log.warning(f"Endpoint {endpoint} failed: {e.response['Error']['Code']}")
            continue
    raise RuntimeError("All ARC data plane endpoints failed — check network and IAM.")


def set_routing_control_state(routing_control_arn: str, target_state: str) -> dict:
    """
    Flip a routing control switch. This IS the failover action.
    target_state: 'On' or 'Off'
    """
    if target_state not in ("On", "Off"):
        raise ValueError(f"Invalid state '{target_state}'. Must be 'On' or 'Off'.")

    for endpoint in ARC_DATA_PLANE_ENDPOINTS:
        try:
            client = get_arc_cluster_client(endpoint)
            client.update_routing_control_state(
                RoutingControlArn=routing_control_arn,
                RoutingControlState=target_state,
            )
            return {
                "success": True,
                "routing_control_arn": routing_control_arn,
                "new_state": target_state,
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "endpoint_used": endpoint,
            }
        except ClientError as e:
            code = e.response["Error"]["Code"]
            if code == "ConflictException":
                return {"success": False, "reason": "Safety rule blocked the change — at least one region must remain active."}
            log.warning(f"Endpoint {endpoint} failed: {code}")
            continue
    raise RuntimeError("All ARC data plane endpoints failed during state update.")


def describe_vpc(region: str, vpc_id: str) -> dict:
    """Fetch VPC details + attached subnets and security groups."""
    ec2 = get_ec2_client(region)

    vpc_resp = ec2.describe_vpcs(VpcIds=[vpc_id])
    vpc = vpc_resp["Vpcs"][0]

    subnet_resp = ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])
    subnets = [
        {
            "id": s["SubnetId"],
            "cidr": s["CidrBlock"],
            "az": s["AvailabilityZone"],
            "public": s["MapPublicIpOnLaunch"],
            "available_ips": s["AvailableIpAddressCount"],
        }
        for s in subnet_resp["Subnets"]
    ]

    sg_resp = ec2.describe_security_groups(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])
    security_groups = [
        {
            "id": sg["GroupId"],
            "name": sg["GroupName"],
            "description": sg["Description"],
            "inbound_rules": len(sg["IpPermissions"]),
            "outbound_rules": len(sg["IpPermissionsEgress"]),
        }
        for sg in sg_resp["SecurityGroups"]
    ]

    return {
        "vpc_id": vpc["VpcId"],
        "cidr_block": vpc["CidrBlock"],
        "state": vpc["State"],
        "region": region,
        "dns_support": vpc.get("EnableDnsSupport", {}).get("Value", False),
        "dns_hostnames": vpc.get("EnableDnsHostnames", {}).get("Value", False),
        "subnets": subnets,
        "security_groups": security_groups,
        "tags": {t["Key"]: t["Value"] for t in vpc.get("Tags", [])},
    }


# ── MCP Server Definition ──────────────────────────────────────────────
app = Server("arc-failover-assistant")


@app.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="get_regional_readiness",
            description=(
                "Query the live readiness status of both AWS regions (Cape Town primary "
                "and Ireland standby). Returns whether each region is actively receiving "
                "traffic, based on their ARC routing control states."
            ),
            inputSchema={
                "type": "object",
                "properties": {},
                "required": [],
            },
        ),
        Tool(
            name="trigger_failover",
            description=(
                "Execute a controlled regional failover by flipping ARC routing controls. "
                "This promotes Ireland (standby) to active and demotes Cape Town (primary). "
                "A safety rule prevents total blackout — at least one region stays active. "
                "Use this during a Cape Town outage or for a planned maintenance failover test."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "direction": {
                        "type": "string",
                        "enum": ["primary_to_standby", "standby_to_primary"],
                        "description": (
                            "'primary_to_standby': failover from Cape Town to Ireland. "
                            "'standby_to_primary': fail back to Cape Town after recovery."
                        ),
                    },
                    "confirm": {
                        "type": "boolean",
                        "description": "Must be true. Acts as an intent confirmation gate.",
                    },
                },
                "required": ["direction", "confirm"],
            },
        ),
        Tool(
            name="describe_vpc",
            description=(
                "Fetch a detailed plain-English description of a regional VPC — "
                "including subnets, AZs, security groups, and CIDR blocks. "
                "Useful for architecture review or during an incident investigation."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "region": {
                        "type": "string",
                        "enum": ["primary", "standby"],
                        "description": "Which region's VPC to describe.",
                    }
                },
                "required": ["region"],
            },
        ),
        Tool(
            name="get_arc_cluster_info",
            description=(
                "Return metadata about the ARC control cluster and its control panel, "
                "including all routing controls and their current ARNs."
            ),
            inputSchema={
                "type": "object",
                "properties": {},
                "required": [],
            },
        ),
    ]


@app.call_tool()
async def call_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:
    try:
        if name == "get_regional_readiness":
            result = await _get_regional_readiness()
        elif name == "trigger_failover":
            result = await _trigger_failover(arguments)
        elif name == "describe_vpc":
            result = await _describe_vpc(arguments)
        elif name == "get_arc_cluster_info":
            result = await _get_arc_cluster_info()
        else:
            result = {"error": f"Unknown tool: {name}"}

        return [TextContent(type="text", text=json.dumps(result, indent=2))]

    except Exception as e:
        log.exception(f"Tool '{name}' failed")
        return [TextContent(type="text", text=json.dumps({"error": str(e)}, indent=2))]


async def _get_regional_readiness() -> dict:
    primary_state = get_routing_control_state(CONFIG["primary_routing_control_arn"])
    standby_state = get_routing_control_state(CONFIG["standby_routing_control_arn"])

    primary_active = primary_state["state"] == "On"
    standby_active = standby_state["state"] == "On"

    if primary_active and not standby_active:
        summary = "Normal operation. Cape Town (primary) is active. Ireland is on warm standby."
        alert_level = "green"
    elif standby_active and not primary_active:
        summary = "FAILOVER ACTIVE. Traffic is routing to Ireland (standby). Cape Town is offline."
        alert_level = "red"
    elif primary_active and standby_active:
        summary = "Both regions active — split-brain or transition state. Investigate immediately."
        alert_level = "amber"
    else:
        summary = "CRITICAL: Both regions are OFF. Safety rule may have been overridden."
        alert_level = "critical"

    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "alert_level": alert_level,
        "summary": summary,
        "regions": {
            "primary": {
                "name": "Cape Town",
                "aws_region": CONFIG["primary_region"],
                "routing_control_state": primary_state["state"],
                "receiving_traffic": primary_active,
            },
            "standby": {
                "name": "Ireland",
                "aws_region": CONFIG["standby_region"],
                "routing_control_state": standby_state["state"],
                "receiving_traffic": standby_active,
            },
        },
    }


async def _trigger_failover(args: dict) -> dict:
    if not args.get("confirm"):
        return {
            "success": False,
            "reason": "Failover not executed — 'confirm' must be true. This is an intent gate.",
        }

    direction = args["direction"]
    log.info(f"Failover triggered: direction={direction}")

    if direction == "primary_to_standby":
        # 1. Promote standby FIRST (safety rule requires ≥1 active at all times)
        promote = set_routing_control_state(CONFIG["standby_routing_control_arn"], "On")
        if not promote["success"]:
            return promote
        # 2. Then demote primary
        demote = set_routing_control_state(CONFIG["primary_routing_control_arn"], "Off")
        action = "Cape Town → Ireland"
        next_step = "Monitor Ireland ALB health checks. Execute 'get_regional_readiness' to confirm."

    elif direction == "standby_to_primary":
        # 1. Promote primary FIRST
        promote = set_routing_control_state(CONFIG["primary_routing_control_arn"], "On")
        if not promote["success"]:
            return promote
        # 2. Then demote standby
        demote = set_routing_control_state(CONFIG["standby_routing_control_arn"], "Off")
        action = "Ireland → Cape Town (fail back)"
        next_step = "Verify Cape Town stack is fully healthy before closing the incident."
    else:
        return {"success": False, "reason": f"Unknown direction: {direction}"}

    return {
        "success": True,
        "action": action,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "promote_result": promote,
        "demote_result": demote,
        "next_step": next_step,
    }


async def _describe_vpc(args: dict) -> dict:
    region_key = args["region"]
    if region_key == "primary":
        region = CONFIG["primary_region"]
        vpc_id = CONFIG["primary_vpc_id"]
        label = "Cape Town (Primary)"
    else:
        region = CONFIG["standby_region"]
        vpc_id = CONFIG["standby_vpc_id"]
        label = "Ireland (Warm Standby)"

    vpc_data = describe_vpc(region, vpc_id)
    vpc_data["label"] = label
    vpc_data["retrieved_at"] = datetime.now(timezone.utc).isoformat()
    return vpc_data


async def _get_arc_cluster_info() -> dict:
    client = get_arc_client()
    cluster_resp = client.describe_cluster(ClusterArn=CONFIG["arc_cluster_arn"])
    cluster = cluster_resp["Cluster"]

    panels_resp = client.list_control_panels(ClusterArn=CONFIG["arc_cluster_arn"])

    result = {
        "cluster": {
            "name": cluster["Name"],
            "arn": cluster["ClusterArn"],
            "status": cluster["Status"],
            "endpoints": cluster.get("ClusterEndpoints", []),
        },
        "control_panels": [],
    }

    for panel in panels_resp.get("ControlPanels", []):
        controls_resp = client.list_routing_controls(
            ControlPanelArn=panel["ControlPanelArn"]
        )
        result["control_panels"].append({
            "name": panel["Name"],
            "arn": panel["ControlPanelArn"],
            "status": panel["Status"],
            "routing_controls": [
                {
                    "name": rc["Name"],
                    "arn": rc["RoutingControlArn"],
                    "status": rc["Status"],
                }
                for rc in controls_resp.get("RoutingControls", [])
            ],
        })

    return result


# ── Entrypoint ─────────────────────────────────────────────────────────
async def main():
    missing = [k for k, v in CONFIG.items() if not v and k != "primary_vpc_id" and k != "standby_vpc_id"]
    if missing:
        log.error(f"Missing required environment variables: {missing}")
        log.error("Run 'terraform output mcp_server_config' and export the values.")
        sys.exit(1)

    log.info("ARC Failover Assistant MCP Server starting...")
    log.info(f"Primary region: {CONFIG['primary_region']} (Cape Town)")
    log.info(f"Standby region: {CONFIG['standby_region']} (Ireland)")

    async with stdio_server() as (read_stream, write_stream):
        await app.run(read_stream, write_stream, app.create_initialization_options())


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
