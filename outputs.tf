################################################################################
# outputs.tf — Stack-level outputs for integration and verification
################################################################################

output "use_localstack" {
  description = "Whether this deployment targets LocalStack"
  value       = var.use_localstack
}

output "enable_alb" {
  description = "Whether ALB resources were created"
  value       = local.enable_alb
}

output "primary_vpc_id" {
  description = "VPC ID of the Cape Town (primary) stack"
  value       = module.primary_stack.vpc_id
}

output "failover_vpc_id" {
  description = "VPC ID of the Ireland (failover) stack"
  value       = module.failover_stack.vpc_id
}

output "app_endpoint" {
  description = "Application health URL"
  value       = module.primary_stack.app_health_url
}

output "local_dns_name" {
  description = "Route 53 name in LocalStack (when use_localstack = true)"
  value       = var.use_localstack ? "app.${var.project_name}.local" : null
}

output "arc_cluster_arn" {
  description = "ARC cluster ARN (empty on LocalStack)"
  value       = var.use_localstack ? "" : aws_route53recoverycontrolconfig_cluster.resilience_cluster[0].arn
}

output "primary_routing_control_arn" {
  description = "Cape Town routing control ARN (empty on LocalStack)"
  value       = var.use_localstack ? "" : aws_route53recoverycontrolconfig_routing_control.primary_switch[0].arn
}

output "failover_routing_control_arn" {
  description = "Ireland routing control ARN (empty on LocalStack)"
  value       = var.use_localstack ? "" : aws_route53recoverycontrolconfig_routing_control.failover_switch[0].arn
}

output "primary_alb_dns" {
  description = "Primary entry hostname or IP (ALB DNS or EC2 public IP)"
  value       = module.primary_stack.alb_dns_name
}

output "primary_health_url" {
  description = "curl-friendly health check URL for primary region"
  value       = module.primary_stack.app_health_url
}

output "failover_alb_dns" {
  description = "Failover entry hostname or IP"
  value       = module.failover_stack.alb_dns_name
}

output "failover_health_url" {
  description = "curl-friendly health check URL for failover region"
  value       = module.failover_stack.app_health_url
}

output "primary_instance_ids" {
  description = "EC2 instance IDs in the primary region"
  value       = module.primary_stack.instance_ids
}

output "failover_instance_ids" {
  description = "EC2 instance IDs in the failover region"
  value       = module.failover_stack.instance_ids
}
