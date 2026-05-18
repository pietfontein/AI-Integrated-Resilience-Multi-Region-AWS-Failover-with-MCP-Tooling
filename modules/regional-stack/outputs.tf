################################################################################
# modules/regional-stack/outputs.tf
################################################################################

output "vpc_id" { value = aws_vpc.main.id }

output "alb_dns_name" {
  description = "ALB DNS name, or EC2 public IP:8080 when ALB is disabled"
  value = var.enable_alb ? aws_lb.app[0].dns_name : coalesce(
    aws_instance.app[0].public_ip,
    aws_instance.app[0].private_ip,
    "127.0.0.1"
  )
}

output "alb_zone_id" {
  value = var.enable_alb ? aws_lb.app[0].zone_id : ""
}

output "app_health_url" {
  description = "Full URL for /health (works with curl on LocalStack without ALB)"
  value       = var.enable_alb ? "${var.certificate_arn != "" ? "https" : "http"}://${aws_lb.app[0].dns_name}/health" : "http://${coalesce(aws_instance.app[0].public_ip, aws_instance.app[0].private_ip)}:8080/health"
}

output "state_bucket_id" { value = aws_s3_bucket.state.id }
output "state_bucket_arn" { value = aws_s3_bucket.state.arn }
output "instance_ids" { value = aws_instance.app[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
