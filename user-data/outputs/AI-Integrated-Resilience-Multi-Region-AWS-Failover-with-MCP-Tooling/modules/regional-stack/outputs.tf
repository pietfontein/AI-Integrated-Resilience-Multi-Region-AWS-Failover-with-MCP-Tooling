################################################################################
# modules/regional-stack/outputs.tf
################################################################################

output "vpc_id"             { value = aws_vpc.main.id }
output "alb_dns_name"       { value = aws_lb.app.dns_name }
output "alb_zone_id"        { value = aws_lb.app.zone_id }
output "state_bucket_id"    { value = aws_s3_bucket.state.id }
output "state_bucket_arn"   { value = aws_s3_bucket.state.arn }
output "instance_ids"       { value = aws_instance.app[*].id }
output "private_subnet_ids" { value = aws_subnet.private[*].id }
output "public_subnet_ids"  { value = aws_subnet.public[*].id }
