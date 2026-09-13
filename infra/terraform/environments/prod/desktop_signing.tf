# Separate from desktop_downloads: CloudFront readiness must not be a dependency
# of the protected signing identity. Keep off until this exact IAM grant is approved.
variable "desktop_stable_signing_enabled" {
  description = "Provision the reviewed stable macOS signing role only. Does not sign, publish or activate desktop-only mode."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = !var.desktop_stable_signing_enabled || !contains(keys(var.desktop_signing_secret_arns), "stable")
    error_message = "Stable signing must have one owner: leave desktop_signing_secret_arns.stable absent when this independent module is enabled."
  }
}

data "aws_iam_openid_connect_provider" "desktop_stable_signing" {
  count = var.desktop_stable_signing_enabled ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

module "desktop_stable_signing" {
  count                    = var.desktop_stable_signing_enabled ? 1 : 0
  source                   = "../../modules/desktop-signing"
  github_oidc_provider_arn = data.aws_iam_openid_connect_provider.desktop_stable_signing[0].arn
  github_repository        = "Yapio-Ltd/mokaid"
  macos_signing_secret_arn = "arn:aws:secretsmanager:il-central-1:660601648321:secret:mokaid/desktop/stable/macos-signing-8pPQkT"
}

output "desktop_stable_signing" {
  description = "Public identifiers for the stable signing environment; null while provisioning is disabled."
  value = var.desktop_stable_signing_enabled ? {
    MOKAID_AWS_REGION               = "il-central-1"
    MOKAID_SIGNING_AWS_ROLE_ARN     = module.desktop_stable_signing[0].signing_role_arn
    MOKAID_MACOS_SIGNING_SECRET_ARN = module.desktop_stable_signing[0].macos_signing_secret_arn
  } : null
}
