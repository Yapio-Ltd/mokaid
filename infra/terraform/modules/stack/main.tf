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

variable "web_image_tag" {
  type    = string
  default = "latest"
}

variable "crm_image_tag" {
  type    = string
  default = "latest"
}

variable "web_cpu" {
  type    = number
  default = 256
}

variable "web_memory" {
  type    = number
  default = 512
}

variable "web_desired_count" {
  type    = number
  default = 1
}

variable "web_max_count" {
  type    = number
  default = 2
}

variable "crm_cpu" {
  type    = number
  default = 256
}

variable "crm_memory" {
  type    = number
  default = 512
}

variable "crm_desired_count" {
  type    = number
  default = 1
}

variable "crm_max_count" {
  type    = number
  default = 2
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

variable "waf_allowed_country_codes" {
  description = "ISO 3166-1 alpha-2 countries allowed by the ALB WAF (default Block)"
  type        = list(string)
  default     = ["IL", "FR"]
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

variable "crm_domain" {
  description = "Operator CRM hostname (e.g. crm.mokaid.com)"
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
  description = "cognito | dev_fallback"
  type        = string
  default     = "cognito"
}

variable "payme_sandbox" {
  description = "Use the PayMe sandbox (true) or live payments (false)"
  type        = bool
  default     = true
}

variable "db_snapshot_identifier" {
  description = "Restore the Postgres instance from this snapshot (data migration). Empty = fresh database."
  type        = string
  default     = ""
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

  app_origins = var.app_domain != "" ? ["https://${var.app_domain}"] : [
    "http://localhost:3000",
    "http://localhost:5173",
  ]

  crm_origins = var.crm_domain != "" ? ["https://${var.crm_domain}"] : [
    "http://localhost:3001",
  ]

  # Cognito requires HTTPS for non-localhost callbacks; ALB HTTP origin is API CORS/S3 only.
  cors_origins = concat(
    local.app_origins,
    local.crm_origins,
    var.app_domain == "" ? ["http://${module.alb.alb_dns_name}"] : [],
  )

  app_origin = join(",", local.cors_origins)
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
  crm_domain        = var.crm_domain
  tags              = local.tags
}

module "waf" {
  source = "../waf"

  # Keep the existing ACL name so terraform can manage the live resource.
  name                  = "allow-israel-only"
  alb_arn               = module.alb.alb_arn
  allowed_country_codes = var.waf_allowed_country_codes
  tags                  = local.tags
}

# ---------- Registries (managed in bootstrap; shared across environments) ----------

data "aws_ecr_repository" "api" {
  name = "mokaid-api"
}

data "aws_ecr_repository" "ai_worker" {
  name = "mokaid-ai-worker"
}

data "aws_ecr_repository" "web" {
  name = "mokaid-web"
}

data "aws_ecr_repository" "crm" {
  name = "mokaid-crm"
}

locals {
  ecr_repository_urls = {
    "mokaid-api"       = data.aws_ecr_repository.api.repository_url
    "mokaid-ai-worker" = data.aws_ecr_repository.ai_worker.repository_url
    "mokaid-web"       = data.aws_ecr_repository.web.repository_url
    "mokaid-crm"       = data.aws_ecr_repository.crm.repository_url
  }
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
  cors_allowed_origins = local.cors_origins
  tags                 = local.tags
}

module "s3_uploads" {
  source = "../s3-bucket"

  bucket_name            = "mokaid-uploads-${local.bucket_suffix}"
  cors_allowed_origins   = local.cors_origins
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
  callback_urls = [for origin in local.app_origins : "${origin}/auth/callback"]
  logout_urls   = local.app_origins
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
    secret_key_base          = "CHANGE_ME"
    worker_auth_token        = "CHANGE_ME"
    openai_api_key           = "CHANGE_ME"
    anthropic_api_key        = "CHANGE_ME"
    deepseek_api_key         = "CHANGE_ME"
    payme_seller_id          = "CHANGE_ME"
    figma_client_id          = "CHANGE_ME"
    figma_client_secret      = "CHANGE_ME"
    google_client_id         = "CHANGE_ME"
    google_client_secret     = "CHANGE_ME"
    github_client_id         = "CHANGE_ME"
    github_client_secret     = "CHANGE_ME"
    linear_client_id         = "CHANGE_ME"
    linear_client_secret     = "CHANGE_ME"
    slack_client_id          = "CHANGE_ME"
    slack_client_secret      = "CHANGE_ME"
    slack_signing_secret     = "CHANGE_ME"
    slack_app_id             = "CHANGE_ME"
    slack_verification_token = "CHANGE_ME"
    notion_client_id         = "CHANGE_ME"
    notion_client_secret     = "CHANGE_ME"
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
  snapshot_identifier = var.db_snapshot_identifier
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

  container_image = "${local.ecr_repository_urls["mokaid-api"]}:${var.api_image_tag}"
  container_port  = 4000
  cpu             = var.api_cpu
  memory          = var.api_memory
  desired_count   = var.api_desired_count
  max_count       = var.api_max_count

  target_group_arn      = module.alb.api_target_group_arn
  alb_security_group_id = module.alb.alb_security_group_id

  environment = {
    MIX_ENV               = "prod"
    PHX_HOST              = var.app_domain != "" ? var.app_domain : module.alb.alb_dns_name
    PORT                  = "4000"
    AWS_REGION            = var.aws_region
    AUTH_MODE             = var.auth_mode
    COGNITO_USER_POOL_ID  = module.cognito.user_pool_id
    COGNITO_CLIENT_ID     = module.cognito.web_client_id
    S3_BUCKET_UPLOADS     = module.s3_uploads.bucket_id
    S3_BUCKET_PRIVATE     = module.s3_files.bucket_id
    S3_BUCKET_OUTPUTS     = module.s3_exports.bucket_id
    S3_BUCKET_EXPORTS     = module.s3_exports.bucket_id
    AI_DISPATCH_QUEUE_URL = module.sqs_ai_runs.queue_url
    CORS_ORIGINS          = local.app_origin
    FIGMA_REDIRECT_URI    = var.app_domain != "" ? "https://${var.app_domain}/oauth/figma/callback" : "https://mokaid.com/oauth/figma/callback"
    GOOGLE_REDIRECT_URI   = var.app_domain != "" ? "https://${var.app_domain}/oauth/google/callback" : "https://mokaid.com/oauth/google/callback"
    GITHUB_REDIRECT_URI   = var.app_domain != "" ? "https://${var.app_domain}/oauth/github/callback" : "https://mokaid.com/oauth/github/callback"
    LINEAR_REDIRECT_URI   = var.app_domain != "" ? "https://${var.app_domain}/oauth/linear/callback" : "https://mokaid.com/oauth/linear/callback"
    SLACK_REDIRECT_URI    = var.app_domain != "" ? "https://${var.app_domain}/oauth/slack/callback" : "https://mokaid.com/oauth/slack/callback"
    NOTION_REDIRECT_URI   = var.app_domain != "" ? "https://${var.app_domain}/auth/notion/callback" : "https://mokaid.com/auth/notion/callback"
    # PayMe hosted checkout: callback goes to the API, customers return to the app.
    PAYME_SANDBOX = var.payme_sandbox ? "true" : "false"
    API_BASE_URL  = var.app_domain != "" ? "https://${var.app_domain}" : "http://${module.alb.alb_dns_name}"
    WEB_BASE_URL  = var.app_domain != "" ? "https://${var.app_domain}" : "http://${module.alb.alb_dns_name}"
  }

  secrets = {
    DATABASE_URL             = module.rds.database_url_secret_arn
    SECRET_KEY_BASE          = module.secrets.secret_arns["secret_key_base"]
    AI_WORKER_TOKEN          = module.secrets.secret_arns["worker_auth_token"]
    FIGMA_CLIENT_ID          = module.secrets.secret_arns["figma_client_id"]
    FIGMA_CLIENT_SECRET      = module.secrets.secret_arns["figma_client_secret"]
    GOOGLE_CLIENT_ID         = module.secrets.secret_arns["google_client_id"]
    GOOGLE_CLIENT_SECRET     = module.secrets.secret_arns["google_client_secret"]
    GITHUB_CLIENT_ID         = module.secrets.secret_arns["github_client_id"]
    GITHUB_CLIENT_SECRET     = module.secrets.secret_arns["github_client_secret"]
    LINEAR_CLIENT_ID         = module.secrets.secret_arns["linear_client_id"]
    LINEAR_CLIENT_SECRET     = module.secrets.secret_arns["linear_client_secret"]
    SLACK_CLIENT_ID          = module.secrets.secret_arns["slack_client_id"]
    SLACK_CLIENT_SECRET      = module.secrets.secret_arns["slack_client_secret"]
    SLACK_SIGNING_SECRET     = module.secrets.secret_arns["slack_signing_secret"]
    SLACK_APP_ID             = module.secrets.secret_arns["slack_app_id"]
    SLACK_VERIFICATION_TOKEN = module.secrets.secret_arns["slack_verification_token"]
    NOTION_CLIENT_ID         = module.secrets.secret_arns["notion_client_id"]
    NOTION_CLIENT_SECRET     = module.secrets.secret_arns["notion_client_secret"]
    PAYME_SELLER_ID          = module.secrets.secret_arns["payme_seller_id"]
  }

  task_policy_json   = data.aws_iam_policy_document.api_task.json
  enable_task_policy = true
  tags               = local.tags
}

module "web_service" {
  source = "../ecs-service"

  name               = "${local.name}-web"
  cluster_arn        = aws_ecs_cluster.this.arn
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  container_image = "${local.ecr_repository_urls["mokaid-web"]}:${var.web_image_tag}"
  container_port  = 80
  cpu             = var.web_cpu
  memory          = var.web_memory
  desired_count   = var.web_desired_count
  max_count       = var.web_max_count

  target_group_arn      = module.alb.web_target_group_arn
  alb_security_group_id = module.alb.alb_security_group_id

  tags = local.tags
}

module "crm_service" {
  source = "../ecs-service"

  name               = "${local.name}-crm"
  cluster_arn        = aws_ecs_cluster.this.arn
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids

  container_image = "${local.ecr_repository_urls["mokaid-crm"]}:${var.crm_image_tag}"
  container_port  = 3001
  cpu             = var.crm_cpu
  memory          = var.crm_memory
  desired_count   = var.crm_desired_count
  max_count       = var.crm_max_count

  # Same-origin API on crm.mokaid.com (ALB host+path rules). Empty public URL.
  environment = {
    PORT                = "3001"
    HOSTNAME            = "0.0.0.0"
    NEXT_PUBLIC_API_URL = ""
  }

  target_group_arn      = module.alb.crm_target_group_arn
  alb_security_group_id = module.alb.alb_security_group_id

  tags = local.tags
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

  container_image = "${local.ecr_repository_urls["mokaid-ai-worker"]}:${var.worker_image_tag}"
  container_port  = 8100
  cpu             = var.worker_cpu
  memory          = var.worker_memory
  desired_count   = 1
  max_count       = 3

  environment = {
    PHOENIX_API_URL   = var.app_domain != "" ? "https://${var.app_domain}" : "http://${module.alb.alb_dns_name}"
    AWS_REGION        = var.aws_region
    AI_RUNS_QUEUE_URL = module.sqs_ai_runs.queue_url
    # LangSmith stays opt-in: set LANGSMITH_API_KEY as an SSM/Secrets override
    # out-of-band when you want tracing; the worker enables it only if present.
    LANGSMITH_PROJECT = "mokaid-ai-worker"
  }

  secrets = {
    # Same ecto:// DSN as the API — the Python worker rewrites the scheme to
    # postgresql:// for psycopg / LangGraph checkpoints (run persistence).
    DATABASE_URL      = module.rds.database_url_secret_arn
    WORKER_AUTH_TOKEN = module.secrets.secret_arns["worker_auth_token"]
    OPENAI_API_KEY    = module.secrets.secret_arns["openai_api_key"]
    ANTHROPIC_API_KEY = module.secrets.secret_arns["anthropic_api_key"]
    DEEPSEEK_API_KEY  = module.secrets.secret_arns["deepseek_api_key"]
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

output "web_service_name" {
  value = module.web_service.service_name
}

output "crm_service_name" {
  value = module.crm_service.service_name
}

output "cognito_user_pool_id" {
  value = module.cognito.user_pool_id
}

output "cognito_web_client_id" {
  value = module.cognito.web_client_id
}

output "ecr_repository_urls" {
  value = local.ecr_repository_urls
}

output "ai_runs_queue_url" {
  value = module.sqs_ai_runs.queue_url
}

output "db_endpoint" {
  value = module.rds.endpoint
}
