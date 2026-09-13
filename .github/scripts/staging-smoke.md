# Ephemeral release-image staging

`python3 .github/scripts/staging_smoke.py` is a pre-deployment gate, not a
production deployment. It uses a disposable local Docker bridge marked
`--internal`, a fresh PostgreSQL/pgvector database, and the exact API and web
image content selected for the production release. It creates no AWS resources.

## Workflow contract

- Required `API_IMAGE`, `WEB_IMAGE`: `repository@sha256:<64 lowercase hex>`.
  Local validation also accepts `sha256:<64 lowercase hex>` image IDs already
  present in the Docker daemon. Tags, partial IDs and missing images fail closed.
- Optional `CRM_IMAGE`: same immutable contract; adds CRM startup/login HTML.
- Optional `MOKAID_DESKTOP_ONLY_BUSINESS`: literal `true` or `false`, default
  `false`. This is not the signed-desktop readiness gate; the release workflow
  must enforce that gate independently before enabling the production flag.
- Optional `STAGING_TIMEOUT_SECONDS`: 60–900, default 420, **per readiness phase**.
  Docker operations and the Node verifier have additional bounded timeouts.
- Optional `STAGING_DIAGNOSTICS_DIR`: failure-report directory. Defaults to the
  OS temporary directory. Reports have unique names and mode 0600.
- No arguments, custom Elixir, database URLs, AWS/provider credentials, container
  names, networks or port inputs are accepted. Ambient production environment
  variables are not forwarded to containers. Fixture secrets are generated in
  memory and passed as process environment, never in command-line arguments.

Requires Python 3.11+, Docker with a **local Unix-socket daemon**, and OpenSSL on
the runner. Remote Docker contexts and TCP endpoints are rejected before image
pulls or resource creation. The job needs permission to pull the exact image references, but the
containers do not receive the runner's registry credentials. Pulls happen before
the isolated network is created. All image references resolve to content IDs;
the created containers' actual image IDs and sole network are checked.

Run after scans of those same immutable image digests and before registering or
updating ECS task definitions. A failed smoke or incomplete cleanup returns 1;
only full success returns 0. Do not use `continue-on-error` or replace this gate
with a different build. Keep workflow concurrency protection for production.

```sh
API_IMAGE=registry.example/api@sha256:... \
WEB_IMAGE=registry.example/web@sha256:... \
CRM_IMAGE=registry.example/crm@sha256:... \
STAGING_DIAGNOSTICS_DIR="$RUNNER_TEMP/mokaid-staging-diagnostics" \
python3 .github/scripts/staging_smoke.py
```

The ellipses are documentation placeholders, deliberately invalid as inputs.

## What runs and what is verified

1. A unique PostgreSQL 16/pgvector container, with no published database port.
   Database name is always `mokaid_staging_test`. A fresh one-day self-signed TLS
   certificate is copied into that disposable container; its private temporary
   host directory is immediately removed. Passwords are generated afresh.
2. The production API release executes a **fixed isolation prelude**, followed
   by the real `Mokaid.Release.migrate()`. A nonzero exit, OOM, timeout, missing
   completion marker or missing schema prevents API startup. No generic seed,
   user fixture, payment, upload or AI job is requested.
3. The same API image executes that prelude followed by the real
   `Application.ensure_all_started(:mokaid)`. The production repository's TLS
   setting is preserved. SQL verifies the expected database, applied migrations
   and `pg_stat_ssl.ssl = true` for the live connection.
4. API health must return its real successful payload. `/api/me` and the
   authenticated desktop-consent request endpoint must return 401 anonymously.
5. The exact web image runs its normal entrypoint. The existing
   `verify-production.mjs` checks prerendered public HTML, canonical URLs,
   sitemap, noindex/no-store private pages, and unknown-route 404. Nginx does
   not proxy the API locally, so API checks are deliberately separate.
6. If supplied, the exact CRM image runs its normal entrypoint and must serve
   real `/login` HTML successfully. This does not assert an authenticated CRM
   workflow or desktop admin parity.

