################################################################################
# modules/regional-stack/variables.tf
# Module-level inputs — all validated before any resource is created.
################################################################################

variable "project_name"   { type = string }
variable "environment"    { type = string }
variable "region_label"   { type = string } # "primary" or "failover"
variable "region_name"    { type = string }
variable "replica_count"  { type = number }
variable "instance_type"  { type = string }
variable "bucket_name"    { type = string }
variable "vpc_cidr"       { type = string }
variable "public_subnet_cidrs"  { type = list(string) }
variable "private_subnet_cidrs" { type = list(string) }
variable "allowed_cidr_blocks"  { type = list(string) default = [] }
variable "tags"           { type = map(string) default = {} }
