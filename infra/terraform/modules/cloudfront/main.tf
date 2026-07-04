variable "name" {
  type = string
}

variable "app_bucket_id" {
  description = "S3 bucket serving the SPA build"
  type        = string
}

variable "app_bucket_arn" {
  type = string
}

variable "app_bucket_domain_name" {
  type = string
}

variable "assets_bucket_id" {
  description = "S3 bucket serving 3D assets (GLB/KTX2)"
  type        = string
}

variable "assets_bucket_arn" {
  type = string
}

variable "assets_bucket_domain_name" {
  type = string
}

variable "aliases" {
  type    = list(string)
  default = []
}

variable "acm_certificate_arn" {
  description = "Certificate in us-east-1 for custom domains. Empty = default CF cert."
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_cloudfront_origin_access_control" "this" {
  name                              = var.name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

locals {
  app_origin_id    = "app-s3"
  assets_origin_id = "assets-s3"
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.name} — SPA + 3D assets"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  aliases             = var.aliases
  http_version        = "http2and3"

  origin {
    domain_name              = var.app_bucket_domain_name
    origin_id                = local.app_origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  origin {
    domain_name              = var.assets_bucket_domain_name
    origin_id                = local.assets_origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  default_cache_behavior {
    target_origin_id       = local.app_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS managed CachingOptimized policy
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  ordered_cache_behavior {
    path_pattern           = "/assets3d/*"
    target_origin_id       = local.assets_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # SPA routing: serve index.html for unknown paths
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = var.acm_certificate_arn == ""
    acm_certificate_arn            = var.acm_certificate_arn != "" ? var.acm_certificate_arn : null
    ssl_support_method             = var.acm_certificate_arn != "" ? "sni-only" : null
    minimum_protocol_version       = var.acm_certificate_arn != "" ? "TLSv1.2_2021" : null
  }

  tags = var.tags
}

data "aws_iam_policy_document" "app_bucket" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${var.app_bucket_arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "app" {
  bucket = var.app_bucket_id
  policy = data.aws_iam_policy_document.app_bucket.json
}

data "aws_iam_policy_document" "assets_bucket" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${var.assets_bucket_arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "assets" {
  bucket = var.assets_bucket_id
  policy = data.aws_iam_policy_document.assets_bucket.json
}

output "distribution_id" {
  value = aws_cloudfront_distribution.this.id
}

output "distribution_domain_name" {
  value = aws_cloudfront_distribution.this.domain_name
}
