################################################################################
# localstack.tf — Simplified DNS for LocalStack dev (no ALB / no ARC)
################################################################################

locals {
  ls = var.use_localstack
}

resource "aws_route53_zone" "local_app_zone" {
  count    = local.ls ? 1 : 0
  provider = aws.arc_control_plane
  name     = "${var.project_name}.local"

  tags = {
    Purpose = "localstack-dev"
  }
}

# A record to primary app (EC2 public IP when ALB is off)
resource "aws_route53_record" "local_app" {
  count    = local.ls ? 1 : 0
  provider = aws.arc_control_plane
  zone_id  = aws_route53_zone.local_app_zone[0].zone_id
  name     = "app.${var.project_name}.local"
  type     = "A"
  ttl      = 60
  records  = [coalesce(module.primary_stack.alb_dns_name, "127.0.0.1")]
}
