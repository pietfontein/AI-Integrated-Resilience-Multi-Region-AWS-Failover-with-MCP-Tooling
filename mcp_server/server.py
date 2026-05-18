#!/usr/bin/env python3
"""
mcp_server/server.py — Route 53 ARC Failover Assistant
"""

import json
import logging
import os
import sys
from typing import Any

import boto3
from botocore.exceptions import ClientError, NoCredentialsError
from mcp.server import Server  # pyright: ignore[reportMissingImports]
from mcp.server.stdio import stdio_server  # pyright: ignore[reportMissingImports]
from mcp.types import TextContent, Tool  # pyright: ignore[reportMissingImports]

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("arc-mcp-server")

_CONFIG_FIELDS: tuple[tuple[str, str, str], ...] = (
    ("primary_region", "PRIMARY_REGION", "af-south-1"),
    ("failover_region", "FAILOVER_REGION", "eu-west-1"),
    ("cluster_arn", "ARC_CLUSTER_ARN", ""),
    ("primary_routing_control_arn", "PRIMARY_ROUTING_CONTROL_ARN", ""),
    ("failover_routing_control_arn", "FAILOVER_ROUTING_CONTROL_ARN", ""),
    ("primary_vpc_id", "PRIMARY_VPC_ID", ""),
    ("failover_vpc_id", "FAILOVER_VPC_ID", ""),
)


