# Mocked provider only: these tests never access AWS or create cloud resources.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRoleWithWebIdentity\",\"Principal\":{\"Federated\":\"arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com\"}}]}"
    }
  }
}

variables {
  bucket_name              = "mokaid-desktop-test-123456789012"
  domain_name              = "downloads.example.com"
  acm_certificate_arn      = "arn:aws:acm:us-east-1:123456789012:certificate/test-fixture"
  github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  signing_secret_arns      = {}
}

run "external_dns_and_unsigned_state_are_safe" {
  command = plan
  assert {
    condition     = length(aws_route53_record.downloads) == 0
    error_message = "External DNS must not create or take over Route53 records."
  }
  assert {
    condition     = length(aws_iam_role.signer) == 0 && length(aws_iam_role.publisher) == 2
    error_message = "Signers must remain unprovisioned without exact secret ARNs; publisher identities remain channel-separated."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.downloads.block_public_acls && aws_s3_bucket_public_access_block.downloads.block_public_policy && aws_s3_bucket_public_access_block.downloads.ignore_public_acls && aws_s3_bucket_public_access_block.downloads.restrict_public_buckets
    error_message = "The origin must never permit public S3 access."
  }
  assert {
    condition     = aws_s3_bucket_versioning.downloads.versioning_configuration[0].status == "Enabled"
    error_message = "Feed rollback requires object versioning."
  }
  assert {
    condition     = aws_cloudfront_distribution.downloads.viewer_certificate[0].minimum_protocol_version == "TLSv1.2_2021" && aws_cloudfront_cache_policy.feeds.max_ttl == 60
    error_message = "HTTPS and short-lived channel feeds are mandatory."
  }
}

run "route53_records_are_opt_in" {
  command = plan
  variables { route53_zone_id = "Z0123456789FIXTURE" }
  assert {
    condition     = length(aws_route53_record.downloads) == 2
    error_message = "An explicitly provided hosted zone should receive IPv4 and IPv6 aliases."
  }
}

run "wildcard_secret_permissions_are_rejected" {
  command = plan
  variables { signing_secret_arns = { stable = ["arn:aws:secretsmanager:il-central-1:123456789012:secret:*"] } }
  expect_failures = [var.signing_secret_arns]
}

run "wrong_certificate_region_is_rejected" {
  command = plan
  variables { acm_certificate_arn = "arn:aws:acm:il-central-1:123456789012:certificate/test-fixture" }
  expect_failures = [var.acm_certificate_arn]
}
