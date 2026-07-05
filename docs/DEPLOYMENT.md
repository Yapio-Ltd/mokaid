# Deployment

## Local development

```bash
make dev          # docker compose: postgres, minio, api, ai-worker, web
# or run apps natively:
make db.setup
make api.dev      # Phoenix on :4000
make ai.dev       # FastAPI on :8000
make web.dev      # Vite on :3000
```

Demo login: `tom@mokaid.app` / `mokaid-demo` (seeded).

## AWS deployment (per environment)

### 0. Prerequisites (once)

```bash
cd infra/terraform/bootstrap
terraform init && terraform apply       # state bucket + lock table
```

### 1. Provision infrastructure

```bash
cd infra/terraform/environments/dev     # or staging / production
terraform init && terraform apply
```

Note the outputs: ECR URLs, CloudFront domain, Cognito IDs, ALB DNS.

### 2. Set secrets (once per environment)

In Secrets Manager, replace the `CHANGE_ME` placeholders:

- `mokaid-<env>/secret_key_base` — `mix phx.gen.secret`
- `mokaid-<env>/worker_auth_token` — long random string
- `mokaid-<env>/openai_api_key` — provider key

### 3. Build & push images

```bash
aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com

docker build -f infra/docker/api.Dockerfile -t <ecr>/mokaid-api:v1 .
docker build -f infra/docker/ai-worker.Dockerfile -t <ecr>/mokaid-ai-worker:v1 .
docker push <ecr>/mokaid-api:v1 && docker push <ecr>/mokaid-ai-worker:v1

# Point services at the new tag
terraform apply -var api_image_tag=v1 -var worker_image_tag=v1
```

### 4. Run migrations

```bash
aws ecs run-task --cluster mokaid-<env> \
  --task-definition mokaid-<env>-api \
  --overrides '{"containerOverrides":[{"name":"mokaid-<env>-api","command":["bin/mokaid","eval","Mokaid.Release.migrate()"]}]}' \
  --launch-type FARGATE --network-configuration '...'
```

### 5. Deploy the SPA

```bash
VITE_API_URL=https://api.<domain> VITE_WS_URL=wss://api.<domain> npm run build --workspace=apps/web
aws s3 sync apps/web/dist s3://mokaid-app-<env>-<account>/ --delete
aws cloudfront create-invalidation --distribution-id <id> --paths "/*"
```

## CI/CD

`.github/workflows/ci.yml` runs typecheck/lint/tests for all three apps + `terraform fmt/validate` on every PR, and Docker builds on `main`.

`.github/workflows/deploy.yml` deploys API + AI worker to ECS on `main` after CI succeeds. Enable it once:

```bash
cd infra/terraform/bootstrap
terraform init && terraform apply   # creates GitHub OIDC role
# copy output github_deploy_role_arn into GitHub:
gh secret set AWS_DEPLOY_ROLE_ARN --repo Tomyshh/mokaid
gh variable set AWS_DEPLOY_ENABLED --repo Tomyshh/mokaid --body true
```

Then re-run **Deploy to AWS** from the Actions tab (or push to `main`).

## Rollback

- API/worker: `terraform apply` with the previous image tag (immutable ECR tags).
- SPA: re-sync the previous build artifact + CloudFront invalidation.
- DB: migrations are additive by convention; restore from RDS snapshot if required.
