# Only secret metadata is managed here. The channel update seed is installed by
# a trusted operator outside Terraform; no private value enters this state.
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  role_name = "mokaid-desktop-signing-windows-stable"
  tags = merge(var.tags, {
    Project     = "mokaid"
    Owner       = "Yapio"
    ManagedBy   = "Terraform"
    Component   = "desktop-windows-signing"
    Channel     = "stable"
    Environment = "prod"
  })
}

resource "aws_secretsmanager_secret" "updates" {
  name                    = "mokaid/desktop/stable/windows-updates"
  description             = "Stable desktop update_ed25519_seed only; no Apple or Azure credentials."
  recovery_window_in_days = 30
  tags                    = local.tags

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = data.aws_region.current.name == "il-central-1"
      error_message = "The stable Windows update secret belongs in il-central-1."
    }
  }
}

resource "aws_iam_role" "signer" {
  name                 = local.role_name
  description          = "Approved stable Windows signing job; reads only its channel update seed."
  max_session_duration = 3600
  tags                 = local.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ApprovedStableWindowsSigningJob"
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = var.github_oidc_provider_arn }
      Condition = { StringEquals = {
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:environment:desktop-signing-stable"
      } }
    }]
  })

  lifecycle {
    precondition {
      condition     = split(":", var.github_oidc_provider_arn)[4] == data.aws_caller_identity.current.account_id
      error_message = "The GitHub provider and Terraform caller must belong to the same AWS account."
    }
  }
}

resource "aws_iam_role_policy" "signer" {
  name = "read-stable-windows-updates"
  role = aws_iam_role.signer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadOnlyStableWindowsUpdateSeed"
      Effect   = "Allow"
      Action   = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.updates.arn
    }]
  })
}
