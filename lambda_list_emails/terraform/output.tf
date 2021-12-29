output "lambda_invoke_arn" {
  value = aws_lambda_function.list_emails.invoke_arn
}
