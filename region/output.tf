output "inbound_email_bucket_arn" {
  value = module.inbound_email_s3.bucket_arn
}
output "inbound_email_bucket_name" {
  value = module.inbound_email_s3.bucket_name
}
output "api_url" {
  value = module.api_gateway.api_url
}
output "api_stage_path" {
  value = module.api_gateway.stage_path
}
output "front_end_bucket_url" {
  value = module.front_end_s3.bucket_url
}
output "front_end_bucket_name" {
  value = module.front_end_s3.bucket_name
}
output "front_end_bucket_arn" {
  value = module.front_end_s3.bucket_arn
}
