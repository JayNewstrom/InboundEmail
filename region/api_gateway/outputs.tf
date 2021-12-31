output "api_execution_arn" {
  value = aws_apigatewayv2_api.api.execution_arn
}
output "api_url" {
  value = aws_apigatewayv2_api.api.api_endpoint
}
output "stage_path" {
  value = aws_apigatewayv2_stage.api_production.name
}
