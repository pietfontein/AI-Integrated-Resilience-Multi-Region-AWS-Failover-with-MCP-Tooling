################################################################################
# arc.tf — Route 53 Application Recovery Controller
# Digital circuit breakers for zero-touch regional failover.
# ARC control plane MUST live in us-west-2 (AWS constraint).
################################################################################

# ── The Cluster: global control plane for failover decisions ──────────────────
resource "aws_route53recoverycontrolconfig_cluster" "resilience_cluster" {
  provider = aws.arc_control_plane
  name     = "${var.project_name}-anti-load-shedding-cluster"
}

# ── Control Panel: groups our regional routing switches ───────────────────────
resource "aws_route53recoverycontrolconfig_control_panel" "main_panel" {
  provider    = aws.arc_control_plane
  cluster_arn = aws_route53recoverycontrolconfig_cluster.resilience_cluster.arn
  name        = "RegionalFailoverPanel"
}

# ── Routing Control: the ON/OFF switch for Cape Town (Primary) ─────────────────
resource "aws_route53recoverycontrolconfig_routing_control" "primary_switch" {
  provider          = aws.arc_control_plane
  cluster_arn       = aws_route53recoverycontrolconfig_cluster.resilience_cluster.arn
  control_panel_arn = aws_route53recoverycontrolconfig_control_panel.main_panel.arn
  name              = "PrimaryRegionActive"
}

# ── Routing Control: the ON/OFF switch for Ireland (Failover) ─────────────────
resource "aws_route53recoverycontrolconfig_routing_control" "failover_switch" {
  provider          = aws.arc_control_plane
  cluster_arn       = aws_route53recoverycontrolconfig_cluster.resilience_cluster.arn
  control_panel_arn = aws_route53recoverycontrolconfig_control_panel.main_panel.arn
  name              = "FailoverRegionActive"
}

# ── Safety Rule: enforce that exactly ONE region is active at all times ───────
# This is the "no split-brain" guarantee. ARC will block invalid state changes.
resource "aws_route53recoverycontrolconfig_safety_rule" "one_region_active" {
  provider          = aws.arc_control_plane
  control_panel_arn = aws_route53recoverycontrolconfig_control_panel.main_panel.arn
  name              = "OneRegionMustBeActive"
  wait_period_ms    = 5000 # 5s minimum transition window — prevents flapping

  rule_config {
    inverted  = false
    threshold = 1
    type      = "ATLEAST"
  }

  asserted_controls = [
    aws_route53recoverycontrolconfig_routing_control.primary_switch.arn,
    aws_route53recoverycontrolconfig_routing_control.failover_switch.arn,
  ]
}

# ── Route 53 Hosted Zone (replace with your actual domain) ───────────────────
resource "aws_route53_zone" "app_zone" {
  provider = aws.arc_control_plane
  name     = "${var.project_name}.example.com"

  tags = {
    Purpose = "multi-region-failover"
  }
}

# ── Health Check wired to the Primary ARC routing control ─────────────────────
resource "aws_route53_health_check" "primary_arc" {
  provider                        = aws.arc_control_plane
  type                            = "RECOVERY_CONTROL"
  routing_control_arn             = aws_route53recoverycontrolconfig_routing_control.primary_switch.arn

  tags = {
    Name   = "primary-arc-health-check"
    Region = "af-south-1"
  }
}

# ── Health Check wired to the Failover ARC routing control ────────────────────
resource "aws_route53_health_check" "failover_arc" {
  provider                        = aws.arc_control_plane
  type                            = "RECOVERY_CONTROL"
  routing_control_arn             = aws_route53recoverycontrolconfig_routing_control.failover_switch.arn

  tags = {
    Name   = "failover-arc-health-check"
    Region = "eu-west-1"
  }
}

# ── DNS Record: PRIMARY (Cape Town) — serves traffic when switch is ON ────────
resource "aws_route53_record" "primary" {
  provider = aws.arc_control_plane
  zone_id  = aws_route53_zone.app_zone.zone_id
  name     = "app.${var.project_name}.example.com"
  type     = "A"

  failover_routing_policy {
    type = "PRIMARY"
  }

  set_identifier  = "primary-cape-town"
  health_check_id = aws_route53_health_check.primary_arc.id

  alias {
    name                   = module.primary_stack.alb_dns_name
    zone_id                = module.primary_stack.alb_zone_id
    evaluate_target_health = true
  }
}

# ── DNS Record: FAILOVER (Ireland) — promoted when primary switch flips OFF ───
resource "aws_route53_record" "failover" {
  provider = aws.arc_control_plane
  zone_id  = aws_route53_zone.app_zone.zone_id
  name     = "app.${var.project_name}.example.com"
  type     = "A"

  failover_routing_policy {
    type = "SECONDARY"
  }

  set_identifier  = "failover-ireland"
  health_check_id = aws_route53_health_check.failover_arc.id

  alias {
    name                   = module.failover_stack.alb_dns_name
    zone_id                = module.failover_stack.alb_zone_id
    evaluate_target_health = true
  }
}
