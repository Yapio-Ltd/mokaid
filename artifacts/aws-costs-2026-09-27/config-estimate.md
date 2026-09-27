# AWS production configuration estimate — 27 September 2026

**Configured baseline: approximately US$142.56/month before variable usage, monitoring, tax, discounts and credits. This is not the actual AWS bill or a live resource inventory.** It assumes the current repository Terraform configuration, 730 running hours/month, one task per existing ECS service, 20 GiB RDS storage and at least three billed public IPv4 addresses. Live AWS access was pending SSO renewal when this estimate was prepared. Resources created outside Terraform, drift, autoscaling and prior revisions can change the bill.

The optional new avatar worker is disabled in the checked-in production defaults. Enabling its configured 1 vCPU / 4 GiB Linux x86 task continuously would add **$54.44/month**, plus logs and usage; the comparable baseline becomes **$197.00/month**. No infrastructure was changed for this estimate.

## Fixed configured baseline

All regional rates below are the official `il-central-1` (Israel/Tel Aviv) public On-Demand rates downloaded on 2026-09-27. Hourly components use 730 hours; AWS invoices use actual running time. Each linked JSON contains the matching usage type and price dimension.

| Service/resource | Configured quantity | Formula | Estimated USD/month | Source |
|---|---:|---|---:|---|
| ECS Fargate API | 1 ARM64 task, 0.25 vCPU / 0.5 GiB | `730 × (0.25 × 0.04145152 + 0.5 × 0.00455168)` | 9.2263 | [ECS prices](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonECS/current/il-central-1/index.json) |
| ECS Fargate web | Same | Same | 9.2263 | Same |
| ECS Fargate CRM | Same | Same | 9.2263 | Same |
| ECS Fargate AI worker | Same | Same | 9.2263 | Same |
| RDS PostgreSQL | 1 `db.t4g.micro`, Single-AZ | `730 × 0.018` | 13.14 | [RDS prices](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRDS/current/il-central-1/index.json) |
| RDS gp3 disk | 20 GiB provisioned | `20 × 0.153` | 3.06 | Same |
| NAT Gateway | 1 zonal public NAT | `730 × 0.0504` | 36.792 | [EC2/NAT prices](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/il-central-1/index.json) |
| Application Load Balancer | 1 public ALB spanning 2 AZs | `730 × 0.02646` | 19.3158 | [ELB prices](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSELB/current/il-central-1/index.json) |
| Public IPv4 | Assumed minimum 3: NAT EIP + one ALB address/AZ | `3 × 730 × 0.005` | 10.95 | [VPC prices](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonVPC/current/il-central-1/index.json) |
| Secrets Manager | 31 stack secrets + 1 RDS DSN secret | `32 × 0.40` | 12.80 | [Secrets prices](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSSecretsManager/current/il-central-1/index.json) |
| WAFv2 | 1 regional ACL, 3 rules: geo, webhook path, public host | `5 + 3 × 1` | 8.00 | [WAF prices](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/awswaf/current/il-central-1/index.json) |
| KMS | 1 customer-managed RDS key, initial key version | `1 × 1` | 1.00 | [KMS prices](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/awskms/current/il-central-1/index.json) |
| Cloud Map | 1 registered AI-worker task | `1 × 0.10` | 0.10 | [Cloud Map prices](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSCloudMap/current/il-central-1/index.json) |
| Route 53 | 1 private hosted zone created by Cloud Map | `1 × 0.50` | 0.50 | [Route 53 prices](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRoute53/current/index.json) |
| **Subtotal, using unrounded values** | | | **142.5628624** | |

The existing macOS signing secret is referenced by the enabled signing module but created outside this Terraform stack. If present, it adds **$0.40/month**, making this subtotal **$142.96** before the remaining items. No secret values were read. A snapshot-restored database can still use an older KMS key while the newly declared key exists; extra keys and rotated key versions require live verification. AWS-managed S3 KMS keys are not counted as customer-managed keys.

The ALB can allocate additional addresses as it scales, so the IPv4 figure is a minimum assumption. The four ECS task definitions default to ARM64, but their Terraform lifecycle ignores deployed task revisions and desired count; an actual deployment can differ.

## Usage-dependent services and additional charges

