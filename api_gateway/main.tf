terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

locals {
  api_validation_domains = distinct(
  [
  for k, v in aws_acm_certificate.api_certificate[0].domain_validation_options : merge(
  tomap(v), { domain_name = replace(v.domain_name, "*.", "") }
  )
  ]
  )
}

resource "cloudflare_record" "api_validation" {
  count = 1

  zone_id = var.cloudflare_zone
  name    = element(local.api_validation_domains, count.index)["resource_record_name"]
  type    = element(local.api_validation_domains, count.index)["resource_record_type"]
  value   = replace(element(local.api_validation_domains, count.index)["resource_record_value"], "/.$/", "")
  ttl     = var.dns_validation_ttl
  proxied = false

  allow_overwrite = var.dns_validation_allow_overwrite_records

  depends_on = [aws_acm_certificate.api_certificate]
}

resource "aws_acm_certificate" "api_certificate" {
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

resource "aws_acm_certificate_validation" "api_certificate_validation" {
  certificate_arn = aws_acm_certificate.api_certificate[0].arn

  validation_record_fqdns = cloudflare_record.api_validation.*.hostname
}

resource "cloudflare_record" "api" {
  zone_id = var.cloudflare_zone
  name    = aws_apigatewayv2_domain_name.api.domain_name
  type    = "CNAME"
  value   = aws_apigatewayv2_domain_name.api.domain_name_configuration[0].target_domain_name
  ttl     = var.dns_ttl
  proxied = false

  allow_overwrite = var.dns_validation_allow_overwrite_records
}

resource "aws_apigatewayv2_api" "api" {
  name          = "api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_domain_name" "api" {
  domain_name = var.domain_name

  domain_name_configuration {
    certificate_arn = aws_acm_certificate.api_certificate[0].arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  depends_on = [aws_acm_certificate_validation.api_certificate_validation]
}

resource "aws_apigatewayv2_api_mapping" "api" {
  api_id      = aws_apigatewayv2_api.api.id
  domain_name = aws_apigatewayv2_domain_name.api.id
  stage       = aws_apigatewayv2_stage.api_production.id
}


resource "aws_apigatewayv2_stage" "api_production" {
  api_id        = aws_apigatewayv2_api.api.id
  name          = "production"
  deployment_id = aws_apigatewayv2_deployment.api.id
}

resource "aws_apigatewayv2_deployment" "api" {
  api_id = aws_apigatewayv2_api.api.id

  triggers = {
    redeployment = sha1(join(",", tolist([
      jsonencode(aws_apigatewayv2_integration.api_list_emails),
      jsonencode(aws_apigatewayv2_route.api_list_emails),
    ])))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_apigatewayv2_integration" "api_list_emails" {
  api_id             = aws_apigatewayv2_api.api.id
  integration_type   = "AWS_PROXY"
  integration_method = "POST"
  integration_uri    = var.lambda_list_emails_invoke_arn
}

resource "aws_apigatewayv2_route" "api_list_emails" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /emails"

  target = "integrations/${aws_apigatewayv2_integration.api_list_emails.id}"
}
