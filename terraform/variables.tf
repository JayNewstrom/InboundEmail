variable "domain_name" {
}

variable "cloudflare_zone" {
}

variable "cloudflare_api_token" {
}

variable "aws_profile" {
  default = ""
}

variable "aws_tags" {
  type        = map(string)
  default     = {}
  description = "tags for all the resources, if any"
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