def _vault_token() -> str | None:
    t = os.environ.get("VAULT_TOKEN")
    if t:
        return t.strip()
    path = os.path.expanduser(os.environ.get("VAULT_TOKEN_PATH", "~/.vault-token"))
    try:
        with open(os.path.expanduser(path), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return None


def _read_vault_kv() -> dict[str, Any]:
    addr = os.environ.get("VAULT_ADDR", "").strip()
    if not addr:
        return {}

    try:
        import hvac
    except ImportError:
        log.warning("VAULT_ADDR is set but hvac is not installed; run: pip install hvac")
        return {}

    token = _vault_token()
    if not token:
        log.warning("VAULT_ADDR is set but no token (VAULT_TOKEN or ~/.vault-token); skipping Vault")
        return {}

    mount = os.environ.get("VAULT_KV_MOUNT", "secret").strip().strip("/")
    path = os.environ.get("VAULT_KV_PATH", "resilience/mcp").strip().strip("/")

    try:
        client = hvac.Client(url=addr, token=token)
        if not client.is_authenticated():
            log.warning("Vault token rejected or expired; skipping Vault")
            return {}
        resp = client.secrets.kv.v2.read_secret_version(mount_point=mount, path=path)
        return dict(resp.get("data", {}).get("data", {}) or {})
    except Exception as e:
        log.warning("Could not read Vault KV at %s/%s: %s", mount, path, e)
        return {}


def build_config() -> dict[str, Any]:
    cfg: dict[str, Any] = {"arc_control_plane_region": "us-west-2"}
    vault_data = _read_vault_kv()
    filled_from_vault: list[str] = []

    for field, env_name, default in _CONFIG_FIELDS:
        if env_name in os.environ:
            cfg[field] = os.environ[env_name]
            continue
        v = vault_data.get(field)
        if v is not None and str(v).strip() != "":
            cfg[field] = str(v).strip()
            filled_from_vault.append(field)
        else:
            cfg[field] = default

    if filled_from_vault:
        log.info("Loaded from Vault (KV): %s", ", ".join(sorted(filled_from_vault)))

    return cfg


CONFIG = build_config()

LOCALSTACK_DEV = os.environ.get("LOCALSTACK_DEV", "").strip() in ("1", "true", "yes")
AWS_ENDPOINT_URL = os.environ.get("AWS_ENDPOINT_URL", "").strip()


def get_client(service: str, region: str, endpoint_url: str | None = None):
    kwargs: dict[str, Any] = {"region_name": region}
    effective_endpoint = endpoint_url or AWS_ENDPOINT_URL
    if effective_endpoint:
        kwargs["endpoint_url"] = effective_endpoint
        kwargs.setdefault("aws_access_key_id", os.environ.get("AWS_ACCESS_KEY_ID", "test"))
        kwargs.setdefault("aws_secret_access_key", os.environ.get("AWS_SECRET_ACCESS_KEY", "test"))
    try:
        return boto3.client(service, **kwargs)
    except NoCredentialsError:
        log.error("No AWS credentials found. Configure via IAM role or environment.")
        raise


def get_regional_readiness() -> dict[str, Any]:
    if LOCALSTACK_DEV:
        return {
            "summary": "LOCALSTACK — ARC is not deployed locally. Use describe_vpc and ALB outputs for infra checks.",
            "controls": {
                "primary_cape_town": {"status": "N/A", "reason": "ARC disabled on LocalStack"},
                "failover_ireland": {"status": "N/A", "reason": "ARC disabled on LocalStack"},
            },
        }

    controls = {
        "primary_cape_town": CONFIG["primary_routing_control_arn"],
        "failover_ireland": CONFIG["failover_routing_control_arn"],
    }

    missing = [label for label, arn in controls.items() if not arn]
    if missing:
        return {
            "summary": "UNKNOWN - ARC routing controls are not fully configured.",
            "controls": {
                label: {"status": "UNKNOWN", "reason": "ARN not configured", "arn": arn}
                for label, arn in controls.items()
            },
        }

    cluster_endpoints = _get_cluster_endpoints()
    if not cluster_endpoints:
        return {
            "summary": "UNKNOWN - no ARC cluster endpoints are available.",
            "controls": {
                label: {"status": "UNKNOWN", "reason": "Cluster endpoint unavailable", "arn": arn}
                for label, arn in controls.items()
            },
        }

    errors: list[str] = []
    results: dict[str, Any] = {}
    for endpoint in cluster_endpoints:
        try:
            results = _get_routing_control_states(endpoint, controls)
            break
        except ClientError as e:
            log.warning("ARC cluster endpoint %s state read failed: %s", endpoint, e)
            errors.append(f"{endpoint}: {e}")

    if not results:
        return {
            "summary": "UNKNOWN - all ARC cluster endpoints failed while reading routing state.",
            "controls": {
                label: {"status": "ERROR", "reason": "; ".join(errors), "arn": arn}
                for label, arn in controls.items()
            },
        }

    primary_on = results.get("primary_cape_town", {}).get("routing_control_state") == "On"
    failover_on = results.get("failover_ireland", {}).get("routing_control_state") == "On"

    if primary_on and not failover_on:
        summary = "NOMINAL — Cape Town (af-south-1) is active. Ireland is on warm standby."
    elif failover_on and not primary_on:
        summary = "FAILOVER ACTIVE — Ireland (eu-west-1) is serving traffic. Cape Town is offline."
    elif primary_on and failover_on:
        summary = "WARNING — Both regions show ENABLED. Safety rule may be preventing this state."
    else:
        summary = "CRITICAL — Both regions are DISABLED. No region is serving traffic."

    return {"summary": summary, "controls": results}


def _update_routing_controls_on_endpoint(
    endpoint_url: str,
    routing_updates: list[tuple[str, str]],
) -> None:
    client = get_client(
        "route53-recovery-cluster",
        CONFIG["arc_control_plane_region"],
        endpoint_url=endpoint_url,
    )
    client.update_routing_control_states(
        UpdateRoutingControlStateEntries=[
            {"RoutingControlArn": arn, "RoutingControlState": state}
            for arn, state in routing_updates
        ]
    )


def _get_routing_control_states(
    endpoint_url: str,
    routing_controls: dict[str, str],
) -> dict[str, Any]:
    client = get_client(
        "route53-recovery-cluster",
        CONFIG["arc_control_plane_region"],
        endpoint_url=endpoint_url,
    )

    results: dict[str, Any] = {}
    for label, arn in routing_controls.items():
        resp = client.get_routing_control_state(RoutingControlArn=arn)
        state = resp["RoutingControlState"]
        results[label] = {
            "status": "ENABLED" if state == "On" else "DISABLED" if state == "Off" else state,
            "routing_control_state": state,
            "arn": arn,
            "endpoint_used": endpoint_url,
        }
    return results


def trigger_failover(target_region: str, reason: str) -> dict[str, Any]:
    if LOCALSTACK_DEV:
        return {
            "success": False,
            "error": "trigger_failover is not available on LocalStack (ARC not deployed). Use real AWS for failover drills.",
        }

    if target_region not in ("ireland", "cape_town"):
        return {"success": False, "error": "target_region must be 'ireland' or 'cape_town'"}

    if not reason or len(reason.strip()) < 10:
        return {"success": False, "error": "Reason must be at least 10 characters for audit compliance."}

    missing = [
        name
        for name in ("primary_routing_control_arn", "failover_routing_control_arn")
        if not CONFIG[name]
    ]
    if missing:
        return {
            "success": False,
            "error": f"Missing required ARC routing control configuration: {', '.join(missing)}",
        }

    cluster_endpoints = _get_cluster_endpoints()
    if not cluster_endpoints:
        return {"success": False, "error": "Could not retrieve ARC cluster endpoints."}

    if target_region == "ireland":
        routing_updates = [
            (CONFIG["primary_routing_control_arn"], "Off"),
            (CONFIG["failover_routing_control_arn"], "On"),
        ]
    else:
        routing_updates = [
            (CONFIG["primary_routing_control_arn"], "On"),
            (CONFIG["failover_routing_control_arn"], "Off"),
        ]

    errors: list[str] = []
    for endpoint in cluster_endpoints:
        try:
            _update_routing_controls_on_endpoint(endpoint, routing_updates)
            log.info("Failover triggered to %s via %s. Reason: %s", target_region, endpoint, reason)
            return {
                "success": True,
                "active_region": target_region,
                "reason": reason,
                "endpoint_used": endpoint,
                "message": f"Traffic redirected to {target_region}. DNS propagation: ~30-60s.",
            }
        except ClientError as e:
            log.warning("ARC cluster endpoint %s failed: %s", endpoint, e)
            errors.append(f"{endpoint}: {e}")

    return {
        "success": False,
        "error": "All ARC cluster endpoints failed.",
        "details": errors,
    }


def describe_vpc(region_label: str) -> dict[str, Any]:
    region_map = {
        "primary": (CONFIG["primary_region"], CONFIG["primary_vpc_id"]),
        "failover": (CONFIG["failover_region"], CONFIG["failover_vpc_id"]),
    }

    if region_label not in region_map:
        return {"error": "region_label must be 'primary' or 'failover'"}

    region, vpc_id = region_map[region_label]

    if not vpc_id:
        return {"error": f"VPC ID for {region_label} not configured."}

    ec2 = get_client("ec2", region)

    try:
        vpc_resp = ec2.describe_vpcs(VpcIds=[vpc_id])
        vpc = vpc_resp["Vpcs"][0]

        subnet_resp = ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])
        subnets = [
            {
                "id": s["SubnetId"],
                "cidr": s["CidrBlock"],
                "az": s["AvailabilityZone"],
                "type": "public" if s.get("MapPublicIpOnLaunch") else "private",
                "available_ips": s["AvailableIpAddressCount"],
            }
            for s in subnet_resp["Subnets"]
        ]

        instance_resp = ec2.describe_instances(
            Filters=[
                {"Name": "vpc-id", "Values": [vpc_id]},
                {"Name": "instance-state-name", "Values": ["running", "stopped"]},
            ]
        )
        instances = []
        for reservation in instance_resp["Reservations"]:
            for inst in reservation["Instances"]:
                name = next(
                    (t["Value"] for t in inst.get("Tags", []) if t["Key"] == "Name"),
                    "unnamed",
                )
                instances.append({
                    "id": inst["InstanceId"],
                    "name": name,
                    "type": inst["InstanceType"],
                    "state": inst["State"]["Name"],
                    "private_ip": inst.get("PrivateIpAddress", "N/A"),
                    "az": inst["Placement"]["AvailabilityZone"],
                })

        return {
            "region": region,
            "region_label": region_label,
            "vpc": {
                "id": vpc["VpcId"],
                "cidr": vpc["CidrBlock"],
                "state": vpc["State"],
                "tags": {t["Key"]: t["Value"] for t in vpc.get("Tags", [])},
            },
            "subnets": subnets,
            "instances": instances,
            "summary": (
                f"{region_label.upper()} VPC in {region}: "
                f"CIDR {vpc['CidrBlock']}, {len(subnets)} subnets, {len(instances)} instances."
            ),
        }

    except ClientError as e:
        return {"error": str(e)}


