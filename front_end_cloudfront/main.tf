terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = var.aws_profile
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

locals {
  validation_domains = distinct(
  [
  for k, v in aws_acm_certificate.certificate[0].domain_validation_options : merge(
  tomap(v), { domain_name = replace(v.domain_name, "*.", "") }
  )
  ]
  )
}

resource "aws_cloudfront_distribution" "api" {
  origin_group {
    origin_id = "front_end"

    failover_criteria {
      status_codes = [500, 502, 503, 504]
    }

    dynamic "member" {
      for_each = var.upstream_s3_buckets
      content {
        origin_id = member.value["name"]
      }
    }
  }

  dynamic "origin" {
    for_each = var.upstream_s3_buckets
    content {
      domain_name = origin.value["url"]
      origin_id   = origin.value["name"]

      s3_origin_config {
        origin_access_identity = aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path
      }
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  aliases = [var.domain_name]

  default_cache_behavior {
    allowed_methods = [
      "GET",
      "HEAD",
    ]

    cached_methods = [
      "GET",
      "HEAD",
    ]

    target_origin_id = "front_end"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    compress = true

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000
  }

  price_class = var.cloudfront_price_class

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.certificate_validation.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  custom_error_response {
    error_code            = 403
    response_code         = 200
    error_caching_min_ttl = 0
    response_page_path    = "/"
  }

  wait_for_deployment = false
}

resource "aws_acm_certificate" "certificate" {
  count             = 1
  domain_name       = var.domain_name
  validation_method = "DNS"

  options {
    certificate_transparency_logging_preference = "ENABLED"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "cloudflare_record" "validation" {
  count = 1

  zone_id = var.cloudflare_zone
  name    = element(local.validation_domains, count.index)["resource_record_name"]
  type    = element(local.validation_domains, count.index)["resource_record_type"]
  value   = replace(element(local.validation_domains, count.index)["resource_record_value"], "/.$/", "")
  ttl     = var.dns_validation_ttl
  proxied = false

  allow_overwrite = var.dns_validation_allow_overwrite_records

  depends_on = [aws_acm_certificate.certificate]
}

resource "aws_acm_certificate_validation" "certificate_validation" {
  certificate_arn = aws_acm_certificate.certificate[0].arn

  validation_record_fqdns = cloudflare_record.validation.*.hostname
}

resource "cloudflare_record" "domain_record" {
  zone_id = var.cloudflare_zone
  name    = var.domain_name
  type    = "CNAME"
  value   = aws_cloudfront_distribution.api.domain_name
  ttl     = var.dns_ttl
  proxied = false

  allow_overwrite = var.dns_allow_overwrite_records
}

resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "access-identity-${var.domain_name}.s3.amazonaws.com"
}
