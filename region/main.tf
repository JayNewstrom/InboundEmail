provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

locals {
  aws_account_id          = data.aws_caller_identity.current.account_id
  inbound_email_table_arn = "arn:aws:dynamodb:${var.aws_region}:${local.aws_account_id}:table/${var.inbound_email_table_name}"
}

data "aws_caller_identity" "current" {}

module "inbound_email_s3" {
  source = "../inbound_email_s3"

  aws_profile = var.aws_profile
  aws_region  = var.aws_region
  bucket_name = "${var.domain_name}.${var.aws_region}"
}

module "lambda_ses_inbound" {
  source = "../lambda_ses_inbound/terraform"

  aws_profile              = var.aws_profile
  aws_region               = var.aws_region
  inbound_email_table_arn  = local.inbound_email_table_arn
  inbound_email_table_name = var.inbound_email_table_name
  s3_bucket_arn            = module.inbound_email_s3.bucket_arn
  s3_bucket_name           = module.inbound_email_s3.bucket_name
}

module "ses" {
  source = "../ses"

  aws_profile          = var.aws_profile
  aws_region           = var.aws_region
  bucket_name          = module.inbound_email_s3.bucket_name
  cloudflare_api_token = var.cloudflare_api_token
  cloudflare_zone      = var.cloudflare_zone

  dns_mx_allow_overwrite_records         = var.dns_mx_allow_overwrite_records
  dns_mx_ttl                             = var.dns_mx_ttl
  dns_validation_allow_overwrite_records = var.dns_validation_allow_overwrite_records
  dns_validation_ttl                     = var.dns_validation_ttl

  domain_name         = var.domain_name
  lambda_function_arn = module.lambda_ses_inbound.lambda_function_arn
  mx_priority         = var.mx_priority
}

module "lambda_list_emails" {
  source = "../lambda_list_emails/terraform"

  aws_api_gateway_execution_arn = module.api_gateway.api_execution_arn
  aws_profile                   = var.aws_profile
  aws_region                    = var.aws_region
  inbound_email_table_arn       = local.inbound_email_table_arn
  inbound_email_table_name      = var.inbound_email_table_name
}

module "api_gateway" {
  source = "../api_gateway"

  aws_profile = var.aws_profile
  aws_region  = var.aws_region

  domain_name = "${var.aws_region}.api.${var.domain_name}"

  lambda_list_emails_invoke_arn = module.lambda_list_emails.lambda_invoke_arn

  cloudflare_api_token                   = var.cloudflare_api_token
  cloudflare_zone                        = var.cloudflare_zone
  dns_ttl                                = var.dns_ttl
  dns_validation_allow_overwrite_records = var.dns_validation_allow_overwrite_records
  dns_validation_ttl                     = var.dns_validation_ttl
}

module "front_end_s3" {
  source = "../front_end_s3"

  aws_cloudfront_origin_access_identity_iam_arn = var.front_end_aws_cloudfront_origin_access_identity_iam_arn

  aws_profile = var.aws_profile
  aws_region  = var.aws_region
  bucket_name = "front-end.${var.domain_name}.${var.aws_region}"
}