def get_cluster_readiness_summary() -> dict[str, Any]:
    if LOCALSTACK_DEV:
        return {
            "name": "localstack-stub",
            "status": "NOT_DEPLOYED",
            "endpoints": [],
            "note": "ARC cluster is not provisioned when use_localstack=true.",
        }

    if not CONFIG["cluster_arn"]:
        return {"error": "ARC_CLUSTER_ARN is not configured."}

    client = get_client("route53-recovery-control-config", CONFIG["arc_control_plane_region"])
    try:
        resp = client.describe_cluster(ClusterArn=CONFIG["cluster_arn"])
        cluster = resp["Cluster"]
        return {
            "name": cluster["Name"],
            "status": cluster["Status"],
            "endpoints": cluster.get("ClusterEndpoints", []),
        }
    except ClientError as e:
        return {"error": str(e)}


def _get_cluster_endpoints() -> list[str]:
    summary = get_cluster_readiness_summary()
    return [ep["Endpoint"] for ep in summary.get("endpoints", [])]


app = Server("arc-failover-assistant")

TOOLS = [
    Tool(
        name="get_regional_readiness",
        description=(
            "Query the current readiness status of both AWS regions. "
            "Returns which region is actively serving traffic and a plain-English summary."
        ),
        inputSchema={"type": "object", "properties": {}, "required": []},
    ),
    Tool(
        name="trigger_failover",
        description=(
            "Redirect application traffic by flipping Route 53 ARC routing controls. "
            "Use 'ireland' to fail over, 'cape_town' to fail back. Reason is mandatory."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "target_region": {
                    "type": "string",
                    "enum": ["ireland", "cape_town"],
                    "description": "The region to activate.",
                },
                "reason": {
                    "type": "string",
                    "minLength": 10,
                    "description": "Reason for the failover (min 10 chars).",
                },
            },
            "required": ["target_region", "reason"],
        },
    ),
    Tool(
        name="describe_vpc",
        description="Return VPC, subnet, and EC2 details for primary or failover region.",
        inputSchema={
            "type": "object",
            "properties": {
                "region_label": {
                    "type": "string",
                    "enum": ["primary", "failover"],
                    "description": "primary = Cape Town, failover = Ireland.",
                }
            },
            "required": ["region_label"],
        },
    ),
    Tool(
        name="get_cluster_readiness_summary",
        description="Check ARC control plane cluster health and list cluster endpoints.",
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


async def main():
    log.info("ARC Failover MCP Server starting...")
    if LOCALSTACK_DEV or AWS_ENDPOINT_URL:
        log.info("LocalStack mode: endpoint=%s", AWS_ENDPOINT_URL or "(from AWS config)")
    log.info("Primary region:  %s", CONFIG["primary_region"])
    log.info("Failover region: %s", CONFIG["failover_region"])

    async with stdio_server() as (read_stream, write_stream):
        await app.run(read_stream, write_stream, app.create_initialization_options())


if __name__ == "__main__":
    import asyncio

    asyncio.run(main())
