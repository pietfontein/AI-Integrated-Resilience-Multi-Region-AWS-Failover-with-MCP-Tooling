################################################################################
# modules/regional-stack/variables.tf
################################################################################

variable "project_name" { type = string }
variable "environment" { type = string }
variable "region_label" { type = string }
variable "region_name" { type = string }
variable "replica_count" { type = number }
variable "instance_type" { type = string }
variable "bucket_name" { type = string }
variable "vpc_cidr" { type = string }
variable "public_subnet_cidrs" { type = list(string) }
variable "private_subnet_cidrs" { type = list(string) }

variable "allowed_cidr_blocks" {
  type    = list(string)
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "certificate_arn" {
  description = "ACM certificate ARN for HTTPS listener; leave empty for HTTP on port 80"
  type        = string
  default     = ""
}

variable "enable_alb" {
  description = "Use ALB in front of app tier. Set false for LocalStack Community (no ELBv2)."
  type        = bool
  default     = true
}
