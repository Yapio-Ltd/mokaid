terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    bucket         = "mokaid-terraform-state"
    key            = "prod/terraform.tfstate"
    region         = "il-central-1"
    dynamodb_table = "mokaid-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "mokaid"
      Owner     = "Yapio"
      ManagedBy = "Terraform"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "il-central-1"
}

variable "alarm_email" {
  type    = string
  default = ""
}

variable "app_domain" {
  type    = string
  default = "mokaid.com"
}

variable "crm_domain" {
  type    = string
  default = "crm.mokaid.com"
}

variable "alb_certificate_arn" {
  description = "ACM certificate (il-central-1) for the ALB HTTPS listener — must include mokaid.com and crm.mokaid.com SANs"
  type        = string
  default     = "arn:aws:acm:il-central-1:660601648321:certificate/6a571d65-8eb0-4b47-b9ae-92eea282ae22"
}

variable "web_image_tag" {
  type    = string
  default = "v2"
}

variable "crm_image_tag" {
  type    = string
  default = "latest"
}

variable "api_image_tag" {
  type    = string
  default = "v2"
}

variable "worker_image_tag" {
  type    = string
  default = "latest"
}

variable "db_snapshot_identifier" {
  description = "Optional RDS snapshot to restore from (used once when migrating from a previous environment)."
  type        = string
  default     = ""
}

module "stack" {
  source = "../../modules/stack"

  environment        = "prod"
  aws_region         = var.aws_region
  vpc_cidr           = "10.10.0.0/16"
  single_nat_gateway = true
  api_cpu            = 256
  api_memory         = 512
  api_desired_count  = 1
  api_max_count      = 2
  worker_cpu         = 256
  worker_memory      = 512

  db_instance_class      = "db.t4g.micro"
  db_multi_az            = false
  db_deletion_protection = true
  db_snapshot_identifier = var.db_snapshot_identifier

  app_domain                = var.app_domain
  crm_domain                = var.crm_domain
  alb_certificate_arn       = var.alb_certificate_arn
  waf_allowed_country_codes = ["IL", "FR"]

  auth_mode = "dev_fallback"

  tranzila_terminal = "fxpyapio"
  # No dedicated token terminal provisioned — empty falls back to the main
  # terminal with tranmode=AK ("fxpyapiotok" does not exist and 404s).
  tranzila_token_terminal = ""
  tranzila_currency       = "USD"

  api_image_tag    = var.api_image_tag
  web_image_tag    = var.web_image_tag
  crm_image_tag    = var.crm_image_tag
  worker_image_tag = var.worker_image_tag

  alarm_email        = var.alarm_email
  monthly_budget_usd = 100
}

output "web_service_name" {
  value = module.stack.web_service_name
}

output "crm_service_name" {
  value = module.stack.crm_service_name
}

output "cloudfront_domain" {
  value = module.stack.cloudfront_domain
}

output "alb_dns_name" {
  value = module.stack.alb_dns_name
}

output "cognito_user_pool_id" {
  value = module.stack.cognito_user_pool_id
}

output "cognito_web_client_id" {
  value = module.stack.cognito_web_client_id
}

output "ecr_repository_urls" {
  value = module.stack.ecr_repository_urls
}

output "db_endpoint" {
  value = module.stack.db_endpoint
}
