# Composition module: wires all mokaid infrastructure for one environment.

variable "environment" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "single_nat_gateway" {
  type    = bool
  default = true
}

variable "api_image_tag" {
  type    = string
  default = "latest"
}

variable "worker_image_tag" {
  type    = string
  default = "latest"
}

variable "api_cpu" {
  type    = number
  default = 512
}

variable "api_memory" {
  type    = number
  default = 1024
}

variable "api_desired_count" {
  type    = number
  default = 1
}

variable "api_max_count" {
  type    = number
  default = 4
}

variable "worker_cpu" {
  type    = number
  default = 512
}

variable "worker_memory" {
  type    = number
  default = 1024
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_multi_az" {
  type    = bool
  default = false
}

variable "db_deletion_protection" {
  type    = bool
  default = false
}

variable "alb_certificate_arn" {
  type    = string
  default = ""
}

variable "cloudfront_certificate_arn" {
  type    = string
  default = ""
}

variable "cloudfront_aliases" {
  type    = list(string)
  default = []
}

variable "app_domain" {
  description = "Public web app origin used for CORS and Cognito callbacks"
  type        = string
  default     = ""
}

variable "alarm_email" {
  type    = string
  default = ""
}

variable "monthly_budget_usd" {
  type    = number
  default = 200
}

variable "enable_cloudfront" {
  description = "Create CloudFront distribution (requires verified AWS account)"
  type        = bool
  default     = false
}

variable "auth_mode" {
  description = "cognito | dev_fallback (dev only)"
  type        = string
  default     = "cognito"
}

data "aws_caller_identity" "current" {}

locals {
  name = "mokaid-${var.environment}"

  tags = {
    Project     = "mokaid"
    Owner       = "Yapio"
    ManagedBy   = "Terraform"
    Environment = var.environment
  }

  bucket_suffix = "${var.environment}-${data.aws_caller_identity.current.account_id}"

  app_origin = var.app_domain != "" ? "https://${var.app_domain}" : "http://localhost:3000,http://localhost:5173"
}

# ---------- Networking ----------

module "vpc" {
  source = "../vpc"

  name               = local.name
  cidr_block         = var.vpc_cidr
  single_nat_gateway = var.single_nat_gateway
  tags               = local.tags
}

module "alb" {
  source = "../alb"

  name              = local.name
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  certificate_arn   = var.alb_certificate_arn
  tags              = local.tags
}

# ---------- Registries ----------

module "ecr" {
  source = "../ecr"

  repositories = ["mokaid-api", "mokaid-ai-worker", "mokaid-web"]
  tags         = local.tags
}

# ---------- Storage ----------

module "s3_app" {
  source = "../s3-bucket"

  bucket_name = "mokaid-app-${local.bucket_suffix}"
  tags        = local.tags
}

module "s3_assets" {
  source = "../s3-bucket"

  bucket_name = "mokaid-assets-3d-${local.bucket_suffix}"
  tags        = local.tags
}

module "s3_files" {
  source = "../s3-bucket"

  bucket_name          = "mokaid-files-${local.bucket_suffix}"
  cors_allowed_origins = [local.app_origin]
  tags                 = local.tags
}

module "s3_uploads" {
  source = "../s3-bucket"

  bucket_name            = "mokaid-uploads-${local.bucket_suffix}"
  cors_allowed_origins   = [local.app_origin]
  expire_noncurrent_days = 14
  tags                   = local.tags
}

module "s3_exports" {
  source = "../s3-bucket"

  bucket_name            = "mokaid-exports-${local.bucket_suffix}"
  versioning             = false
  expire_noncurrent_days = 30
  tags                   = local.tags
}

module "s3_backups" {
  source = "../s3-bucket"

  bucket_name = "mokaid-backups-${local.bucket_suffix}"
  tags        = local.tags
}

module "cloudfront" {
  count  = var.enable_cloudfront ? 1 : 0
  source = "../cloudfront"

  name                      = local.name
  app_bucket_id             = module.s3_app.bucket_id
  app_bucket_arn            = module.s3_app.bucket_arn
  app_bucket_domain_name    = module.s3_app.bucket_regional_domain_name
  assets_bucket_id          = module.s3_assets.bucket_id
  assets_bucket_arn         = module.s3_assets.bucket_arn
  assets_bucket_domain_name = module.s3_assets.bucket_regional_domain_name
  aliases                   = var.cloudfront_aliases
  acm_certificate_arn       = var.cloudfront_certificate_arn
  tags                      = local.tags
}

# ---------- Auth ----------

module "cognito" {
  source = "../cognito"

  name          = local.name
  callback_urls = ["${local.app_origin}/auth/callback"]
  logout_urls   = [local.app_origin]
  tags          = local.tags
}

# ---------- Messaging ----------

module "sqs_ai_runs" {
  source = "../sqs"

  name = "${local.name}-ai-runs"
  tags = local.tags
}

# ---------- Secrets ----------

module "secrets" {
  source = "../secrets"

  name_prefix = local.name
  secrets = {
    secret_key_base     = "CHANGE_ME"
    worker_auth_token   = "CHANGE_ME"
    openai_api_key      = "CHANGE_ME"
    figma_client_id     = "CHANGE_ME"
    figma_client_secret = "CHANGE_ME"
  }
  parameters = {
    cognito_user_pool_id = module.cognito.user_pool_id
    cognito_client_id    = module.cognito.web_client_id
  }
  tags = local.tags
}

# ---------- Compute ----------

resource "aws_ecs_cluster" "this" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.tags
}

module "rds" {
  source = "../rds-postgres"

  name                = local.name
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnet_ids
  instance_class      = var.db_instance_class
  multi_az            = var.db_multi_az
  deletion_protection = var.db_deletion_protection
  tags                = local.tags
}

