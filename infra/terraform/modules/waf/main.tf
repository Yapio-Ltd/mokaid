# Regional WAFv2 ACL attached to the ALB.
# Default Block (custom branded HTML) + geo Allow for listed countries.

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

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  # WAF custom response body max is 4 KiB — keep the minified HTML under that.
  geo_unavailable_html = file("${path.module}/geo-unavailable.min.html")
}

resource "aws_wafv2_web_acl" "this" {
  name        = var.name
  description = "Allow traffic only from: ${join(", ", var.allowed_country_codes)}"
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
