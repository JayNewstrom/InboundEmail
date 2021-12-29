locals {
  inbound_email_lambda_name = "SesInbound"
  aws_account_id = data.aws_caller_identity.current.account_id
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
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
                "arn:aws:logs:${var.aws_region}:${local.aws_account_id}:log-group:/aws/lambda/${local.inbound_email_lambda_name}:*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": "dynamodb:PutItem",
            "Resource": "${var.inbound_email_table_arn}"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3-object-lambda:List*",
                "s3-object-lambda:Get*"
            ],
            "Resource": "${var.s3_bucket_arn}/*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:Get*",
                "s3:List*"
            ],
            "Resource": "${var.s3_bucket_arn}/*"
        }
    ]
}
POLICY
}

data "archive_file" "lambda_ses_inbound" {
  type        = "zip"
  source_file = "${path.module}/../main.py"
  output_path = "${path.module}/main.zip"
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
      INCOMING_EMAIL_BUCKET = var.s3_bucket_name
      INCOMING_EMAIL_TABLE  = var.inbound_email_table_name
    }
  }
}

resource "aws_lambda_permission" "allow_ses" {
  statement_id   = "GiveSESPermissionToInvokeFunction"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.ses_inbound.function_name
  principal      = "ses.amazonaws.com"
  source_arn     = "arn:aws:ses:${var.aws_region}:${local.aws_account_id}:receipt-rule-set/inbound-email:receipt-rule/inbound-email"
  source_account = local.aws_account_id
}

resource "aws_cloudwatch_log_group" "inbound_email_lambda" {
  name              = "/aws/lambda/${local.inbound_email_lambda_name}"
  retention_in_days = 90
}
