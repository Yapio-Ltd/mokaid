# Regional ALB access policy

This module retains the existing regional WAF ACL and ALB association. Its
default action is the existing branded **403 Block** response. It does not
change application authentication, permissions, sessions, ALB routing or DNS.

## Inputs and rules

| Input | Default | Meaning |
| --- | --- | --- |
| `name` | Required | Existing ACL name; production keeps `allow-israel-only`. |
| `alb_arn` | Required | Exact ALB receiving the existing association. |
| `allowed_country_codes` | `["IL", "FR"]` | Existing geo Allow, priority 0, metric `allowGeo`. |
| `geo_exempt_path_prefixes` | `["/api/webhooks/"]` | Existing global webhook-path Allow, priority 1, metric `allowWebhookPaths`; endpoints still authenticate requests themselves. |
| `globally_allowed_hosts` | `[]` | Opt-in set of exact Hosts allowed from any country; empty adds no rule. |
| `tags` | `{}` | Tags for the existing ACL. |

The outputs `web_acl_arn` and `web_acl_id` are unchanged. The module requires
Terraform 1.10+ and AWS provider 5.x (minimum 5.100), locked at 5.100.0 with
checksums for reproducible validation. The production root owns its remote, encrypted,
locked state; this module introduces no backend or state migration.

Each global Host gets a separate ByteMatch Allow rule using **`EXACTLY`** on
`single_header { name = "host" }` and the `LOWERCASE` transformation. No suffix
match, wildcard, `X-Forwarded-Host`, URI-path shortcut or broad default Allow is
introduced. A rule does not depend on request path, so the selected site's API
and WebSocket paths are covered on that same Host.

Inputs must be lowercase ASCII DNS names with 1–63-character labels and an
alphabetic first character in the final label. IP literals, wildcard labels,
Unicode, schemes, ports, paths, trailing dots and whitespace are rejected.
ASCII validation makes the 200-character maximum also the AWS ByteMatch
[200-byte SearchString limit](https://docs.aws.amazon.com/waf/latest/APIReference/API_ByteMatchStatement.html).
Use an explicitly reviewed ASCII/Punycode hostname if an internationalized
domain is ever needed; the module does not normalize or expand an input.

Priorities are `10 + index` of the sorted Host set, distinct from the existing
rules. Each rule name and metric uses the first 16 SHA256 hex characters of
its exact hostname. Ordering/duplicates in input cannot rename rules or
metrics; adding an earlier sorted Host can shift their numerical priorities,
without changing their relative evaluation or scope. A single Host works
without an `OrStatement` (AWS requires at least two operands for that form).

## Production opt-in and boundaries

The stack's `waf_globally_allowed_hosts` defaults to `[]`. Only the production
root opts in with `[var.app_domain]`, currently `["mokaid.com"]`. Development
and other callers remain unchanged unless explicitly configured.

From a country outside IL/FR, a normal `Host: mokaid.com` (including uppercase
spelling after the case transformation) gains site/API access. These Hosts do
**not** match the added rule: `crm.mokaid.com`, `www.mokaid.com`, the ALB DNS
hostname, `mokaid.com.evil.example`, `mokaid.com:443`, `mokaid.com.` or a missing
Host. The unchanged geo and webhook rules can still allow requests that meet
their pre-existing conditions; this change is not a new deny rule for them.

Host is routing input, **not proof of identity**: a client connecting directly
to the ALB can intentionally send the public Host and reach the public target.
The ALB's CRM Host rule must continue to require `crm.mokaid.com`, so supplying
the public Host must not route to the CRM. Browser/native users and operators
remain subject to the existing backend authentication and permissions. A WAF
Host Allow also covers any future paths on that public Host; protected API
routes must never depend solely on geography.

The rule does not enable CloudFront, open other origins, change certificates,
or guarantee DNS reachability. Explicit ports/trailing-dot requests are
intentionally outside this exception. Live WAF/ALB HTTP normalization,
duplicate Host handling, DNS/TLS routing and actual geographic behavior need
separate runtime checks; mock tests below are not claims about those layers.

## Offline-safe validation

From this module, with the pinned provider already installed or available via
the official registry:

```sh
terraform fmt -check -recursive
terraform init -backend=false -input=false -lockfile=readonly
terraform validate
tflint --init
tflint
AWS_EC2_METADATA_DISABLED=true terraform test -no-color
```

`tests/host_access.tftest.hcl` uses **only `mock_provider "aws"` and `command =
plan`**. There are no live data sources, AWS calls, cloud resources or
production state reads. Tests inspect the real planned WAF statements and
cover default-closed global access, exact Host matching, misleading Host and
forwarded-header cases, existing geo/webhooks/default403/association,
deterministic priorities/names/metrics, empty webhook configuration, the
200-byte boundary and invalid input rejection. The request examples evaluate
the asserted EXACTLY/LOWERCASE semantics; they do not emulate AWS networking.

For local offline init, `-plugin-dir` can point to an already checksum-verified
provider mirror. No credentials are required. Terraform/tflint plugins need
local IPC sockets even with a mocked provider.

## Change review and rollback

No apply is part of these tests. Before rollout, the operator must inspect the
production plan: only an in-place update to the intended ACL is expected from
this feature, with its name, association, existing rules and default403 intact.
Coordinate with any other pending Terraform changes; do not apply an entire
unreviewed stack plan. After the approved apply, check the public Host and
unauthenticated API responses plus negative CRM/ALB/forwarded-Host routing.

To withdraw worldwide access, change production's Host set back to `[]`,
review the resulting plan and apply it through the same approved process.
This removes only the new Host rules and restores the former geo/webhook
policy, without deleting or replacing the ACL. No application permissions,
database rollback or global network reset is involved.
