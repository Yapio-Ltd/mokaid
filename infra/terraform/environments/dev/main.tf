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
    key            = "dev/terraform.tfstate"
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
  default = ""
}

module "stack" {
  source = "../../modules/stack"

  environment = "dev"
  aws_region  = var.aws_region
  vpc_cidr    = "10.10.0.0/16"

  # Cost-optimized development environment
  single_nat_gateway = true
  api_cpu            = 256
  api_memory         = 512
  api_desired_count  = 1
  api_max_count      = 2
  worker_cpu         = 256
  worker_memory      = 512

  db_instance_class      = "db.t4g.micro"
  db_multi_az            = false
  db_deletion_protection = false

  alarm_email        = var.alarm_email
  monthly_budget_usd = 100
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
