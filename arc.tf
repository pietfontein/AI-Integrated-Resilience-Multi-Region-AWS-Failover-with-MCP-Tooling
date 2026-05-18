################################################################################
# arc.tf — Route 53 ARC (real AWS only; skipped when use_localstack = true)
################################################################################

resource "aws_route53recoverycontrolconfig_cluster" "resilience_cluster" {
  count    = var.use_localstack ? 0 : 1
  provider = aws.arc_control_plane
  name     = "${var.project_name}-anti-load-shedding-cluster"
}

resource "aws_route53recoverycontrolconfig_control_panel" "main_panel" {
  count       = var.use_localstack ? 0 : 1
  provider    = aws.arc_control_plane
  cluster_arn = aws_route53recoverycontrolconfig_cluster.resilience_cluster[0].arn
  name        = "RegionalFailoverPanel"
}

resource "aws_route53recoverycontrolconfig_routing_control" "primary_switch" {
  count             = var.use_localstack ? 0 : 1
  provider          = aws.arc_control_plane
  cluster_arn       = aws_route53recoverycontrolconfig_cluster.resilience_cluster[0].arn
  control_panel_arn = aws_route53recoverycontrolconfig_control_panel.main_panel[0].arn
  name              = "PrimaryRegionActive"
}

resource "aws_route53recoverycontrolconfig_routing_control" "failover_switch" {
  count             = var.use_localstack ? 0 : 1
  provider          = aws.arc_control_plane
  cluster_arn       = aws_route53recoverycontrolconfig_cluster.resilience_cluster[0].arn
  control_panel_arn = aws_route53recoverycontrolconfig_control_panel.main_panel[0].arn
  name              = "FailoverRegionActive"
}

resource "aws_route53recoverycontrolconfig_safety_rule" "one_region_active" {
  count             = var.use_localstack ? 0 : 1
  provider          = aws.arc_control_plane
  control_panel_arn = aws_route53recoverycontrolconfig_control_panel.main_panel[0].arn
  name              = "OneRegionMustBeActive"
  wait_period_ms    = 5000

  rule_config {
    inverted  = false
    threshold = 1
    type      = "ATLEAST"
  }

  asserted_controls = [
    aws_route53recoverycontrolconfig_routing_control.primary_switch[0].arn,
    aws_route53recoverycontrolconfig_routing_control.failover_switch[0].arn,
  ]
}

resource "aws_route53_zone" "app_zone" {
  count    = var.use_localstack ? 0 : 1
  provider = aws.arc_control_plane
  name     = "${var.project_name}.example.com"

  tags = {
    Purpose = "multi-region-failover"
  }
}

resource "aws_route53_health_check" "primary_arc" {
  count               = var.use_localstack ? 0 : 1
  provider            = aws.arc_control_plane
  type                = "RECOVERY_CONTROL"
  routing_control_arn = aws_route53recoverycontrolconfig_routing_control.primary_switch[0].arn

  tags = {
    Name   = "primary-arc-health-check"
    Region = "af-south-1"
  }
}

resource "aws_route53_health_check" "failover_arc" {
  count               = var.use_localstack ? 0 : 1
  provider            = aws.arc_control_plane
  type                = "RECOVERY_CONTROL"
  routing_control_arn = aws_route53recoverycontrolconfig_routing_control.failover_switch[0].arn

  tags = {
    Name   = "failover-arc-health-check"
    Region = "eu-west-1"
  }
}

resource "aws_route53_record" "primary" {
  count    = var.use_localstack ? 0 : 1
  provider = aws.arc_control_plane
  zone_id  = aws_route53_zone.app_zone[0].zone_id
  name     = "app.${var.project_name}.example.com"
  type     = "A"

  failover_routing_policy {
    type = "PRIMARY"
  }

  set_identifier  = "primary-cape-town"
  health_check_id = aws_route53_health_check.primary_arc[0].id

  alias {
    name                   = module.primary_stack.alb_dns_name
    zone_id                = module.primary_stack.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "failover" {
  count    = var.use_localstack ? 0 : 1
  provider = aws.arc_control_plane
  zone_id  = aws_route53_zone.app_zone[0].zone_id
  name     = "app.${var.project_name}.example.com"
  type     = "A"

  failover_routing_policy {
    type = "SECONDARY"
  }

  set_identifier  = "failover-ireland"
  health_check_id = aws_route53_health_check.failover_arc[0].id

  alias {
    name                   = module.failover_stack.alb_dns_name
    zone_id                = module.failover_stack.alb_zone_id
    evaluate_target_health = true
  }
}
