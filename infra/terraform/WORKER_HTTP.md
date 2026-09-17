# Private worker HTTP endpoint

Voice and text coordination need synchronous API-to-worker HTTP. Missions keep
using `AI_DISPATCH_QUEUE_URL` / `AI_RUNS_QUEUE_URL` and SQS. Production's endpoint
is `http://ai-worker.mokaid-prod.internal:8100`.

The stack creates a private Cloud Map namespace attached to the application VPC,
an `ai-worker` service with multivalue A records (10-second TTL), and one ingress
rule allowing TCP 8100 only from the API task security group. The existing worker
ECS service registers its task addresses. There is no worker public IP, public DNS
record, or ALB listener. Authentication retains the existing shared Secrets
Manager references (`AI_WORKER_TOKEN` and `WORKER_AUTH_TOKEN`); secret values are
not needed for this deployment.

## Bootstrap an existing production service

Application task revisions belong to CI. The ECS service module ignores
`task_definition` and `desired_count` changes from Terraform. A networking rollout
must preserve the worker's currently deployed task definition.

Use a saved, reviewed plan for these three resources only:

```sh
AWS_PROFILE=mokaid terraform -chdir=infra/terraform/environments/prod plan \
  -target=module.stack.aws_service_discovery_private_dns_namespace.workers \
  -target=module.stack.aws_service_discovery_service.worker \
  -target=module.stack.aws_vpc_security_group_ingress_rule.worker_from_api \
  -out=/private/tmp/mokaid-worker-http.tfplan
```

Inspect the plan's resource addresses/actions before applying. The expected
changes are exactly three creates; existing SG/VPC dependencies should be no-ops.
Stop on any deletion, replacement, unrelated change, or task-definition change.
Keep the saved plan and any full JSON outside Git: plans can contain state data.
After reviewing the saved plan, apply that exact file with the same profile.

Register the newly created Cloud Map service on the **existing** worker service
using `aws ecs update-service --cluster mokaid-prod --service
mokaid-prod-ai-worker --service-registries registryArn=<created-service-ARN>` with
profile `mokaid`, region `il-central-1`. Do not supply `--task-definition`, desired
count, network overrides, or `--force-new-deployment`. Adding the registry itself
starts a rolling deployment using the current task definition. This operation
matches the Terraform `service_registry` declaration; a later refresh reconciles
its state. Wait for ECS stability and Cloud Map instance registration before
rolling out the API's `AI_WORKER_URL` through CI.

Do not target the entire worker module for this bootstrap. Targeting its ECS
service also traverses the Terraform task-definition and IAM dependencies. Even
though `ignore_changes` prevents attaching an older task definition, an apply may
register an unnecessary revision from stale Terraform image/environment inputs.

For a fresh stack, a normal reviewed Terraform apply sets up the registry and API
environment together. For an existing stack, Terraform changing the API task
definition alone will not update the running API service: CI must include the
private URL in its task-definition environment update.

## Verification

1. Confirm worker ECS stability, the intended registry ARN, and unchanged task
   definition during the networking-only rollout.
2. Confirm Cloud Map instances contain private task addresses.
3. Confirm the API release has the exact URL and retains the original queue URL.
4. Exercise an authenticated coordinator request through the public API and
   inspect its result. ECS stability alone does not prove VPC DNS/HTTP reachability.
5. Confirm queued mission dispatch still uses SQS.

The existing shared worker token remains required for coordinator requests.

## Offline checks

With the locked providers installed:

```sh
terraform -chdir=infra/terraform/environments/prod validate
terraform -chdir=infra/terraform/modules/ecs-service init -backend=false
terraform -chdir=infra/terraform/modules/ecs-service test
terraform -chdir=infra/terraform/modules/stack init -backend=false
terraform -chdir=infra/terraform/modules/stack test -filter=tests/worker_http.tftest.hcl
```

The tests use mocked providers, do not contact AWS, and do not alter remote state.
They cover opt-in registry behavior, private networking, rolling-deployment
safeguards, ARN validation, production DNS, and SG-only worker ingress.
