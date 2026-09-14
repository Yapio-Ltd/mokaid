# Plan-only tests with a mocked provider: no AWS credentials, calls or state.
mock_provider "aws" {
  override_during = plan

  mock_resource "aws_wafv2_web_acl" {
    defaults = {
      arn = "arn:aws:wafv2:us-east-1:123456789012:regional/webacl/fixture/00000000-0000-4000-8000-000000000000"
      id  = "00000000-0000-4000-8000-000000000000"
    }
  }
}

variables {
  name    = "allow-israel-only"
  alb_arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/fixture/0000000000000000"
}

run "default_has_no_global_host_exception" {
  command = plan

  assert {
    condition     = length(aws_wafv2_web_acl.this.rule) == 2 && toset([for rule in aws_wafv2_web_acl.this.rule : rule.name]) == toset(["allow-geo", "allow-webhook-paths"])
    error_message = "The default must contain only the pre-existing geo and webhook rules, with no global Host exception."
  }

  assert {
    condition = (
      aws_wafv2_web_acl.this.name == "allow-israel-only" &&
      aws_wafv2_web_acl.this.scope == "REGIONAL" &&
      aws_wafv2_web_acl_association.alb.resource_arn == var.alb_arn &&
      aws_wafv2_web_acl_association.alb.web_acl_arn == aws_wafv2_web_acl.this.arn
    )
    error_message = "Keep the ACL identity, regional scope and association to the existing ALB."
  }

  assert {
    condition = (
      length(aws_wafv2_web_acl.this.default_action[0].allow) == 0 &&
      aws_wafv2_web_acl.this.default_action[0].block[0].custom_response[0].response_code == 403 &&
      aws_wafv2_web_acl.this.default_action[0].block[0].custom_response[0].custom_response_body_key == "geo-unavailable" &&
      one(aws_wafv2_web_acl.this.custom_response_body).content == file("${path.module}/geo-unavailable.min.html")
    )
    error_message = "Unmatched requests must retain the same branded default 403 response."
  }

  assert {
    condition = alltrue([for rule in aws_wafv2_web_acl.this.rule :
      rule.priority == 0 && toset(rule.statement[0].geo_match_statement[0].country_codes) == toset(["IL", "FR"]) &&
      length(rule.action[0].allow) == 1 && rule.visibility_config[0].metric_name == "allowGeo"
      if rule.name == "allow-geo"
    ])
    error_message = "The existing IL/FR geo allowance, priority and metric must remain unchanged."
  }
}

