# Independent of Apple signing, Azure, CloudFront and application services.
variable "desktop_windows_signing_enabled" {
  description = "Provision stable Windows update-secret metadata and its separate read-only signing role."
  type        = bool
  default     = false
  nullable    = false
}

data "aws_iam_openid_connect_provider" "desktop_windows_signing" {
  count = var.desktop_windows_signing_enabled ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

module "desktop_windows_signing" {
  count                    = var.desktop_windows_signing_enabled ? 1 : 0
  source                   = "../../modules/desktop-windows-signing"
  github_oidc_provider_arn = data.aws_iam_openid_connect_provider.desktop_windows_signing[0].arn
  github_repository        = "Yapio-Ltd/mokaid"
}

output "desktop_windows_signing" {
  description = "Public identifiers only; null while provisioning is disabled."
  value = var.desktop_windows_signing_enabled ? {
    MOKAID_AWS_REGION                   = "il-central-1"
    MOKAID_WINDOWS_SIGNING_AWS_ROLE_ARN = module.desktop_windows_signing[0].signing_role_arn
    MOKAID_WINDOWS_SIGNING_SECRET_ARN   = module.desktop_windows_signing[0].windows_signing_secret_arn
  } : null
}
