provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

data "aws_iam_policy_document" "bucket_policy" {
  statement {
    sid = "1"

    actions = [
      "s3:GetObject",
    ]

    resources = [
      "arn:aws:s3:::${var.bucket_name}/*",
    ]

    principals {
      type = "AWS"

      identifiers = [
        var.aws_cloudfront_origin_access_identity_iam_arn,
      ]
    }
  }
}

resource "aws_s3_bucket" "bucket" {
  bucket = var.bucket_name
  acl    = "private"
  policy = data.aws_iam_policy_document.bucket_policy.json

  versioning {
    enabled = true
  }

  lifecycle {
    ignore_changes = [
      replication_configuration
    ]
  }
}

resource "aws_s3_bucket_public_access_block" "bucket" {
  bucket = aws_s3_bucket.bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