run "only_the_explicit_public_host_is_global" {
  command = plan
  variables {
    globally_allowed_hosts = ["mokaid.com"]
  }

  assert {
    condition = toset([for rule in aws_wafv2_web_acl.this.rule : rule.name]) == toset([
      "allow-geo", "allow-webhook-paths", "allow-global-host-${substr(sha256("mokaid.com"), 0, 16)}"
    ])
    error_message = "Exactly one Host rule must be added alongside both existing rules."
  }

  assert {
    condition = alltrue([for rule in aws_wafv2_web_acl.this.rule :
      rule.priority == 10 && length(rule.action[0].allow) == 1 &&
      rule.name == "allow-global-host-${substr(sha256("mokaid.com"), 0, 16)}" &&
      rule.statement[0].byte_match_statement[0].positional_constraint == "EXACTLY" &&
      rule.statement[0].byte_match_statement[0].search_string == "mokaid.com" &&
      rule.statement[0].byte_match_statement[0].field_to_match[0].single_header[0].name == "host" &&
      length(rule.statement[0].byte_match_statement[0].text_transformation) == 1 &&
      one(rule.statement[0].byte_match_statement[0].text_transformation).type == "LOWERCASE" &&
      one(rule.statement[0].byte_match_statement[0].text_transformation).priority == 0 &&
      rule.visibility_config[0].metric_name == "allowGlobalHost${substr(sha256("mokaid.com"), 0, 16)}" &&
      rule.visibility_config[0].cloudwatch_metrics_enabled && rule.visibility_config[0].sampled_requests_enabled
      if startswith(rule.name, "allow-global-host-")
    ])
    error_message = "The global allow must be an exact, case-normalized Host match with stable names and its own priority."
  }

  # These cases interpret only the new rule's inspected EXACTLY/LOWERCASE
  # contract. They do not simulate ALB routing or WAF's live HTTP parser.
  assert {
    condition = alltrue([for request in [
      { host = "mokaid.com", forwarded_host = "", allowed = true },
      { host = "MOKAID.COM", forwarded_host = "crm.mokaid.com", allowed = true },
      { host = "crm.mokaid.com", forwarded_host = "mokaid.com", allowed = false },
      { host = "mokaid-prod-000.us-east-1.elb.amazonaws.com", forwarded_host = "mokaid.com", allowed = false },
      { host = "www.mokaid.com", forwarded_host = "mokaid.com", allowed = false },
      { host = "evil-mokaid.com", forwarded_host = "mokaid.com", allowed = false },
      { host = "mokaid.com.evil.example", forwarded_host = "mokaid.com", allowed = false },
      { host = "mokaid.com:443", forwarded_host = "mokaid.com", allowed = false },
      { host = "mokaid.com.", forwarded_host = "mokaid.com", allowed = false },
      { host = "mokaid.com/", forwarded_host = "mokaid.com", allowed = false },
      { host = "", forwarded_host = "mokaid.com", allowed = false }
      ] : anytrue([for rule in aws_wafv2_web_acl.this.rule : try(
        rule.statement[0].byte_match_statement[0].positional_constraint == "EXACTLY" &&
        lower(request.host) == rule.statement[0].byte_match_statement[0].search_string,
        false
    )]) == request.allowed])
    error_message = "Only the explicit Host may receive the global exception; suffixes, CRM, ALB DNS and forwarded Host cannot qualify."
  }

  assert {
    condition = (
      length(aws_wafv2_web_acl.this.default_action[0].allow) == 0 &&
      aws_wafv2_web_acl.this.default_action[0].block[0].custom_response[0].response_code == 403 &&
      alltrue([for rule in aws_wafv2_web_acl.this.rule :
        rule.priority == 0 && toset(rule.statement[0].geo_match_statement[0].country_codes) == toset(["IL", "FR"]) &&
        length(rule.action[0].allow) == 1 && rule.visibility_config[0].metric_name == "allowGeo"
        if rule.name == "allow-geo"
      ]) &&
      alltrue([for rule in aws_wafv2_web_acl.this.rule :
        rule.priority == 1 && length(rule.action[0].allow) == 1 &&
        rule.visibility_config[0].metric_name == "allowWebhookPaths" &&
        length(rule.statement[0].or_statement[0].statement) == 2 &&
        alltrue([for statement in rule.statement[0].or_statement[0].statement :
          statement.byte_match_statement[0].positional_constraint == "STARTS_WITH" &&
          statement.byte_match_statement[0].search_string == "/api/webhooks/" &&
          length(statement.byte_match_statement[0].field_to_match[0].uri_path) == 1 &&
          one(statement.byte_match_statement[0].text_transformation).type == "NONE"
        ])
        if rule.name == "allow-webhook-paths"
      ])
    )
    error_message = "Global site access must not change geo access, provider webhook exemptions or default deny."
  }
}

run "global_rules_are_sorted_deduplicated_and_stably_named" {
  command = plan
  variables {
    globally_allowed_hosts = ["z.example.com", "mokaid.com", "a.example.com", "mokaid.com"]
  }
  assert {
    condition = length(aws_wafv2_web_acl.this.rule) == 5 && alltrue([
      for rule in aws_wafv2_web_acl.this.rule :
      rule.priority == 10 + index(["a.example.com", "mokaid.com", "z.example.com"], rule.statement[0].byte_match_statement[0].search_string) &&
      rule.name == "allow-global-host-${substr(sha256(rule.statement[0].byte_match_statement[0].search_string), 0, 16)}" &&
      rule.visibility_config[0].metric_name == "allowGlobalHost${substr(sha256(rule.statement[0].byte_match_statement[0].search_string), 0, 16)}"
      if startswith(rule.name, "allow-global-host-")
    ])
    error_message = "Input ordering or duplicate Hosts must not create colliding priorities or unstable names/metrics."
  }
}

