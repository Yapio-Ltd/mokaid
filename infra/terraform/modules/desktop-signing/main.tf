# This module deliberately has no dependency on the download distribution,
# application services, secret versions, or any customer-managed KMS key.
data "aws_caller_identity" "current" {}

locals {
  role_name           = "mokaid-desktop-signing-stable"
  signing_environment = "desktop-signing-stable"
  trust_policy = {
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ApprovedStableSigningJob"
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = var.github_oidc_provider_arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:environment:${local.signing_environment}"
        }
      }
    }]
  }
  secret_policy = {
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadOnlyStableMacSigningIdentity"
      Effect   = "Allow"
      Action   = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"]
      Resource = var.macos_signing_secret_arn
    }]
  }
}

resource "aws_iam_role" "signer" {
  name                 = local.role_name
  description          = "Approved stable desktop signing only; no publishing or application access."
  assume_role_policy   = jsonencode(local.trust_policy)
  max_session_duration = 3600
  tags = merge(var.tags, {
    Project     = "mokaid"
    Owner       = "Yapio"
    ManagedBy   = "Terraform"
    Component   = "desktop-signing"
    Channel     = "stable"
    Environment = "prod"
  })

  lifecycle {
    precondition {
      condition     = split(":", var.github_oidc_provider_arn)[4] == data.aws_caller_identity.current.account_id && split(":", var.macos_signing_secret_arn)[4] == data.aws_caller_identity.current.account_id
      error_message = "The provider, signing secret and Terraform caller must belong to the same AWS account."
    }
  }
}

resource "aws_iam_role_policy" "signer" {
  name   = "read-stable-macos-signing"
  role   = aws_iam_role.signer.id
  policy = jsonencode(local.secret_policy)
}
