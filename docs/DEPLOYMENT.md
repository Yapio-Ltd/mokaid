## Operator CRM secrets (Admin API keys)

Provider **Admin** keys (OpenAI `sk-admin-…`, Anthropic `sk-ant-admin-…`) power the
CRM cost dashboards. They are **never** used for inference and must stay on the
API task only.

```bash
# 1) Create/rotate NEW admin keys in the OpenAI / Anthropic consoles
#    (revoke any key that was pasted in chat or logs).

# 2) Ensure Terraform secrets exist, then push values interactively:
aws sso login --profile mokaid
cd infra/terraform/environments/prod && terraform apply   # creates secret shells
./scripts/push-secrets-to-aws.sh --admin-keys             # silent paste, never logged

# 3) Redeploy API so the new env vars are injected:
aws ecs update-service --cluster mokaid-prod --service mokaid-prod-api --force-new-deployment

# 4) In CRM → Coûts → Synchroniser (or wait for the nightly Oban jobs).
```

Do **not** commit keys to git, Terraform state, GitHub Actions logs, or chat.

---

# Deployment

## Local development

```bash
make dev          # docker compose: postgres, minio, api, ai-worker, web
# or run apps natively:
make db.setup
make api.dev      # Phoenix on :4000
make ai.dev       # FastAPI on :8000
make web.dev      # Vite on :3000
make crm.dev      # Next.js operator CRM on :3001
```

## Operator CRM (`crm.mokaid.com`)

The CRM is a Next.js app (`apps/crm`) that uses the same Phoenix API with
platform-admin endpoints under `/api/admin/*`.

### Local

```bash
# Terminal 1 — API
make api.dev

# Terminal 2 — CRM (proxies /api → localhost:4000 when NEXT_PUBLIC_API_URL is empty)
make crm.dev

# Provision your platform operator once (password via env — never commit it):
PLATFORM_ADMIN_PASSWORD='…' ./scripts/provision-platform-admin.sh
# default email: tomyy4136@gmail.com (override with PLATFORM_ADMIN_EMAIL)
```

Login at http://localhost:3001/login with a user that has `is_platform_admin = true`.

### AWS

Infra (Terraform):

1. Create ECR repo `mokaid-crm` (bootstrap):
   `cd infra/terraform/bootstrap && terraform apply`
2. Ensure the ALB ACM certificate includes **SAN `crm.mokaid.com`** (same cert as `mokaid.com` or additional certificate on the HTTPS listener).
3. DNS: CNAME/ALIAS `crm.mokaid.com` → ALB DNS name (`terraform output alb_dns_name`).
4. `cd infra/terraform/environments/prod && terraform apply` — deploys ECS service `mokaid-prod-crm` and host-based ALB rules:
   - `crm.mokaid.com` + `/api/*` → API
   - `crm.mokaid.com` (default) → CRM
5. CORS includes `https://crm.mokaid.com` automatically via `crm_domain`.

Deploy: GitHub Actions builds `mokaid-crm` on `prod` and rolls the ECS service.

Platform admin in production (one-shot ECS eval, password never stored in git):

```bash
# Example — replace network config with the API task's subnets/SGs
aws ecs run-task --cluster mokaid-prod \
  --task-definition mokaid-prod-api \
  --launch-type FARGATE \
  --network-configuration '...' \
  --overrides '{
    "containerOverrides": [{
      "name": "mokaid-prod-api",
      "command": ["bin/mokaid","eval","Mokaid.Release.provision_platform_admin(System.get_env(\"PLATFORM_ADMIN_EMAIL\"), System.get_env(\"PLATFORM_ADMIN_PASSWORD\"))"],
      "environment": [
        {"name":"PLATFORM_ADMIN_EMAIL","value":"tomyy4136@gmail.com"},
        {"name":"PLATFORM_ADMIN_PASSWORD","value":"<from-secrets-manager>"}
      ]
    }]
  }'
```

## AWS deployment (prod)

### 0. Prerequisites (once)

```bash
cd infra/terraform/bootstrap
terraform init && terraform apply       # state bucket + lock table + GitHub OIDC + ECR
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
- `mokaid-prod/stripe_secret_key` — Stripe secret key (`sk_…`)
- `mokaid-prod/stripe_publishable_key` — Stripe publishable key (`pk_…`)
- `mokaid-prod/stripe_webhook_secret` — Stripe webhook signing secret (`whsec_…`)

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
docker build -f infra/docker/web.Dockerfile -t <ecr>/mokaid-web:v1 .
docker build -f infra/docker/crm.Dockerfile -t <ecr>/mokaid-crm:v1 .
docker push <ecr>/mokaid-api:v1 && docker push <ecr>/mokaid-ai-worker:v1
docker push <ecr>/mokaid-web:v1 && docker push <ecr>/mokaid-crm:v1
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

`.github/workflows/ci.yml` runs typecheck/lint/tests for web, CRM, API, worker + `terraform fmt/validate` on every PR and on pushes to `main` / `prod`. Docker builds run on `main` and `prod`.

`.github/workflows/deploy.yml` deploys API + AI worker + web + CRM to ECS when CI succeeds on the `prod` branch. Enable it once:

```bash
cd infra/terraform/bootstrap
terraform init && terraform apply   # creates GitHub OIDC role
# copy output github_deploy_role_arn into GitHub:
gh secret set AWS_DEPLOY_ROLE_ARN --repo Yapio-Ltd/mokaid
gh variable set AWS_DEPLOY_ENABLED --repo Yapio-Ltd/mokaid --body true
```

Then push to `prod` (or re-run **Deploy to AWS** from the Actions tab).

## Rollback

- API/worker/web/CRM: re-deploy the previous immutable ECR image tag via ECS task definition.
- DB: migrations are additive by convention; restore from RDS snapshot if required.