run "webhook_exception_can_still_be_disabled" {
  command = plan
  variables {
    globally_allowed_hosts   = ["mokaid.com"]
    geo_exempt_path_prefixes = []
  }
  assert {
    condition     = length(aws_wafv2_web_acl.this.rule) == 2 && !contains([for rule in aws_wafv2_web_acl.this.rule : rule.name], "allow-webhook-paths")
    error_message = "The existing explicit empty-webhooks configuration must remain supported."
  }
}

run "maximum_200_ascii_bytes_are_accepted" {
  command = plan
  variables {
    globally_allowed_hosts = [join(".", [for size in [63, 63, 63, 8] : join("", [for index in range(size) : "a"])])]
  }
  assert {
    condition     = length(aws_wafv2_web_acl.this.rule) == 3
    error_message = "A valid DNS Host at the WAF ByteMatch 200-byte limit should be accepted."
  }
}

run "over_200_bytes_are_rejected" {
  command = plan
  variables {
    globally_allowed_hosts = [join(".", [for size in [63, 63, 63, 9] : join("", [for index in range(size) : "a"])])]
  }
  expect_failures = [var.globally_allowed_hosts]
}

run "overlong_dns_label_is_rejected" {
  command = plan
  variables {
    globally_allowed_hosts = ["${join("", [for index in range(64) : "a"])}.com"]
  }
  expect_failures = [var.globally_allowed_hosts]
}

run "wildcard_is_rejected" {
  command = plan
  variables { globally_allowed_hosts = ["*.mokaid.com"] }
  expect_failures = [var.globally_allowed_hosts]
}

run "scheme_is_rejected" {
  command = plan
  variables { globally_allowed_hosts = ["https://mokaid.com"] }
  expect_failures = [var.globally_allowed_hosts]
}

run "path_is_rejected" {
  command = plan
  variables { globally_allowed_hosts = ["mokaid.com/api"] }
  expect_failures = [var.globally_allowed_hosts]
}

run "port_is_rejected" {
  command = plan
  variables { globally_allowed_hosts = ["mokaid.com:443"] }
  expect_failures = [var.globally_allowed_hosts]
}

run "uppercase_is_rejected" {
  command = plan
  variables { globally_allowed_hosts = ["Mokaid.com"] }
  expect_failures = [var.globally_allowed_hosts]
}

run "unicode_is_rejected" {
  command = plan
  variables { globally_allowed_hosts = ["mokaïd.com"] }
  expect_failures = [var.globally_allowed_hosts]
}

run "whitespace_is_rejected" {
  command = plan
  variables { globally_allowed_hosts = [" mokaid.com"] }
  expect_failures = [var.globally_allowed_hosts]
}

run "ipv4_is_rejected" {
  command = plan
  variables { globally_allowed_hosts = ["127.0.0.1"] }
  expect_failures = [var.globally_allowed_hosts]
}

run "ipv6_is_rejected" {
  command = plan
  variables { globally_allowed_hosts = ["[::1]"] }
  expect_failures = [var.globally_allowed_hosts]
}

run "trailing_dot_is_rejected" {
  command = plan
  variables { globally_allowed_hosts = ["mokaid.com."] }
  expect_failures = [var.globally_allowed_hosts]
}

run "empty_label_is_rejected" {
  command = plan
  variables { globally_allowed_hosts = ["mokaid..com"] }
  expect_failures = [var.globally_allowed_hosts]
}

run "leading_label_hyphen_is_rejected" {
  command = plan
  variables { globally_allowed_hosts = ["-mokaid.com"] }
  expect_failures = [var.globally_allowed_hosts]
}

run "trailing_label_hyphen_is_rejected" {
  command = plan
  variables { globally_allowed_hosts = ["mokaid-.com"] }
  expect_failures = [var.globally_allowed_hosts]
}

run "single_label_is_rejected" {
  command = plan
  variables { globally_allowed_hosts = ["localhost"] }
  expect_failures = [var.globally_allowed_hosts]
}

run "empty_host_is_rejected" {
  command = plan
  variables { globally_allowed_hosts = [""] }
  expect_failures = [var.globally_allowed_hosts]
}

run "null_host_is_rejected" {
  command = plan
  variables { globally_allowed_hosts = [null] }
  expect_failures = [var.globally_allowed_hosts]
}
