# Custom character worker

Custom characters are prepared on a dedicated ECS Fargate service. The API's
current Terraform configuration is 256 CPU units / 512 MiB and must not run
Blender. These are repository settings, not a verification of the live service.

## Isolation and defaults

- The reusable stack defaults to `enable_avatar_worker = false`. The explicitly
  approved production rollout is recorded as `true` in `avatars.auto.tfvars`;
  the service is provisioned only when that reviewed infrastructure plan is applied.
- Production API processes use `MOKAID_AVATAR_WORKER_MODE=api`, which excludes the
  `avatars` queue. Paid creation is disabled unless
  `MOKAID_AVATAR_PIPELINE_ENABLED=true`.
- The worker uses the same API release image, with `MOKAID_AVATAR_WORKER_MODE=worker`.
  Only `avatars: 1` runs; Cron/Pruner plugins and the HTTP listener are disabled.
- Worker allocation: **1 x86 vCPU, 4 GiB RAM, one task**. Autoscaling stays at one;
  deployments stop the old task before starting its replacement so two renderer
  jobs cannot overlap. Shutdown allows 110 seconds inside a 120-second ECS stop window.
- Private subnets, no public IP, no ALB and no inbound worker security-group rule.
  It can reach Postgres and make outbound requests through the existing NAT.
  Its task role only accesses avatar-reference uploads and generated-character
  assets; OAuth, provider-admin and payment secrets are not copied to this service.

`PHX_SERVER=false` is parsed as false. Worker mode disables the listener even if
an inherited image environment contains `PHX_SERVER=true`.

## Interrupted jobs

The API runs `Mokaid.Avatars.RecoveryWorker` on its `default` queue every five
minutes. It uses Oban's rescue operation only for avatar generation and repair
jobs on the `avatars` queue that have been executing for more than 30 minutes.
This exceeds the 600-second Blender and 120-second native conversion limits,
with time for downloads and storage. Other workers and queues are untouched.

Jobs with attempts remaining become available again; the avatar worker then
applies the existing generation claim checks. An unresolved paid submission is
never resubmitted. Local preparation can resume from its saved upstream task.
Exhausted jobs are discarded by Oban. If a generation is still active, has a
terminal generation job, and has no incomplete avatar job, recovery locks its
row, marks it failed, and issues the existing idempotent credit refund. Ready
characters and repair-only jobs never trigger a credit refund or asset changes.
No global Lifeline plugin is enabled.

## Image and executable contract

The API remains Linux ARM64. The avatar worker uses Linux AMD64 because the
[official Blender 5.2.0 manifest](https://download.blender.org/release/Blender5.2/blender-5.2.0.sha256)
does not publish a Linux ARM64 binary. Both variants share one immutable image
manifest. The AMD64 build verifies this archive SHA-256 before extracting it:

```text
blender-5.2.0-linux-x64.tar.xz
96f6c181a30f4950607839dc84d42a354b250d8a0231b098b59b7bc69c351c48
```

The ARM64 image deliberately has no Blender executable. Do not assign worker
mode to it or substitute an old distro Blender package.

| Environment | Value in the image |
| --- | --- |
| `MOKAID_AVATAR_BLENDER` | `/opt/blender/blender` |
| `MOKAID_AVATAR_PREPARER` | `/opt/avatar-preparer/prepare-custom-avatar.py` |
| `MOKAID_AVATAR_PYTHON` | `/usr/bin/python3` |
| `MOKAID_AVATAR_PROCESS_RUNNER` | `/opt/avatar-preparer/avatar-process-runner.py` |
| `MESHY_NATIVE_COOKER` | `/opt/avatar-cooker/cook-custom.mjs` |
| `MESHY_NODE_BIN` | `/usr/local/bin/node` |

The preparer includes `blender-avatar-quality.py`, `blender-avatar-life.py` and
`validate-avatar-life.py`. The independent `avatar-preparer` Docker stage imports
all four Blender scripts with the actual pinned Linux binary, without DB
credentials or generation-provider calls. The Node cooker includes both
`surface-kinds.mjs` and `character-normals.mjs` and is import-checked in the final image.

```sh
docker buildx build --platform linux/amd64 --target avatar-preparer \
  -f infra/docker/api.Dockerfile --load -t mokaid-avatar-preparer:check .
```

## Enable and deploy

1. Pass CI on an immutable commit. CI builds both API image architectures. Deploy
   scans both variants and runs an AMD64 headless import check with networking
   disabled before any production revision changes.
2. Review the Terraform plan using `enable_avatar_worker=true` and an
   `api_image_tag` for that verified multi-architecture commit. Infrastructure
   applies remain a separate operational action; none are performed by this change.
3. Apply the reviewed infrastructure change and verify the worker's ECS health
   check and `/ecs/mokaid-prod-avatar-worker` logs. It must report the single
   `avatars` queue with no HTTP server or unrelated queues.
4. Set the protected deployment environment variable
   `MOKAID_AVATAR_PIPELINE_ENABLED=true` only after the worker exists. The normal
   deployment workflow updates the worker to the exact scanned API image digest,
   waits for worker health, then enables creation on the API revision.
5. Run a controlled end-to-end acceptance check: one disclosed credit charge,
   validated animated GLB/native asset, dedicated head portrait, successful team
   assignment, and one refund for a deliberately failed generation. This check
   uses the generation provider and must be separately authorized if it costs credits.

Terraform deliberately ignores ECS service `task_definition` drift because CI
owns application deployments. Flipping Terraform's flag alone does not update
an existing API service revision: the protected workflow flag must match.

To stop new paid requests, set the workflow flag to false and deploy the API;
let queued jobs complete before removing the worker. Workflow failure recovery
includes the avatar worker's recorded previous revision alongside API/web/AI-worker/CRM.
When changing infrastructure, review the previous task definition and plan before
rolling back; do not destroy a worker with paid jobs still running.

## Cost and pricing limits

The worker is **always running**, including idle time; this implementation does
not scale to zero. AWS's public `il-central-1` Fargate Linux x86 prices published
2026-09-11 are $0.0518144 per vCPU-hour and $0.0056896 per GB-hour. At 730 hours:

| Allocation | Compute per month |
| --- | ---: |
| 1 vCPU / 4 GiB (configured) | **$54.44** |
| 2 vCPU / 8 GiB (comparison only) | $108.88 |

Source: [AWS regional ECS price list](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonECS/current/il-central-1/index.json).
These estimates exclude generation-provider fees, NAT/data transfer, storage,
logs, taxes and other shared services. At the configured rate, 1,000 hypothetical
five-minute jobs would represent $6.21 of active compute *if* billed only while
running; that is not the monthly bill of this always-on worker. No workload time
or end-to-end margin is guaranteed by that example.

The 1,000-credit creation tariff needs to cover the provider, failure/refund
rate, actual processing time and this idle infrastructure cost. Reassess margin
using real paid-credit revenue and measured successful generations before
increasing worker count or resources.
