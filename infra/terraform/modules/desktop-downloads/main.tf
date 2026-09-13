terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.100" }
  }
}

variable "bucket_name" {
  description = "Globally unique private S3 bucket for immutable installers and channel feeds."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "Use a valid lowercase S3 bucket name, 3–63 characters."
  }
}
variable "domain_name" {
  description = "HTTPS hostname served by this distribution."
  type        = string
  default     = "downloads.mokaid.com"
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}$", var.domain_name))
    error_message = "Use a DNS hostname without a scheme, path or wildcard."
  }
}
variable "acm_certificate_arn" {
  description = "Validated certificate for downloads.mokaid.com in us-east-1."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:acm:us-east-1:[0-9]{12}:certificate/", var.acm_certificate_arn))
    error_message = "The CloudFront certificate must be in us-east-1."
  }
}
variable "route53_zone_id" {
  description = "Existing Route53 zone; null leaves DNS at the external provider and exports the CloudFront hostname."
  type        = string
  default     = null
}
variable "github_oidc_provider_arn" {
  description = "Existing token.actions.githubusercontent.com IAM OIDC provider."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn))
    error_message = "Pass the existing GitHub Actions OIDC provider ARN."
  }
}
variable "github_repository" {
  description = "Repository allowed to assume the protected environment roles."
  type        = string
  default     = "Yapio-Ltd/mokaid"
}
variable "signing_secret_arns" {
  description = "Existing Secrets Manager ARNs by channel; create values outside Terraform state."
  type        = map(list(string))
  validation {
    condition     = alltrue([for channel in keys(var.signing_secret_arns) : contains(["stable", "beta"], channel)])
    error_message = "Only stable and beta signing channels are supported."
  }
  validation {
    condition = alltrue([for arns in values(var.signing_secret_arns) : length(arns) > 0 && alltrue([
      for arn in arns : can(regex("^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[^*?]+$", arn))
    ])])
    error_message = "Signing roles require exact existing secret ARNs; no empty list or wildcard."
  }
}
variable "signing_kms_key_arns" {
  description = "Optional KMS keys for those signing secrets, scoped by channel."
  type        = map(list(string))
  default     = {}
}
variable "tags" {
  description = "Tags merged with the provider defaults on supported resources."
  type        = map(string)
  default     = {}
}

resource "aws_s3_bucket" "downloads" {
  bucket = var.bucket_name
  tags   = var.tags
  lifecycle { prevent_destroy = true }
}
resource "aws_s3_bucket_versioning" "downloads" {
  bucket = aws_s3_bucket.downloads.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "downloads" {
  bucket = aws_s3_bucket.downloads.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_public_access_block" "downloads" {
  bucket                  = aws_s3_bucket.downloads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_ownership_controls" "downloads" {
  bucket = aws_s3_bucket.downloads.id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_object" "unavailable" {
  bucket        = aws_s3_bucket.downloads.id
  key           = "unavailable.json"
  content       = jsonencode({ error = "release_not_available" })
  content_type  = "application/json"
  cache_control = "public,max-age=60"
}
resource "aws_cloudfront_origin_access_control" "downloads" {
  name                              = "mokaid-desktop-downloads"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}
resource "aws_cloudfront_response_headers_policy" "downloads" {
  name = "mokaid-desktop-downloads"
  cors_config {
    access_control_allow_credentials = false
    access_control_allow_headers { items = ["*"] }
    access_control_allow_methods { items = ["GET", "HEAD", "OPTIONS"] }
    access_control_allow_origins { items = ["https://mokaid.com", "https://www.mokaid.com"] }
    access_control_expose_headers { items = ["Content-Length", "Content-Type", "ETag"] }
    access_control_max_age_sec = 600
    origin_override            = true
  }
  security_headers_config {
    content_type_options { override = true }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = false
      override                   = true
    }
    referrer_policy {
      referrer_policy = "no-referrer"
      override        = true
    }
  }
}
resource "aws_cloudfront_cache_policy" "feeds" {
  name        = "mokaid-desktop-update-feeds"
  min_ttl     = 0
  default_ttl = 60
  max_ttl     = 60
  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
    cookies_config { cookie_behavior = "none" }
    headers_config { header_behavior = "none" }
    query_strings_config { query_string_behavior = "none" }
  }
}
resource "aws_cloudfront_distribution" "downloads" {
  enabled         = true
  is_ipv6_enabled = true
  aliases         = [var.domain_name]
  price_class     = "PriceClass_100"
  http_version    = "http2and3"
  comment         = "Signed native Mokaid releases and update feeds"
  origin {
    domain_name              = aws_s3_bucket.downloads.bucket_regional_domain_name
    origin_id                = "signed-releases"
    origin_access_control_id = aws_cloudfront_origin_access_control.downloads.id
  }
  default_cache_behavior {
    target_origin_id           = "signed-releases"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    response_headers_policy_id = aws_cloudfront_response_headers_policy.downloads.id
  }
  dynamic "ordered_cache_behavior" {
    for_each = toset(["stable/*", "beta/*"])
    content {
      path_pattern               = ordered_cache_behavior.value
      target_origin_id           = "signed-releases"
      viewer_protocol_policy     = "redirect-to-https"
      allowed_methods            = ["GET", "HEAD", "OPTIONS"]
      cached_methods             = ["GET", "HEAD"]
      compress                   = true
      cache_policy_id            = aws_cloudfront_cache_policy.feeds.id
      response_headers_policy_id = aws_cloudfront_response_headers_policy.downloads.id
    }
  }
  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/unavailable.json"
    error_caching_min_ttl = 60
  }
  restrictions {
    geo_restriction { restriction_type = "none" }
  }
  viewer_certificate {
    acm_certificate_arn      = var.acm_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
  tags = var.tags
}
resource "aws_route53_record" "downloads" {
  for_each = var.route53_zone_id == null ? toset([]) : toset(["A", "AAAA"])
  zone_id  = var.route53_zone_id
  name     = var.domain_name
  type     = each.value
  alias {
    name                   = aws_cloudfront_distribution.downloads.domain_name
    zone_id                = aws_cloudfront_distribution.downloads.hosted_zone_id
    evaluate_target_health = false
  }
}
data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "CloudFrontReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.downloads.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.downloads.arn]
    }
  }
  statement {
    sid       = "DenyUnencryptedTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.downloads.arn, "${aws_s3_bucket.downloads.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
  statement {
    sid       = "ImmutableReleaseObjectsRequireConditionalCreate"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.downloads.arn}/releases/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Null"
      variable = "s3:if-none-match"
      values   = ["true"]
    }
  }
}
resource "aws_s3_bucket_policy" "downloads" {
  bucket = aws_s3_bucket.downloads.id
  policy = data.aws_iam_policy_document.bucket.json
}

