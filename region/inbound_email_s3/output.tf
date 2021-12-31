output "bucket_arn" {
  value = aws_s3_bucket.inbound_email.arn
}
output "bucket_name" {
  value = aws_s3_bucket.inbound_email.id
}
