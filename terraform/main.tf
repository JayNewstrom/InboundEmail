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
}

resource "aws_dynamodb_table" "inbound_email" {
  name         = "InboundEmail"
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

  aws_api_gateway_execution_arn = module.api_gateway.api_execution_arn
  aws_profile                   = var.aws_profile
  aws_region                    = local.aws_region
  inbound_email_table_arn       = aws_dynamodb_table.inbound_email.arn
  inbound_email_table_name      = aws_dynamodb_table.inbound_email.name
}

module "api_gateway" {
  source = "../api_gateway"

  aws_profile = var.aws_profile
  aws_region  = local.aws_region

  domain_name = "${local.aws_region}.api.${var.domain_name}"

  lambda_list_emails_invoke_arn = module.lambda_list_emails.lambda_invoke_arn

  cloudflare_api_token                   = var.cloudflare_api_token
  cloudflare_zone                        = var.cloudflare_zone
  dns_ttl                                = var.dns_ttl
  dns_validation_allow_overwrite_records = var.dns_validation_allow_overwrite_records
  dns_validation_ttl                     = var.dns_validation_ttl
}
