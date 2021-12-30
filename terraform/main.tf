provider "aws" {
  region  = "us-east-1"
  profile = var.aws_profile
}

resource "aws_dynamodb_table" "inbound_email" {
  name           = "InboundEmail"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "emailAddress"
  range_key      = "receivedAt"
  stream_enabled = true
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

  #  TODO: Consider swapping with primary index, so that body can be removed from projection?
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

  aws_region = "us-east-1"

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
  mx_priority                            = 10
}

module "region_us_west_2" {
  source = "../region"

  aws_region = "us-west-2"

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
  mx_priority                            = 20
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