| Service | Repository inventory/configuration | Verified rate or cost driver; excluded from fixed subtotal |
|---|---|---|
| Fargate autoscaling/deployments | API max 2, web max 2, CRM max 2, AI worker max 3; minimum 1 each. Deployment overlap allowed. | Each additional current-sized ARM task costs $9.2263/month if continuously running. Nine tasks continuously running would cost $83.04/month for ECS alone. Fargate included ephemeral disk is not explicitly increased. |
| NAT traffic | One gateway serves both private AZs; no S3 gateway endpoint declared. | **$0.0504/GB** processed; Internet transfer and applicable inter-AZ transfer are separate. S3/image pulls/provider traffic may traverse NAT. [NAT price JSON](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/il-central-1/index.json) |
| ALB traffic | API, web, CRM target groups; HTTP/HTTPS routing | **$0.0084/LCU-hour**, determined by the applicable maximum connection/byte/rule dimension; e.g. an average 1 LCU throughout 730 h adds $6.132. [ELB price JSON](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSELB/current/il-central-1/index.json) |
| WAF requests | Three ordinary rules; no paid Bot/Fraud managed rule group declared | Base tier **$0.60/million requests**. [WAF price JSON](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/awswaf/current/il-central-1/index.json) |
| S3 | 6 application buckets: app, 3D assets, files, uploads, exports, backups; plus desktop downloads and Terraform state = **8 configured buckets** across prod/bootstrap | No fixed bucket fee. Standard storage **$0.025/GB-month** first 50 TB in Tel Aviv; PUT/COPY/POST/LIST **$0.0055/1,000**; GET/other **$0.00044/1,000**. Versioning means old versions also occupy storage. Transfer/KMS requests extra. [S3 price JSON](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonS3/current/il-central-1/index.json) |
| ECR | 4 shared repositories, basic scan-on-push, lifecycle keeps last 20 images per repository | **$0.10/GB-month** stored, plus applicable transfer. Actual compressed image bytes needed. [ECR price JSON](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonECR/current/il-central-1/index.json) |
| CloudFront | Main application CDN disabled by default. **Desktop-download distribution enabled** via `desktop.auto.tfvars`, PriceClass_100. | Pay-as-you-go bytes and requests; selected US/Europe outbound first tier **$0.085/GB**, HTTPS **$0.010/$0.012 per 10,000 requests** respectively, before allowances. Distribution count alone does not establish a monthly charge. Live plan/allowances needed. [CloudFront price JSON](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonCloudFront/current/index.json) |
| CloudWatch logs | 4 ECS log groups, 30-day retention | Standard ingestion **$0.50/GB**, archived log storage **$0.03/GB-month**, before free allowances; query scanning/API usage extra. [CloudWatch price JSON](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonCloudWatch/current/il-central-1/index.json) |
| CloudWatch metrics/alarms | Container Insights enabled. Three explicit alarms: API CPU, API memory, DB CPU. ALB 5xx alarm disabled because ARN suffix not supplied. Target tracking creates additional managed alarms. | Standard alarms **$0.10/alarm-metric-month** before allowances; the 3 explicit alarms have a $0.30 list-price subtotal. Custom metrics first tier **$0.30/metric-month**; Container Insights collected metric/log cardinality must be measured. Do not assume monitoring is free. Same JSON. |
| RDS extras | 7-day backup retention; gp3 autoscaling allowed up to 100 GiB; Performance Insights enabled; enhanced OS monitoring disabled | At 100 GiB, gp3 storage is $15.30/month instead of $3.06. Excess backups/snapshots, T4g surplus CPU credits and any chargeable monitoring settings require live usage/configuration. |
| KMS requests | RDS customer key; S3 server-side KMS encryption with bucket keys | Standard regional KMS requests **$0.03/10,000**, before global free allowance. Extra keys/rotations can add fixed charges. [KMS price JSON](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/awskms/current/il-central-1/index.json) |
| Secrets Manager requests | Tasks load secrets at startup; app may read others | **$0.05/10,000 API calls**; secret count beyond declared values needs inventory. [Secrets price JSON](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSSecretsManager/current/il-central-1/index.json) |
| SQS | 1 standard AI-run queue + 1 DLQ, SSE-SQS enabled | First 1 million monthly SQS requests free; subsequent first regional tier **$0.42/million standard requests**. Billing units include payload size and polling. [SQS price JSON](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSQueueService/current/il-central-1/index.json) |
| Cognito | 1 user pool, web client and Cognito domain. Stack `AUTH_MODE=dev_fallback`; pool still provisioned. | No estimated fixed amount; active users, tier and auth methods matter. Tel Aviv Lite **$0.0055/MAU**, Essentials **$0.015/MAU**, Plus **$0.020/MAU** first paid tier, with tier-specific free allowances. Config does not explicitly set current user-pool tier; verify live rather than infer. [Cognito price JSON](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonCognito/current/il-central-1/index.json) |
| Cloud Map / Route 53 | Private AI-worker DNS only; public desktop DNS is external (`route53_zone_id=null`) | Cloud Map discovery API **$1/million calls** if used. Queries to private Route 53 hosted zones have **no additional query charge**; do not apply public DNS query rates to this private zone. [Route 53 pricing](https://aws.amazon.com/route53/pricing/), [Cloud Map pricing](https://aws.amazon.com/cloud-map/pricing/) |
| DynamoDB | Terraform state lock table, on-demand | **$0.17/million read units**, **$0.85/million write units**; standard storage **$0.3396/GB-month** after the included tier. Usually small here, but no usage measured. [DynamoDB price JSON](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonDynamoDB/current/il-central-1/index.json) |
| SNS / Budgets | 1 alarms topic, optional email subscription (default absent); $100 monthly budget | Delivery/API usage if any. The **$100 budget is an alert threshold, not a spending cap**. No budget action or paid report declared. |
| SSM Parameter Store | 2 parameters for Cognito IDs | Standard parameters; no advanced tier or high-throughput setting declared. Any out-of-band parameters/usage require inventory. |
| IAM / ECS control plane / ACM / base VPC | IAM roles/policies/OIDC, cluster, security groups/routes/subnets/IGW, ALB certificate reference and desktop ACM public certificate | No standalone provisioned hourly instance charge is added for these configuration objects. Private CA, exportable paid certificates, paid support and other out-of-band products are not declared here. |
| Cost Explorer | API IAM grants read cost APIs for cost sync | API requests can be billable; polling frequency and actual use unknown. |

## Optional avatar worker

`modules/stack/avatar_worker.tf` declares a separately gated worker, Linux x86_64, 1 vCPU and 4 GiB, desired/min/max 1. Both stack and production variable defaults are `enable_avatar_worker=false`; it is not enabled in the reviewed auto-tfvars.

At verified Tel Aviv rates:

`730 × (1 × $0.0518144 + 4 × $0.0056896) = $54.438144/month`

This worker reuses the API repository, database, Secrets Manager values, NAT, and asset/upload buckets. It has no separate public IP or ALB. More CPU runtime, logging, image storage/pulls and generated assets are variable. Provider generation charges are outside AWS and are not included.

## Configuration evidence and scope

- `infra/terraform/environments/prod/main.tf`: region, 4-service sizes, RDS class, Single-AZ, single NAT, WAF hosts and $100 alert budget.
- `infra/terraform/environments/prod/desktop.auto.tfvars`: desktop downloads and stable signing enabled.
- `infra/terraform/modules/stack/main.tf`: six application buckets, 31 secrets, worker discovery, autoscaling limits, task environment.
- `infra/terraform/modules/ecs-service/main.tf`: default ARM64, private tasks without public IPs, 30-day log retention, task-revision/desired-count drift ignored.
- `infra/terraform/modules/rds-postgres/main.tf`: initial 20 GiB gp3, maximum 100 GiB, seven-day backups, KMS key and additional database secret.
- `infra/terraform/modules/vpc/main.tf`: two public/two private subnets, one NAT/EIP under the prod setting.
- `infra/terraform/modules/waf/main.tf`: one geo rule, one webhook-path rule and one host rule for this prod configuration.
- `infra/terraform/bootstrap/main.tf`: Terraform state bucket, DynamoDB lock table, four shared ECR repositories.
- `infra/terraform/modules/desktop-downloads/main.tf`: download S3 bucket, one CloudFront distribution, PriceClass_100.

The official source catalog publication dates range from 2026-09-11 to 2026-09-26. `selected-prices.json` beside this report retains selected public rate records, their SKUs, publication dates and source URLs for reproducibility. Full downloaded catalogs remain in `/private/tmp/mokaid-price-*.json` and `/private/tmp/mokaid-fargate-il-prices.json`.

To turn this into an actual cost report, reconcile all account regions and Cost Explorer service totals with live ECS desired/running counts and task CPU/architecture, RDS allocated storage/snapshots, public IPv4 counts, secrets/KMS keys, S3/ECR bytes, CloudWatch usage, AWS credits/free tiers, tax and support. No claim that all account resources are covered is made before that reconciliation.
