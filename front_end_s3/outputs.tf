output "bucket_url" {
  value = aws_s3_bucket.bucket.bucket_regional_domain_name
}
