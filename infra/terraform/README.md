# mokaid — Terraform infrastructure

Full AWS infrastructure for mokaid, organized as reusable modules composed per environment.

## Layout

```txt
terraform/
  bootstrap/        One-time: S3 state bucket + DynamoDB lock table (local state)
  modules/
    vpc/            VPC, public/private subnets, IGW, NAT
    alb/            Application Load Balancer + target group (WebSocket-ready)
    ecr/            Container registries (api, ai-worker, web)
    ecs-service/    Fargate service + task/execution roles + autoscaling
    rds-postgres/   PostgreSQL 16 (pgvector via migration), KMS, backups
    s3-bucket/      Hardened bucket (BPA, versioning, SSE-KMS, lifecycle)
    cloudfront/     CDN for SPA + 3D assets (OAC, SPA routing)
    cognito/        User Pool + web client + hosted UI domain
    sqs/            AI runs queue + DLQ
    secrets/        Secrets Manager + SSM parameters
    monitoring/     CloudWatch alarms, SNS, monthly budget
    stack/          Composition of all the above for one environment
  environments/
    dev/            Cost-optimized (t4g.micro, single NAT, 1 task)
    staging/        Production-like, smaller sizing
    production/     HA (multi-AZ RDS, 2 NAT, 2+ API tasks)
```

## Usage

```bash
# 1. Bootstrap the remote state (once per AWS account)
cd infra/terraform/bootstrap
terraform init && terraform apply

# 2. Deploy an environment
cd ../environments/dev
terraform init
terraform plan
terraform apply
```

After the first apply:

1. Set real secret values in Secrets Manager (`secret_key_base`, `worker_auth_token`, `openai_api_key`).
2. Build & push Docker images to the ECR repositories from the outputs.
3. Upload the web build to the `mokaid-app-*` bucket, 3D assets to `mokaid-assets-3d-*`.

## Conventions

- All resources are tagged `Project=mokaid`, `Owner=Yapio`, `ManagedBy=Terraform`.
- State: S3 `mokaid-terraform-state` with DynamoDB locking (`mokaid-terraform-locks`).
- Databases and services live in private subnets only; ingress via ALB/CloudFront.
