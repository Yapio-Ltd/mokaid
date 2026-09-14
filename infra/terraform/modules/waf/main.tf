# Regional WAFv2 ACL attached to the ALB.
# Default Block + existing geo/webhook Allows + opt-in exact global Host Allows.

variable "name" {
  type = string
}

variable "alb_arn" {
  type = string
}

variable "allowed_country_codes" {
  description = "ISO 3166-1 alpha-2 country codes allowed through the ALB"
  type        = list(string)
  default     = ["IL", "FR"]
}

variable "geo_exempt_path_prefixes" {
  description = "URI path prefixes reachable from any country (e.g. provider webhooks pushed from US datacenters). These endpoints must authenticate requests themselves."
  type        = list(string)
  default     = ["/api/webhooks/"]
}

variable "globally_allowed_hosts" {
  description = "Exact lowercase DNS Hosts reachable from any country. Empty preserves geo restrictions; authentication and ALB routing remain independent."
  type        = set(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for host in var.globally_allowed_hosts : try(
        length(host) <= 200 && can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", host)),
        false
      )
    ])
    error_message = "Each global Host must be a lowercase ASCII DNS name of at most 200 bytes, with labels of 1-63 characters and an alphabetic TLD start; no wildcard, IP address, scheme, path, port, trailing dot or whitespace."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  # WAF custom response body max is 4 KiB — keep the minified HTML under that.
  geo_unavailable_html = file("${path.module}/geo-unavailable.min.html")
  global_host_priorities = {
    for index, host in sort(tolist(var.globally_allowed_hosts)) : host => 10 + index
  }
}

resource "aws_wafv2_web_acl" "this" {
  name        = var.name
  description = length(var.globally_allowed_hosts) == 0 ? "Allow traffic only from: ${join(", ", var.allowed_country_codes)}" : "Geo-restricted traffic with explicit global Host exceptions"
  scope       = "REGIONAL"

  custom_response_body {
    key          = "geo-unavailable"
    content      = local.geo_unavailable_html
    content_type = "TEXT_HTML"
  }

  default_action {
    block {
      custom_response {
        response_code            = 403
        custom_response_body_key = "geo-unavailable"
      }
    }
  }

  rule {
    name     = "allow-geo"
    priority = 0

    action {
      allow {}
    }

    statement {
      geo_match_statement {
        country_codes = var.allowed_country_codes
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "allowGeo"
      sampled_requests_enabled   = true
    }
  }

  # Provider push notifications (Gmail Pub/Sub, Microsoft Graph) come from
  # US datacenters; without this rule the geo default-block silently drops
  # every webhook. The webhook controllers validate payloads themselves.
  dynamic "rule" {
    for_each = length(var.geo_exempt_path_prefixes) > 0 ? [1] : []

    content {
      name     = "allow-webhook-paths"
      priority = 1

      action {
        allow {}
      }

      statement {
        or_statement {
          dynamic "statement" {
            for_each = var.geo_exempt_path_prefixes

            content {
              byte_match_statement {
                positional_constraint = "STARTS_WITH"
                search_string         = statement.value

                field_to_match {
                  uri_path {}
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }

          # or_statement requires >= 2 operands; duplicate the first prefix
          # when only one is configured.
          dynamic "statement" {
            for_each = length(var.geo_exempt_path_prefixes) == 1 ? [var.geo_exempt_path_prefixes[0]] : []

            content {
              byte_match_statement {
                positional_constraint = "STARTS_WITH"
                search_string         = statement.value

                field_to_match {
                  uri_path {}
                }

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "allowWebhookPaths"
        sampled_requests_enabled   = true
      }
    }
  }

  # The public site and API share one Host. This deliberately does not match
  # subdomains, forwarded headers, suffixes, a trailing dot or an explicit port.
  # One rule per Host also avoids WAF's minimum-two-operands OrStatement limit.
  dynamic "rule" {
    for_each = local.global_host_priorities
    iterator = global_host

    content {
      name     = "allow-global-host-${substr(sha256(global_host.key), 0, 16)}"
      priority = global_host.value

      action {
        allow {}
      }

      statement {
        byte_match_statement {
          positional_constraint = "EXACTLY"
          search_string         = global_host.key

          field_to_match {
            single_header {
              name = "host"
            }
          }

          text_transformation {
            priority = 0
            type     = "LOWERCASE"
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "allowGlobalHost${substr(sha256(global_host.key), 0, 16)}"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.name
    sampled_requests_enabled   = true
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = length(local.geo_unavailable_html) <= 4096
      error_message = "geo-unavailable.min.html must be ≤ 4096 bytes (WAF custom response body limit)."
    }
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

output "web_acl_arn" {
  value = aws_wafv2_web_acl.this.arn
}

output "web_acl_id" {
  value = aws_wafv2_web_acl.this.id
}