No ports are published, including the API/web ports. A pinned Node verifier
shares each target container's network namespace and calls `127.0.0.1` there.
The verifier has no fixture credentials, receives no extra network and runs
read-only as a non-root user with all capabilities dropped. This works with
Docker 29's internal-only bridges, which do not activate requested published
ports ([upstream report](https://github.com/moby/moby/discussions/53256)). The
web verifier source is loaded unchanged from `verify-production.mjs`; its
documented local-origin environment is the only override. Redirects are
disabled and no host proxy settings are inherited. Containers
have bounded memory, CPU, process count and log rotation; API capabilities are
dropped and all containers use no-new-privileges.

### Isolation prelude is intentionally different from production

There is no custom endpoint, patched source or fake successful response. The
release runs its production configuration and code, but its fixed prelude turns
Oban into manual mode with queues/plugins disabled, disables AI dispatch and
provider settings, and replaces Req/ExAws transports with immediate errors.
The internal Docker network additionally prevents outbound connections.

`Release.migrate()` currently also performs catalog/logo seeding. Catalog DB
writes can occur in the disposable database; attempted S3 logo writes fail
locally through the disabled transport. Such expected nonfatal seed errors do
not prove S3 access and do not replace production migration verification.

Consequently, this gate proves packaging, schema migrations on an empty
pgvector database, production-config parsing, API boot/anonymous auth guards,
and actual web delivery. It **does not** prove upgrades from a production data
snapshot, real Cognito login, worker/AI jobs, payment flows, email, OAuth
providers, IAM, RDS certificate verification, S3, ECS networking, ALB routing,
CloudFront or clean-machine desktop installers. Worker image scans remain
separate; the worker is not staged here. Production smoke and rollback are
still required. No automatic database rollback is attempted.

## Cleanup and diagnostics

Every network/container name contains a random UUID and an ownership label.
Creation attempts are tracked before invoking Docker. Cleanup runs in reverse
order on normal completion, failure, Ctrl-C and SIGTERM. It re-inspects ownership
and removes **only exact matching IDs**, including those containers' anonymous
volumes. It never uses prune, wildcard deletion or an existing service name.
Foreign/replaced objects are preserved and cleanup failure makes the gate fail.

Failure reports include image references/IDs, completed checks, exit status,
OOM flags and bounded log tails. Generated secrets and database URLs are
redacted; complete inspect responses and container environments are never
written. Keep these diagnostic artifacts private with short retention even
though they contain no production data. Disposable containers are not retained
on failure. After forced runner termination/SIGKILL, an operator may need to
inspect the exact UUID ownership label reported for the run before removing
orphaned resources; do not prune unrelated containers.

PostgreSQL image pin verified from the upstream publisher's Docker Hub metadata
on 2026-09-14: [`pgvector/pgvector:pg16`](https://hub.docker.com/v2/repositories/pgvector/pgvector/tags/pg16),
multi-architecture digest
`sha256:ccc6e83d6e35e931dc7c5def2022729d5a6c370318d099181995567ff1fb4d6b`.
Node 22 Bookworm Slim uses the official multi-architecture digest
`sha256:83f487e0a63425e5b4d146fb5e5be574bcbe1b7b843d3ebafdd95eaf7767a7e5`,
verified from [Docker Hub metadata](https://hub.docker.com/v2/repositories/library/node/tags/22-bookworm-slim)
on the same date.
Changing the pin requires rerunning unit and real-image smoke tests.

## Tests

```sh
python3 -m unittest discover -s .github/scripts/tests -p 'test_staging_smoke.py' -v
```

These mocked safety tests do not require Docker. Actual local image test
results are recorded below separately, so unit checks cannot be mistaken for
a real release-image staging pass.

### Local execution evidence — 2026-09-14

Full API + WEB + CRM smoke passed on Colima/Docker 29.5.2, Linux ARM64, using:

- API `sha256:43cbf2db34e148ff49bda75561aaccef5a411fd5b54d7181e02d9962ae61126f`.
- WEB `sha256:b2506e66a24e7591790c43f85db93a3b593456445db8993b2b5e50eddf6a8f92`.
- CRM `sha256:66aeebf9d26e6f770e50beb2886f08b9df1b03dc173c64748c3cacbbacae6383`.
- PostgreSQL and Node verifier pins recorded above.

Real release migrations, schema/TLS query, API health, both anonymous 401
checks, the unchanged production web verifier, and actual CRM `/login` HTML
all passed. The CRM was built from `infra/docker/crm.Dockerfile` without source
changes; Next.js compilation, type/lint checks and 17-page generation passed.
Subsequent
Docker inventory checks found **zero** containers and networks with the
staging ownership label. The disposable database volume was removed through
its owning container's `docker rm --volumes`; pre-existing local UI-validation
services and their PostgreSQL data were untouched.

Seventeen staging safety unit tests and the existing 39 ECS/dispatch tests
passed (56 total). Earlier smoke attempts failed closed on unavailable local
image IDs, Docker's internal-network publishing behavior, and the verifier's
canonical port-80 origin check; each owned-resource cleanup completed. The
final harness fixes those integration issues without relaxing isolation.

The CRM build's npm install reported six dependency vulnerabilities (one
moderate, four high, one critical). This functional pass does not clear those
security findings or weaken the release scan gate. Linux AMD64 and all three exact
CI release digests must still pass in the deployment workflow. No AWS,
production database, worker execution or external provider validation is
claimed by this local result.
