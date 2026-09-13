# This adds the distribution boundary without changing the existing web/API
# services. Enable only after reviewing the AWS account, public DNS zone and plan.
variable "desktop_downloads_enabled" {
  description = "Provision native downloads and channel-scoped GitHub roles. Does not publish any release."
  type        = bool
  default     = false
}

variable "desktop_downloads_certificate_arn" {
  description = "Optional existing validated ACM certificate for downloads.mokaid.com in us-east-1. Otherwise create a DNS-validated certificate."
  type        = string
  default     = null
  validation {
    condition     = var.desktop_downloads_certificate_arn == null || can(regex("^arn:aws:acm:us-east-1:[0-9]{12}:certificate/", var.desktop_downloads_certificate_arn))
    error_message = "CloudFront requires an ACM certificate in us-east-1."
  }
}

variable "desktop_signing_secret_arns" {
  description = "Existing Mac/Windows signing-secret ARNs grouped by stable/beta. Empty leaves signing roles unprovisioned; no secret value enters Terraform."
  type        = map(list(string))
  default     = {}
}

variable "desktop_downloads_route53_zone_id" {
  description = "Optional existing public Route53 zone. Null uses external DNS and emits records without taking ownership of the zone."
  type        = string
  default     = null
}

variable "desktop_downloads_external_dns_ready" {
  description = "After adding the emitted ACM CNAME at the external DNS provider, enable certificate validation and CloudFront provisioning. AWS still verifies the certificate."
  type        = bool
  default     = false
}

locals {
  desktop_distribution_ready = var.desktop_downloads_enabled && (var.desktop_downloads_certificate_arn != null || var.desktop_downloads_route53_zone_id != null || var.desktop_downloads_external_dns_ready)
}

variable "desktop_signing_kms_key_arns" {
  description = "Optional customer-managed secret-encryption KMS keys grouped by stable/beta."
  type        = map(list(string))
  default     = {}
}

provider "aws" {
  alias  = "desktop_certificates"
  region = "us-east-1"
  default_tags {
    tags = {
      Project     = "mokaid"
      Owner       = "Yapio"
      ManagedBy   = "Terraform"
      Environment = "prod"
      Component   = "desktop-downloads"
    }
  }
}

data "aws_caller_identity" "desktop" {
  count = var.desktop_downloads_enabled ? 1 : 0
}

# The bootstrap stack owns the account-wide GitHub OIDC provider. Look it up;
# never create another provider or take ownership of the bootstrap resource.
data "aws_iam_openid_connect_provider" "desktop_github" {
  count = var.desktop_downloads_enabled ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

resource "aws_acm_certificate" "desktop" {
  count             = var.desktop_downloads_enabled && var.desktop_downloads_certificate_arn == null ? 1 : 0
  provider          = aws.desktop_certificates
  domain_name       = "downloads.${var.app_domain}"
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
    prevent_destroy       = true
  }
}

resource "aws_route53_record" "desktop_certificate" {
  for_each = var.desktop_downloads_enabled && var.desktop_downloads_certificate_arn == null && var.desktop_downloads_route53_zone_id != null ? {
    for option in aws_acm_certificate.desktop[0].domain_validation_options : option.domain_name => option
  } : {}
  zone_id = var.desktop_downloads_route53_zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 300
}

resource "aws_acm_certificate_validation" "desktop" {
  count                   = local.desktop_distribution_ready && var.desktop_downloads_certificate_arn == null ? 1 : 0
  provider                = aws.desktop_certificates
  certificate_arn         = aws_acm_certificate.desktop[0].arn
  validation_record_fqdns = [for option in aws_acm_certificate.desktop[0].domain_validation_options : option.resource_record_name]
  depends_on              = [aws_route53_record.desktop_certificate]
}

module "desktop_downloads" {
  count                    = local.desktop_distribution_ready ? 1 : 0
  source                   = "../../modules/desktop-downloads"
  bucket_name              = "mokaid-desktop-downloads-${data.aws_caller_identity.desktop[0].account_id}"
  domain_name              = "downloads.${var.app_domain}"
  route53_zone_id          = var.desktop_downloads_route53_zone_id
  acm_certificate_arn      = var.desktop_downloads_certificate_arn != null ? var.desktop_downloads_certificate_arn : aws_acm_certificate_validation.desktop[0].certificate_arn
  github_oidc_provider_arn = data.aws_iam_openid_connect_provider.desktop_github[0].arn
  github_repository        = "Yapio-Ltd/mokaid"
  signing_secret_arns      = var.desktop_signing_secret_arns
  signing_kms_key_arns     = var.desktop_signing_kms_key_arns
  tags = {
    Environment = "prod"
    Component   = "desktop-downloads"
  }
}

output "desktop_downloads" {
  description = "Non-secret configuration for protected GitHub desktop environments. Null until explicitly enabled."
  value = local.desktop_distribution_ready ? {
    MOKAID_AWS_REGION                = var.aws_region
    MOKAID_DOWNLOADS_BUCKET          = module.desktop_downloads[0].bucket_name
    MOKAID_DOWNLOADS_DISTRIBUTION_ID = module.desktop_downloads[0].distribution_id
    publish_role_arns                = module.desktop_downloads[0].publish_role_arns
    signing_role_arns                = module.desktop_downloads[0].signing_role_arns
    external_dns_cname               = module.desktop_downloads[0].cloudfront_domain
    domain                           = "downloads.${var.app_domain}"
  } : null
}

output "desktop_downloads_certificate_dns_records" {
  description = "Add these CNAME records at the authoritative external DNS provider, then enable desktop_downloads_external_dns_ready. These records are public, not secrets."
  value = var.desktop_downloads_enabled && var.desktop_downloads_certificate_arn == null ? [
    for option in aws_acm_certificate.desktop[0].domain_validation_options : {
      name = option.resource_record_name, type = option.resource_record_type, value = option.resource_record_value
    }
  ] : []
}
