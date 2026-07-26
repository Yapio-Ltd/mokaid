# Regional WAFv2 ACL attached to the ALB.
# Default Block + geo Allow for the listed ISO country codes.

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

variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_wafv2_web_acl" "this" {
  name        = var.name
  description = "Allow traffic only from: ${join(", ", var.allowed_country_codes)}"
  scope       = "REGIONAL"

  default_action {
    block {}
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

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.name
    sampled_requests_enabled   = true
  }

  tags = var.tags
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
