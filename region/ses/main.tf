terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 3.0"
    }
  }
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
  value    = "inbound-smtp.${var.aws_region}.amazonaws.com"
  ttl      = var.dns_mx_ttl
  priority = var.mx_priority
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
    bucket_name = var.bucket_name
    position    = 1
  }

  lambda_action {
    function_arn    = var.lambda_function_arn
    invocation_type = "RequestResponse"
    position        = 2
  }
}

resource "aws_ses_active_receipt_rule_set" "inbound_email" {
  rule_set_name = "inbound-email"

  depends_on = [aws_ses_receipt_rule_set.inbound_email]
}
