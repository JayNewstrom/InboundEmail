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

  list_emails_lambda_name = "ListEmails"

  api_domain_name = "api.${var.domain_name}"

  aws_account_id = data.aws_caller_identity.current.account_id

  api_validation_domains = distinct(
  [
  for k, v in aws_acm_certificate.api_certificate[0].domain_validation_options : merge(
  tomap(v), { domain_name = replace(v.domain_name, "*.", "") }
  )
  ]
  )
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

resource "aws_ses_domain_identity" "inbound_email" {
  domain = var.domain_name
}

resource "aws_ses_domain_dkim" "inbound_email" {
  domain = aws_ses_domain_identity.inbound_email.domain
}

resource "cloudflare_record" "ses_validation" {
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

resource "aws_iam_role" "lambda_list_emails" {
  name = "ListEmailsLambda"

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

  managed_policy_arns = [aws_iam_policy.lambda_list_emails.arn]

  tags = var.aws_tags
}

resource "aws_iam_policy" "lambda_list_emails" {
  name = "LambdaListEmails"

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
                "arn:aws:logs:us-east-1:${local.aws_account_id}:log-group:/aws/lambda/${local.list_emails_lambda_name}:*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:Scan"
            ],
            "Resource": "${aws_dynamodb_table.inbound_email.arn}"
        }
    ]
}
POLICY

  tags = var.aws_tags
}

data "archive_file" "lambda_list_emails" {
  type        = "zip"
  source_file = "../lambda_list_emails/main.py"
  output_path = "${path.module}/lambda_list_emails.zip"
}

resource "aws_lambda_function" "list_emails" {
  function_name    = local.list_emails_lambda_name
  role             = aws_iam_role.lambda_list_emails.arn
  handler          = "main.lambda_handler"
  runtime          = "python3.9"
  filename         = data.archive_file.lambda_list_emails.output_path
  source_code_hash = data.archive_file.lambda_list_emails.output_base64sha256
  publish          = true
  memory_size      = 512

  environment {
    variables = {
      INCOMING_EMAIL_TABLE = local.inbound_email_table_name
    }
  }

  tags = var.aws_tags
}

resource "aws_lambda_permission" "allow_api_gateway_to_list_emails" {
  statement_id   = "GiveApiGatewayPermissionToInvokeFunction"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.list_emails.function_name
  principal      = "apigateway.amazonaws.com"
  source_account = local.aws_account_id
  source_arn     = "${aws_apigatewayv2_api.api.execution_arn}/*/*/*"
}

resource "aws_cloudwatch_log_group" "list_emails_lambda" {
  name              = "/aws/lambda/${local.list_emails_lambda_name}"
  retention_in_days = 90

  tags = var.aws_tags
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
  api_id = aws_apigatewayv2_api.api.id
  name   = "production"
  deployment_id = aws_apigatewayv2_deployment.api.id
}

resource "aws_apigatewayv2_domain_name" "api" {
  domain_name = local.api_domain_name

  domain_name_configuration {
    certificate_arn = aws_acm_certificate.api_certificate[0].arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  depends_on = [cloudflare_record.api_validation]
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
  integration_uri    = aws_lambda_function.list_emails.invoke_arn
}

resource "aws_apigatewayv2_route" "api_list_emails" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /emails"

  target = "integrations/${aws_apigatewayv2_integration.api_list_emails.id}"
}
