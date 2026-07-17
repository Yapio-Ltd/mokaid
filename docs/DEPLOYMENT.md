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
## AWS deployment (prod)

### 0. Prerequisites (once)

```bash
cd infra/terraform/bootstrap
terraform init && terraform apply       # state bucket + lock table + GitHub OIDC
```

### 1. Provision infrastructure

```bash
cd infra/terraform/environments/prod
terraform init && terraform apply
```

Note the outputs: ECR URLs, CloudFront domain, Cognito IDs, ALB DNS.

### 2. Set secrets (once)

In Secrets Manager, replace the `CHANGE_ME` placeholders:

- `mokaid-prod/secret_key_base` — `mix phx.gen.secret`
- `mokaid-prod/worker_auth_token` — long random string
- `mokaid-prod/openai_api_key` — provider key

Or push from local `.env` files:

```bash
aws sso login --profile mokaid
./scripts/push-secrets-to-aws.sh
```

### 3. Build & push images

Preferred path: push to the `prod` branch — GitHub Actions builds and deploys automatically.

Manual alternative:

```bash
aws ecr get-login-password | docker login --username AWS --password-stdin <account>.dkr.ecr.<region>.amazonaws.com

docker build -f infra/docker/api.Dockerfile -t <ecr>/mokaid-api:v1 .
docker build -f infra/docker/ai-worker.Dockerfile -t <ecr>/mokaid-ai-worker:v1 .
docker push <ecr>/mokaid-api:v1 && docker push <ecr>/mokaid-ai-worker:v1

# Point services at the new tag
terraform apply -var api_image_tag=v1 -var worker_image_tag=v1
```

### 4. Run migrations

Handled automatically by `.github/workflows/deploy.yml`. Manual:

```bash
aws ecs run-task --cluster mokaid-prod \
  --task-definition mokaid-prod-api \
  --overrides '{"containerOverrides":[{"name":"mokaid-prod-api","command":["bin/mokaid","eval","Mokaid.Release.migrate()"]}]}' \
  --launch-type FARGATE --network-configuration '...'
```

## CI/CD

`.github/workflows/ci.yml` runs typecheck/lint/tests for all three apps + `terraform fmt/validate` on every PR and on pushes to `main` / `prod`. Docker builds run on `main` and `prod`.

`.github/workflows/deploy.yml` deploys API + AI worker + web to ECS when CI succeeds on the `prod` branch. Enable it once:

```bash
cd infra/terraform/bootstrap
terraform init && terraform apply   # creates GitHub OIDC role
# copy output github_deploy_role_arn into GitHub:
gh secret set AWS_DEPLOY_ROLE_ARN --repo Yapio-Ltd/mokaid
gh variable set AWS_DEPLOY_ENABLED --repo Yapio-Ltd/mokaid --body true
```

Then push to `prod` (or re-run **Deploy to AWS** from the Actions tab).

## Rollback

- API/worker/web: re-deploy the previous immutable ECR image tag via ECS task definition.
- DB: migrations are additive by convention; restore from RDS snapshot if required.
