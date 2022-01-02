provider "aws" {
  region  = "us-east-1"
  profile = var.aws_profile
}

resource "aws_dynamodb_table" "inbound_email" {
  name             = "InboundEmail"
  billing_mode     = "PAY_PER_REQUEST"
  hash_key         = "emailAddress"
  range_key        = "receivedAt"
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

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

  global_secondary_index {
    name            = "MessageIdIndex"
    hash_key        = "messageId"
    projection_type = "ALL"
  }

  replica {
    region_name = "us-west-2"
  }

  server_side_encryption {
    enabled = true
  }
}

module "region_us_east_1" {
  source = "../region"

  aws_region  = "us-east-1"
  mx_priority = 10

  aws_profile                            = var.aws_profile
  cloudflare_api_token                   = var.cloudflare_api_token
  cloudflare_zone                        = var.cloudflare_zone
  dns_mx_allow_overwrite_records         = var.dns_mx_allow_overwrite_records
  dns_mx_ttl                             = var.dns_mx_ttl
  dns_ttl                                = var.dns_ttl
  dns_validation_allow_overwrite_records = var.dns_validation_allow_overwrite_records
  dns_validation_ttl                     = var.dns_validation_ttl
  domain_name                            = var.domain_name
  inbound_email_table_name               = aws_dynamodb_table.inbound_email.name

  front_end_aws_cloudfront_origin_access_identity_iam_arn = module.front_end_cloudfront.aws_cloudfront_origin_access_identity_iam_arn
}

module "region_us_west_2" {
  source = "../region"

  aws_region  = "us-west-2"
  mx_priority = 20

  aws_profile                            = var.aws_profile
  cloudflare_api_token                   = var.cloudflare_api_token
  cloudflare_zone                        = var.cloudflare_zone
  dns_mx_allow_overwrite_records         = var.dns_mx_allow_overwrite_records
  dns_mx_ttl                             = var.dns_mx_ttl
  dns_ttl                                = var.dns_ttl
  dns_validation_allow_overwrite_records = var.dns_validation_allow_overwrite_records
  dns_validation_ttl                     = var.dns_validation_ttl
  domain_name                            = var.domain_name
  inbound_email_table_name               = aws_dynamodb_table.inbound_email.name

  front_end_aws_cloudfront_origin_access_identity_iam_arn = module.front_end_cloudfront.aws_cloudfront_origin_access_identity_iam_arn
}

module "api_cloudfront" {
  source = "../api_cloudfront"

  aws_profile                            = var.aws_profile
  cloudflare_api_token                   = var.cloudflare_api_token
  cloudflare_zone                        = var.cloudflare_zone
  cloudfront_price_class                 = var.cloudfront_price_class
  dns_allow_overwrite_records            = var.dns_allow_overwrite_records
  dns_ttl                                = var.dns_ttl
  dns_validation_allow_overwrite_records = var.dns_validation_allow_overwrite_records
  dns_validation_ttl                     = var.dns_validation_ttl
  domain_name                            = "api.${var.domain_name}"

  upstream_domains = [
    {
      url  = module.region_us_east_1.api_url
      name = "api-us-east-1",
      path = module.region_us_east_1.api_stage_path
    }, {
      url  = module.region_us_west_2.api_url
      name = "api-us-west-2",
      path = module.region_us_west_2.api_stage_path
    }
  ]
}

module "front_end_cloudfront" {
  source = "../front_end_cloudfront"

  aws_profile                            = var.aws_profile
  cloudflare_api_token                   = var.cloudflare_api_token
  cloudflare_zone                        = var.cloudflare_zone
  cloudfront_price_class                 = var.cloudfront_price_class
  dns_allow_overwrite_records            = var.dns_allow_overwrite_records
  dns_ttl                                = var.dns_ttl
  dns_validation_allow_overwrite_records = var.dns_validation_allow_overwrite_records
  dns_validation_ttl                     = var.dns_validation_ttl
  domain_name                            = var.domain_name
  github_oidc_repository_slug            = var.github_oidc_repository_slug

  upstream_s3_buckets = [
    {
      url  = module.region_us_east_1.front_end_bucket_url,
      name = "s3-us-east-1",
      arn = module.region_us_east_1.front_end_bucket_arn,
    },
    {
      url  = module.region_us_west_2.front_end_bucket_url,
      name = "s3-us-west-2",
      arn = module.region_us_west_2.front_end_bucket_arn,
    }
  ]
}

module "inbound_email_sync_s3_from_east_1" {
  source = "../sync_s3"

  aws_region       = "us-east-1"
  aws_profile      = var.aws_profile
  name             = "InboundEmailFromEast1"
  from_bucket_name = module.region_us_east_1.inbound_email_bucket_name
  from_bucket_arn  = module.region_us_east_1.inbound_email_bucket_arn
  to_bucket_arns   = [module.region_us_west_2.inbound_email_bucket_arn]
}

module "inbound_email_sync_s3_from_west_2" {
  source = "../sync_s3"

  aws_region       = "us-west-2"
  aws_profile      = var.aws_profile
  name             = "InboundEmailFromWest"
  from_bucket_name = module.region_us_west_2.inbound_email_bucket_name
  from_bucket_arn  = module.region_us_west_2.inbound_email_bucket_arn
  to_bucket_arns   = [module.region_us_east_1.inbound_email_bucket_arn]
}

module "front_end_sync_s3_from_east" {
  source = "../sync_s3"

  aws_region       = "us-east-1"
  aws_profile      = var.aws_profile
  name             = "FrontEndFromEast"
  from_bucket_name = module.region_us_east_1.front_end_bucket_name
  from_bucket_arn  = module.region_us_east_1.front_end_bucket_arn
  to_bucket_arns   = [module.region_us_west_2.front_end_bucket_arn]
}