# Ingress rules added here (not inside the rds module) to avoid a
# dependency cycle: services need the DB secret, DB needs service SGs.
resource "aws_vpc_security_group_ingress_rule" "db_from_api" {
  security_group_id            = module.rds.db_security_group_id
  referenced_security_group_id = module.api_service.security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  tags                         = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "db_from_worker" {
  security_group_id            = module.rds.db_security_group_id
  referenced_security_group_id = module.worker_service.security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  tags                         = local.tags
}

data "aws_iam_policy_document" "api_task" {
  statement {
    sid = "S3Files"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      module.s3_files.bucket_arn,
      "${module.s3_files.bucket_arn}/*",
      module.s3_uploads.bucket_arn,
      "${module.s3_uploads.bucket_arn}/*",
      module.s3_exports.bucket_arn,
      "${module.s3_exports.bucket_arn}/*",
    ]
  }

  statement {
    sid       = "SqsDispatch"
    actions   = ["sqs:SendMessage"]
    resources = [module.sqs_ai_runs.queue_arn]
  }

  statement {
    sid       = "CognitoAdmin"
    actions   = ["cognito-idp:AdminGetUser", "cognito-idp:AdminCreateUser"]
    resources = [module.cognito.user_pool_arn]
  }
}

module "api_service" {
  source = "../ecs-service"

  name               = "${local.name}-api"
  cluster_arn        = aws_ecs_cluster.this.arn
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  container_image = "${module.ecr.repository_urls["mokaid-api"]}:${var.api_image_tag}"
  container_port  = 4000
  cpu             = var.api_cpu
  memory          = var.api_memory
  desired_count   = var.api_desired_count
  max_count       = var.api_max_count

  target_group_arn      = module.alb.api_target_group_arn
  alb_security_group_id = module.alb.alb_security_group_id

  environment = {
    MIX_ENV                = "prod"
    PHX_HOST               = var.app_domain != "" ? "api.${var.app_domain}" : module.alb.alb_dns_name
    PORT                   = "4000"
    AWS_REGION             = var.aws_region
    AUTH_MODE              = var.auth_mode
    COGNITO_USER_POOL_ID   = module.cognito.user_pool_id
    COGNITO_CLIENT_ID      = module.cognito.web_client_id
    S3_BUCKET_UPLOADS      = module.s3_uploads.bucket_id
    S3_BUCKET_PRIVATE      = module.s3_files.bucket_id
    S3_BUCKET_OUTPUTS      = module.s3_exports.bucket_id
    S3_BUCKET_EXPORTS      = module.s3_exports.bucket_id
    AI_DISPATCH_QUEUE_URL  = module.sqs_ai_runs.queue_url
    CORS_ORIGINS           = local.app_origin
    FIGMA_REDIRECT_URI     = var.app_domain != "" ? "https://${var.app_domain}/oauth/figma/callback" : "https://mokaid.com/oauth/figma/callback"
  }

  secrets = {
    DATABASE_URL        = module.rds.database_url_secret_arn
    SECRET_KEY_BASE     = module.secrets.secret_arns["secret_key_base"]
    AI_WORKER_TOKEN     = module.secrets.secret_arns["worker_auth_token"]
    FIGMA_CLIENT_ID     = module.secrets.secret_arns["figma_client_id"]
    FIGMA_CLIENT_SECRET = module.secrets.secret_arns["figma_client_secret"]
  }

  task_policy_json   = data.aws_iam_policy_document.api_task.json
  enable_task_policy = true
  tags               = local.tags
}

data "aws_iam_policy_document" "worker_task" {
  statement {
    sid = "SqsConsume"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [module.sqs_ai_runs.queue_arn]
  }

  statement {
    sid       = "S3Files"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${module.s3_files.bucket_arn}/*"]
  }
}

module "worker_service" {
  source = "../ecs-service"

  name               = "${local.name}-ai-worker"
  cluster_arn        = aws_ecs_cluster.this.arn
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  container_image = "${module.ecr.repository_urls["mokaid-ai-worker"]}:${var.worker_image_tag}"
  container_port  = 8100
  cpu             = var.worker_cpu
  memory          = var.worker_memory
  desired_count   = 1
  max_count       = 3

  environment = {
    PHOENIX_API_URL   = "http://${module.alb.alb_dns_name}"
    AWS_REGION        = var.aws_region
    AI_RUNS_QUEUE_URL = module.sqs_ai_runs.queue_url
  }

  secrets = {
    WORKER_AUTH_TOKEN = module.secrets.secret_arns["worker_auth_token"]
    OPENAI_API_KEY    = module.secrets.secret_arns["openai_api_key"]
  }

  task_policy_json   = data.aws_iam_policy_document.worker_task.json
  enable_task_policy = true
  tags               = local.tags
}

# ---------- Monitoring ----------

module "monitoring" {
  source = "../monitoring"

  name               = local.name
  alarm_email        = var.alarm_email
  ecs_cluster_name   = aws_ecs_cluster.this.name
  api_service_name   = module.api_service.service_name
  db_instance_id     = local.name
  monthly_budget_usd = var.monthly_budget_usd
  tags               = local.tags
}

# ---------- Outputs ----------

output "cloudfront_domain" {
  value = var.enable_cloudfront ? module.cloudfront[0].distribution_domain_name : ""
}

output "alb_dns_name" {
  value = module.alb.alb_dns_name
}

output "cognito_user_pool_id" {
  value = module.cognito.user_pool_id
}

output "cognito_web_client_id" {
  value = module.cognito.web_client_id
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "ai_runs_queue_url" {
  value = module.sqs_ai_runs.queue_url
}

output "db_endpoint" {
  value = module.rds.endpoint
}
