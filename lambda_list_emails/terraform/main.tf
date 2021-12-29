locals {
  list_emails_lambda_name = "ListEmails"
  aws_account_id = data.aws_caller_identity.current.account_id
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "lambda_list_emails" {
  name = "ListEmailsLambda-${var.aws_region}"

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
}

resource "aws_iam_policy" "lambda_list_emails" {
  name = "LambdaListEmails-${var.aws_region}"

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
                "arn:aws:logs:${var.aws_region}:${local.aws_account_id}:log-group:/aws/lambda/${local.list_emails_lambda_name}:*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:Scan"
            ],
            "Resource": "${var.inbound_email_table_arn}"
        }
    ]
}
POLICY
}

data "archive_file" "lambda_list_emails" {
  type        = "zip"
  source_file = "${path.module}/../main.py"
  output_path = "${path.module}/main.zip"
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
      INCOMING_EMAIL_TABLE = var.inbound_email_table_name
    }
  }
}

resource "aws_lambda_permission" "allow_api_gateway_to_list_emails" {
  statement_id   = "GiveApiGatewayPermissionToInvokeFunction"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.list_emails.function_name
  principal      = "apigateway.amazonaws.com"
  source_account = local.aws_account_id
  source_arn     = "${var.aws_api_gateway_execution_arn}/*/*/*"
}

resource "aws_cloudwatch_log_group" "list_emails_lambda" {
  name              = "/aws/lambda/${local.list_emails_lambda_name}"
  retention_in_days = 90
}
