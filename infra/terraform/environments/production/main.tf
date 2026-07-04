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
    key            = "production/terraform.tfstate"
    region         = "eu-west-1"
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
  default = "eu-west-1"
}

variable "alarm_email" {
  type    = string
  default = "ops@yapio.io"
}

variable "app_domain" {
  type    = string
  default = "mokaid.app"
}

variable "alb_certificate_arn" {
  type    = string
  default = ""
}

variable "cloudfront_certificate_arn" {
  description = "ACM cert in us-east-1"
  type        = string
  default     = ""
}

module "stack" {
  source = "../../modules/stack"

  environment = "production"
  aws_region  = var.aws_region
  vpc_cidr    = "10.30.0.0/16"

  # High availability
  single_nat_gateway = false
  api_cpu            = 1024
  api_memory         = 2048
  api_desired_count  = 2
  api_max_count      = 8
  worker_cpu         = 1024
  worker_memory      = 2048

  db_instance_class      = "db.r6g.large"
  db_multi_az            = true
  db_deletion_protection = true

  app_domain                 = var.app_domain
  alb_certificate_arn        = var.alb_certificate_arn
  cloudfront_certificate_arn = var.cloudfront_certificate_arn
  cloudfront_aliases         = var.cloudfront_certificate_arn != "" ? [var.app_domain, "www.${var.app_domain}"] : []

  alarm_email        = var.alarm_email
  monthly_budget_usd = 1500
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
