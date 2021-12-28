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
  inbound_email_lambda_name = "SesInbound"
  inbound_email_bucket_name = var.domain_name
  inbound_email_table_name  = "InboundEmail"
  aws_account_id            = data.aws_caller_identity.current.account_id
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "lambda_ses_inbound" {
  name = "SesInboundLambda"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY

  managed_policy_arns = [aws_iam_policy.lambda_ses_inbound.arn]

  tags = var.aws_tags
}

resource "aws_iam_policy" "lambda_ses_inbound" {
  name = "LambdaSesInbound"

  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": [
                "arn:aws:logs:us-east-1:${local.aws_account_id}:log-group:/aws/lambda/${local.inbound_email_lambda_name}:*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": "dynamodb:PutItem",
            "Resource": "${aws_dynamodb_table.inbound_email.arn}"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3-object-lambda:List*",
                "s3-object-lambda:Get*"
            ],
            "Resource": "${aws_s3_bucket.primary_s3_bucket.arn}/*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:Get*",
                "s3:List*"
            ],
            "Resource": "${aws_s3_bucket.primary_s3_bucket.arn}/*"
        }
    ]
}
POLICY

  tags = var.aws_tags
}

data "archive_file" "lambda_ses_inbound" {
  type        = "zip"
  source_file = "../lambda_ses_inbound/main.py"
  output_path = "${path.module}/lambda_ses_inbound.zip"
}

resource "aws_lambda_function" "ses_inbound" {
  function_name    = local.inbound_email_lambda_name
  role             = aws_iam_role.lambda_ses_inbound.arn
  handler          = "main.lambda_handler"
  runtime          = "python3.9"
  filename         = data.archive_file.lambda_ses_inbound.output_path
  source_code_hash = data.archive_file.lambda_ses_inbound.output_base64sha256
  publish          = true
  environment {
    variables = {
      INCOMING_EMAIL_BUCKET = local.inbound_email_bucket_name
      INCOMING_EMAIL_TABLE  = local.inbound_email_table_name
    }
  }

  tags = var.aws_tags
}

resource "aws_lambda_permission" "allow_ses" {
  statement_id   = "GiveSESPermissionToInvokeFunction"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.ses_inbound.function_name
  principal      = "ses.amazonaws.com"
  source_arn     = "arn:aws:ses:us-east-1:${local.aws_account_id}:receipt-rule-set/inbound-email:receipt-rule/inbound-email"
  source_account = local.aws_account_id
}

resource "aws_cloudwatch_log_group" "inbound_email_lambda" {
  name              = "/aws/lambda/${local.inbound_email_lambda_name}"
  retention_in_days = 90

  tags = var.aws_tags
}

resource "aws_s3_bucket" "primary_s3_bucket" {
  bucket = local.inbound_email_bucket_name
  acl    = "private"
  policy = <<POLICY
  {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowSESPuts",
            "Effect": "Allow",
            "Principal": {
                "Service": "ses.amazonaws.com"
            },
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::${local.inbound_email_bucket_name}/*",
            "Condition": {
                "StringEquals": {
                    "AWS:SourceAccount": "${local.aws_account_id}"
                }
            }
        }
    ]
}
POLICY

  tags = var.aws_tags

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}

resource "aws_s3_bucket_public_access_block" "bucket" {
  bucket = aws_s3_bucket.primary_s3_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
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

resource "aws_ses_domain_identity" "inbound_email" {
  domain = var.domain_name
}

resource "aws_ses_domain_dkim" "inbound_email" {
  domain = aws_ses_domain_identity.inbound_email.domain
}

resource "cloudflare_record" "validation" {
  count = 3

  zone_id = var.cloudflare_zone
  name    = "${element(aws_ses_domain_dkim.inbound_email.dkim_tokens, count.index)}._domainkey.${var.domain_name}"
  type    = "CNAME"
  value   = "${element(aws_ses_domain_dkim.inbound_email.dkim_tokens, count.index)}.dkim.amazonses.com"
  ttl     = var.dns_validation_ttl
  proxied = false

  allow_overwrite = var.dns_validation_allow_overwrite_records

  depends_on = [aws_ses_domain_dkim.inbound_email]
}

resource "cloudflare_record" "mx" {
  zone_id  = var.cloudflare_zone
  name     = var.domain_name
  type     = "MX"
  value    = "inbound-smtp.us-east-1.amazonaws.com"
  ttl      = var.dns_mx_ttl
  priority = 10
  proxied  = false

  allow_overwrite = var.dns_mx_allow_overwrite_records
}

resource "aws_ses_receipt_rule_set" "inbound_email" {
  rule_set_name = "inbound-email"
}

resource "aws_ses_receipt_rule" "inbound_email" {
  name          = "inbound-email"
  rule_set_name = "inbound-email"
  recipients    = []
  enabled       = true
  scan_enabled  = true

  s3_action {
    bucket_name = local.inbound_email_bucket_name
    position    = 1
  }

  lambda_action {
    function_arn    = aws_lambda_function.ses_inbound.arn
    invocation_type = "RequestResponse"
    position        = 2
  }

  depends_on = [
    aws_s3_bucket.primary_s3_bucket, aws_lambda_permission.allow_ses
  ]
}

resource "aws_ses_active_receipt_rule_set" "inbound_email" {
  rule_set_name = "inbound-email"

  depends_on = [aws_ses_receipt_rule_set.inbound_email]
}
