variable "enable_avatar_worker" {
  description = "Opt in to the isolated Blender worker and enable paid custom-character creation."
  type        = bool
  default     = false
}

data "aws_iam_policy_document" "avatar_worker" {
  statement {
    sid       = "ReadAndRemoveAvatarReferences"
    actions   = ["s3:GetObject", "s3:DeleteObject"]
    resources = ["${module.s3_uploads.bucket_arn}/workspaces/*/drive/*/avatar-reference"]
  }
  statement {
    sid       = "StorePreparedCharacters"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${module.s3_assets.bucket_arn}/assets3d/generated-characters/*"]
  }
}

module "avatar_worker_service" {
  count  = var.enable_avatar_worker ? 1 : 0
  source = "../ecs-service"

  name               = "${local.name}-avatar-worker"
  cluster_arn        = aws_ecs_cluster.this.arn
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  container_image    = "${local.ecr_repository_urls["mokaid-api"]}:${var.api_image_tag}"
  # Blender's official Linux distribution is x64. The API remains ARM64.
  cpu_architecture = "X86_64"
  cpu              = 1024
  memory           = 4096
  desired_count    = 1
  min_count        = 1
  max_count        = 1
  # Oban Basic limits concurrency per process. Never overlap two workers.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  stop_timeout                       = 120

  # No ALB, service discovery, public IP, or inbound security-group rule.
  container_health_check = {
    command     = ["CMD-SHELL", "/app/bin/mokaid rpc 'unless match?(%%{limit: 1, paused: false}, Oban.check_queue(queue: :avatars)), do: System.halt(1)' || exit 1"]
    interval    = 30
    timeout     = 10
    retries     = 3
    startPeriod = 60
  }

  environment = {
    MIX_ENV                        = "prod"
    PHX_SERVER                     = "false"
    PHX_HOST                       = var.app_domain != "" ? var.app_domain : module.alb.alb_dns_name
    MOKAID_AVATAR_WORKER_MODE      = "worker"
    MOKAID_AVATAR_PIPELINE_ENABLED = "true"
    POOL_SIZE                      = "3"
    AWS_REGION                     = var.aws_region
    AUTH_MODE                      = var.auth_mode
    COGNITO_USER_POOL_ID           = module.cognito.user_pool_id
    COGNITO_CLIENT_ID              = module.cognito.web_client_id
    S3_BUCKET_UPLOADS              = module.s3_uploads.bucket_id
    S3_BUCKET_ASSETS_3D            = module.s3_assets.bucket_id
    S3_BUCKET_PRIVATE              = module.s3_files.bucket_id
    S3_BUCKET_OUTPUTS              = module.s3_exports.bucket_id
    S3_BUCKET_EXPORTS              = module.s3_exports.bucket_id
    ASSETS_CDN_URL                 = var.enable_cloudfront ? "https://${module.cloudfront[0].distribution_domain_name}" : ""
    API_BASE_URL                   = var.app_domain != "" ? "https://${var.app_domain}" : "http://${module.alb.alb_dns_name}"
    WEB_BASE_URL                   = var.app_domain != "" ? "https://${var.app_domain}" : "http://${module.alb.alb_dns_name}"
  }

  secrets = {
    DATABASE_URL         = module.rds.database_url_secret_arn
    SECRET_KEY_BASE      = module.secrets.secret_arns["secret_key_base"]
    AI_WORKER_TOKEN      = module.secrets.secret_arns["worker_auth_token"]
    MESHY_API_KEY        = module.secrets.secret_arns["meshy_api_key"]
    MESHY_WEBHOOK_SECRET = module.secrets.secret_arns["meshy_webhook_secret"]
  }

  task_policy_json   = data.aws_iam_policy_document.avatar_worker.json
  enable_task_policy = true
  tags               = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "db_from_avatar_worker" {
  count                        = var.enable_avatar_worker ? 1 : 0
  security_group_id            = module.rds.db_security_group_id
  referenced_security_group_id = module.avatar_worker_service[0].security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  tags                         = local.tags
}

output "avatar_worker_service_name" {
  value = var.enable_avatar_worker ? module.avatar_worker_service[0].service_name : null
}
