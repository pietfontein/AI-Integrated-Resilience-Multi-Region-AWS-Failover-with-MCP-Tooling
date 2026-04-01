################################################################################
# outputs.tf — Stack-level outputs for integration and verification
################################################################################

output "primary_vpc_id" {
  description = "VPC ID of the Cape Town (primary) stack"
  value       = module.primary_stack.vpc_id
}

output "failover_vpc_id" {
  description = "VPC ID of the Ireland (failover) stack"
  value       = module.failover_stack.vpc_id
}

output "app_endpoint" {
  description = "DNS name served by Route 53 — traffic follows ARC routing controls"
  value       = "https://app.${var.project_name}.example.com"
}

output "arc_cluster_arn" {
  description = "ARC cluster ARN — use this to query readiness via CLI or MCP server"
  value       = aws_route53recoverycontrolconfig_cluster.resilience_cluster.arn
}

output "primary_routing_control_arn" {
  description = "Cape Town routing control ARN — flip to OFF to trigger failover"
  value       = aws_route53recoverycontrolconfig_routing_control.primary_switch.arn
}

output "failover_routing_control_arn" {
  description = "Ireland routing control ARN — flip to ON to activate failover"
  value       = aws_route53recoverycontrolconfig_routing_control.failover_switch.arn
}

output "primary_alb_dns" {
  description = "Cape Town ALB DNS (for direct testing)"
  value       = module.primary_stack.alb_dns_name
}

output "failover_alb_dns" {
  description = "Ireland ALB DNS (for warm standby verification)"
  value       = module.failover_stack.alb_dns_name
}
