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
    origin_id = "api"

    failover_criteria {
      status_codes = [500, 502, 503, 504]
    }

    dynamic "member" {
      for_each = var.upstream_domains
      content {
        origin_id = member.value["name"]
      }
    }
  }

  dynamic "origin" {
    for_each = var.upstream_domains
    content {
      domain_name = replace(origin.value["url"], "https://", "")
      origin_id   = origin.value["name"]

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }

      origin_path = "/${origin.value["path"]}"
    }
  }

  enabled         = true
  is_ipv6_enabled = true

  aliases = [var.domain_name]

  default_cache_behavior {
    allowed_methods = [
      "GET",
      "HEAD",
      "OPTIONS",
    ]

    cached_methods = [
      "GET",
      "HEAD",
    ]

    target_origin_id = "api"

    response_headers_policy_id = aws_cloudfront_response_headers_policy.api.id
    cache_policy_id = aws_cloudfront_cache_policy.api.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.api.id

    compress = true

    viewer_protocol_policy = "redirect-to-https"
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

resource "aws_cloudfront_origin_request_policy" "api" {
  name = "api-policy"

  cookies_config {
    cookie_behavior = "all"
  }
  headers_config {
    header_behavior = "whitelist"
    headers {
      items = ["Origin"]
    }
  }
  query_strings_config {
    query_string_behavior = "all"
  }
}

resource "aws_cloudfront_cache_policy" "api" {
  name        = "api-policy"
  default_ttl = 0
  max_ttl     = 100
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

resource "aws_cloudfront_response_headers_policy" "api" {
  name = "api-policy"

  cors_config {
    access_control_allow_credentials = false

    access_control_allow_headers {
      items = ["*"]
    }

    access_control_expose_headers {
      items = ["*"]
    }

    access_control_allow_methods {
      items = [
        "GET",
        "HEAD",
        "PUT",
        "POST",
        "PATCH",
        "DELETE",
        "OPTIONS",
      ]
    }

    access_control_allow_origins {
      items = ["*"]
    }

    origin_override = false
  }
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
