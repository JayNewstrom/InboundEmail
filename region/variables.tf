variable "domain_name" {
}

variable "cloudflare_zone" {
}

variable "cloudflare_api_token" {
}

variable "aws_region" {
}

variable "aws_profile" {
}

variable "dns_ttl" {
}

variable "dns_validation_ttl" {
}

variable "dns_mx_ttl" {
}

variable "dns_validation_allow_overwrite_records" {
}

variable "dns_mx_allow_overwrite_records" {
}

variable "inbound_email_table_name" {
}

variable "mx_priority" {
}

variable "front_end_aws_cloudfront_origin_access_identity_iam_arn" {
}
variable "supports_inbound_email" {
  type = bool
  default = true
}
