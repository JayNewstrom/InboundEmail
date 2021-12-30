variable "upstream_s3_buckets" {
  type = list(object({
    url  = string
    name = string
  }))
}

variable "domain_name" {
}

variable "cloudflare_zone" {
}

variable "cloudflare_api_token" {
}

variable "aws_profile" {
}

variable "cloudfront_price_class" {
}

variable "dns_validation_ttl" {
}

variable "dns_ttl" {
}

variable "dns_validation_allow_overwrite_records" {
}

variable "dns_allow_overwrite_records" {
}
