# Offline tests against the generated policies: no credentials or AWS calls.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "660601648321" }
  }
  mock_data "aws_region" {
    defaults = { name = "il-central-1" }
  }
}

override_resource {
  target = aws_secretsmanager_secret.updates
  values = {
    arn = "arn:aws:secretsmanager:il-central-1:660601648321:secret:mokaid/desktop/stable/windows-updates-a1B2c3"
  }
  override_during = plan
}

variables {
  github_oidc_provider_arn = "arn:aws:iam::660601648321:oidc-provider/token.actions.githubusercontent.com"
  github_repository        = "Yapio-Ltd/mokaid"
}

run "exact_stable_windows_identity_and_trust" {
  command = plan
  assert {
    condition     = aws_iam_role.signer.name == "mokaid-desktop-signing-windows-stable" && aws_iam_role.signer.max_session_duration == 3600
    error_message = "Windows must use a separate fixed role with a one-hour session limit."
  }
  assert {
    condition = jsondecode(aws_iam_role.signer.assume_role_policy) == jsondecode(jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "ApprovedStableWindowsSigningJob"
        Effect    = "Allow"
        Action    = "sts:AssumeRoleWithWebIdentity"
        Principal = { Federated = var.github_oidc_provider_arn }
        Condition = { StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:Yapio-Ltd/mokaid:environment:desktop-signing-stable"
        } }
      }]
    }))
    error_message = "Only the exact stable protected environment and STS audience may assume this role."
  }
}

run "only_read_operations_on_created_windows_secret" {
  command = plan
  assert {
    condition = jsondecode(aws_iam_role_policy.signer.policy) == jsondecode(jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid      = "ReadOnlyStableWindowsUpdateSeed"
        Effect   = "Allow"
        Action   = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:il-central-1:660601648321:secret:mokaid/desktop/stable/windows-updates-a1B2c3"
      }]
    }))
    error_message = "The policy may only read the exact created Windows secret, never Apple, application, beta, wildcard, write or publishing resources."
  }
  assert {
    condition     = aws_secretsmanager_secret.updates.name == "mokaid/desktop/stable/windows-updates" && aws_secretsmanager_secret.updates.recovery_window_in_days == 30
    error_message = "The update seed uses a distinct fixed stable secret with a recovery window."
  }
}

run "ownership_cannot_be_overridden" {
  command = plan
  variables { tags = { Channel = "beta", Project = "other", Ticket = "fixture" } }
  assert {
    condition     = aws_iam_role.signer.tags.Channel == "stable" && aws_secretsmanager_secret.updates.tags.Project == "mokaid" && aws_iam_role.signer.tags.Ticket == "fixture"
    error_message = "Additional tags cannot change channel or project identity."
  }
}

run "cross_account_provider_rejected" {
  command = plan
  variables { github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  expect_failures = [aws_iam_role.signer]
}

run "wrong_region_rejected" {
  command = plan
  override_data {
    target = data.aws_region.current
    values = { name = "us-east-1" }
  }
  expect_failures = [aws_secretsmanager_secret.updates]
}

run "untrusted_provider_rejected" {
  command = plan
  variables { github_oidc_provider_arn = "arn:aws:iam::660601648321:oidc-provider/example.com" }
  expect_failures = [var.github_oidc_provider_arn]
}

run "wildcard_repository_rejected" {
  command = plan
  variables { github_repository = "Yapio-Ltd/*" }
  expect_failures = [var.github_repository]
}

run "injected_subject_rejected" {
  command = plan
  variables { github_repository = "Yapio-Ltd/mokaid:ref:refs/heads/main" }
  expect_failures = [var.github_repository]
}
