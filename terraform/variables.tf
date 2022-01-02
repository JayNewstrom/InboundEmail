variable "domain_name" {
}

variable "cloudflare_zone" {
}

variable "cloudflare_api_token" {
}

variable "aws_profile" {
  default = ""
}

variable "dns_ttl" {
  default = 1 // 1 is automatic.
}

variable "dns_validation_ttl" {
  default = 120
}

variable "dns_mx_ttl" {
  default = 3600
}

variable "dns_validation_allow_overwrite_records" {
  default = true
}

variable "dns_mx_allow_overwrite_records" {
  default = true
}

variable "cloudfront_price_class" {
  default     = "PriceClass_100" // Only US,Canada,Europe
  description = "CloudFront distribution price class"
}

variable "dns_allow_overwrite_records" {
  default = true
}
variable "github_oidc_repository_slug" {
}