locals { channels = toset(["stable", "beta"]) }
data "aws_iam_policy_document" "publish_trust" {
  for_each = local.channels
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:environment:desktop-public-${each.key}"]
    }
  }
}
resource "aws_iam_role" "publisher" {
  for_each           = local.channels
  name               = "mokaid-desktop-publish-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.publish_trust[each.key].json
  tags               = var.tags
}
resource "aws_iam_role_policy" "publisher" {
  for_each = local.channels
  role     = aws_iam_role.publisher[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    # ListBucket also lets HeadObject distinguish absent (404) from forbidden
    # (403) before a conditional upload. Only public artifact names are listable.
    { Effect = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.downloads.arn },
    { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = [
      "${aws_s3_bucket.downloads.arn}/releases/*", "${aws_s3_bucket.downloads.arn}/${each.key}/*"
    ] },
    { Effect = "Allow", Action = ["cloudfront:CreateInvalidation"], Resource = aws_cloudfront_distribution.downloads.arn }
  ] })
}
data "aws_iam_policy_document" "signing_trust" {
  for_each = var.signing_secret_arns
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:environment:desktop-signing-${each.key}"]
    }
  }
}
resource "aws_iam_role" "signer" {
  for_each           = var.signing_secret_arns
  name               = "mokaid-desktop-sign-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.signing_trust[each.key].json
  tags               = var.tags
}
resource "aws_iam_role_policy" "signer" {
  for_each = var.signing_secret_arns
  role     = aws_iam_role.signer[each.key].id
  policy = jsonencode({ Version = "2012-10-17", Statement = concat([
    { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = each.value }
    ], length(lookup(var.signing_kms_key_arns, each.key, [])) > 0 ? [
    { Effect = "Allow", Action = ["kms:Decrypt"], Resource = var.signing_kms_key_arns[each.key],
      Condition = { StringEquals = {
        "kms:ViaService"                  = distinct([for arn in each.value : "secretsmanager.${split(":", arn)[3]}.amazonaws.com"])
        "kms:EncryptionContext:SecretARN" = each.value
    } } }
  ] : []) })
}

output "bucket_name" {
  description = "Private downloads bucket name."
  value       = aws_s3_bucket.downloads.id
}
output "distribution_id" {
  description = "CloudFront distribution ID for narrowly scoped feed invalidation."
  value       = aws_cloudfront_distribution.downloads.id
}
output "cloudfront_domain" {
  description = "CNAME target when authoritative DNS is managed outside Route53."
  value       = aws_cloudfront_distribution.downloads.domain_name
}
output "publish_role_arns" {
  description = "Non-secret OIDC publisher role ARNs by protected channel environment."
  value       = { for key, role in aws_iam_role.publisher : key => role.arn }
}
output "signing_role_arns" {
  description = "Non-secret OIDC signer role ARNs; absent until secret ARNs are supplied."
  value       = { for key, role in aws_iam_role.signer : key => role.arn }
}
