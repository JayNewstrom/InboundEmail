terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region  = local.aws_region
  profile = var.aws_profile
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

locals {
  aws_region = "us-east-1"

  inbound_email_table_name = "InboundEmail"

  api_domain_name = "api.${var.domain_name}"

  api_validation_domains = distinct(
  [
  for k, v in aws_acm_certificate.api_certificate[0].domain_validation_options : merge(
  tomap(v), { domain_name = replace(v.domain_name, "*.", "") }
  )
  ]
  )
}

resource "aws_dynamodb_table" "inbound_email" {
  name         = local.inbound_email_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "emailAddress"
  range_key    = "receivedAt"

  attribute {
    name = "emailAddress"
    type = "S"
  }

  attribute {
    name = "receivedAt"
    type = "S"
  }

  attribute {
    name = "messageId"
    type = "S"
  }

  #  TODO: Consider swapping with primary index, so that body can be removed from projection?
  global_secondary_index {
    name            = "MessageIdIndex"
    hash_key        = "messageId"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled = true
  }

  tags = var.aws_tags
}

module "inbound_email_s3" {
  source = "../inbound_email_s3"

  aws_profile = var.aws_profile
  aws_region  = local.aws_region
  bucket_name = var.domain_name
}

module "lambda_ses_inbound" {
  source = "../lambda_ses_inbound/terraform"

  aws_profile              = var.aws_profile
  aws_region               = local.aws_region
  inbound_email_table_arn  = aws_dynamodb_table.inbound_email.arn
  inbound_email_table_name = aws_dynamodb_table.inbound_email.name
  s3_bucket_arn            = module.inbound_email_s3.bucket_arn
  s3_bucket_name           = module.inbound_email_s3.bucket_name
}

module "ses" {
  source = "../ses"

  aws_profile          = var.aws_profile
  aws_region           = local.aws_region
  bucket_name          = module.inbound_email_s3.bucket_name
  cloudflare_api_token = var.cloudflare_api_token
  cloudflare_zone      = var.cloudflare_zone

  dns_mx_allow_overwrite_records         = var.dns_mx_allow_overwrite_records
  dns_mx_ttl                             = var.dns_mx_ttl
  dns_validation_allow_overwrite_records = var.dns_validation_allow_overwrite_records
  dns_validation_ttl                     = var.dns_validation_ttl

  domain_name         = var.domain_name
  lambda_function_arn = module.lambda_ses_inbound.lambda_function_arn
  mx_priority         = 10
}

module "lambda_list_emails" {
  source = "../lambda_list_emails/terraform"

  aws_api_gateway_execution_arn = aws_apigatewayv2_api.api.execution_arn
  aws_profile                   = var.aws_profile
  aws_region                    = local.aws_region
  inbound_email_table_arn       = aws_dynamodb_table.inbound_email.arn
  inbound_email_table_name      = aws_dynamodb_table.inbound_email.name
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
  domain_name       = local.api_domain_name
  validation_method = "DNS"

  options {
    certificate_transparency_logging_preference = "ENABLED"
  }

  tags = var.aws_tags

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

resource "aws_apigatewayv2_stage" "api_production" {
  api_id        = aws_apigatewayv2_api.api.id
  name          = "production"
  deployment_id = aws_apigatewayv2_deployment.api.id
}

resource "aws_apigatewayv2_domain_name" "api" {
  domain_name = local.api_domain_name

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
  integration_uri    = module.lambda_list_emails.lambda_invoke_arn
}

resource "aws_apigatewayv2_route" "api_list_emails" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /emails"

  target = "integrations/${aws_apigatewayv2_integration.api_list_emails.id}"
}
