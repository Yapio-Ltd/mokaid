# API dependency security checkpoint

Validated locally on 2026-09-14 with Elixir 1.17.3, Erlang/OTP 27 and Hex 2.5.1.
This checkpoint concerns the backend dependencies and HTTP transport. It is not
a claim that the complete desktop product or production deployment is accepted.

## Targeted lock changes

The original Hex audit failed with **19 advisories in seven packages** (8 HIGH,
8 MEDIUM and 3 LOW). The resolved lock passes `mix hex.audit` with no retired
packages or security advisories, without severity filters or ignore entries.

| Package | Previous | Resolved | Relevant application surface / primary advisory |
| --- | --- | --- | --- |
| Phoenix | 1.7.23 | 1.7.24 | Authenticated Channels transport; [unbounded joins](https://github.com/phoenixframework/phoenix/security/advisories/GHSA-6983-jfq8-485w) and [Presence JavaScript handling](https://github.com/phoenixframework/phoenix/security/advisories/GHSA-63mc-hw7g-86rr). The separate npm Phoenix package must be audited independently. |
| Bandit | 1.12.0 | 1.12.5 | HTTP/WebSocket server; [HTTP/2 starvation](https://cna.erlef.org/cves/CVE-2026-74836.html), [fragmented WebSocket CPU exhaustion](https://cna.erlef.org/cves/CVE-2026-65623.html), and HTTP/2 header validation. |
| HPAX | 1.0.3 | 1.0.4 | HTTP/2 HPACK decoder used by Bandit and Mint; [unbounded integer decoding](https://cna.erlef.org/cves/CVE-2026-58226.html). |
| Mint | 1.9.0 | 1.10.0 | Outbound Req/Finch connections; [chunk buffering](https://cna.erlef.org/cves/CVE-2026-56810.html), header/trailer accumulation, HTTP/2 continuation handling, chunk parsing and [status-line/chunk-extension buffering](https://cna.erlef.org/cves/CVE-2026-82728.html). |
| Plug | 1.20.2 | 1.20.3 | The endpoint enables multipart parsing; [multipart resource exhaustion](https://cna.erlef.org/cves/CVE-2026-56814.html) and [cookie attribute injection](https://cna.erlef.org/cves/CVE-2026-56813.html). |
| Postgrex | 0.22.2 | 0.22.4 | Database driver; [stream comment validation](https://cna.erlef.org/cves/CVE-2026-66838.html) and [notification reconnect quoting](https://cna.erlef.org/cves/CVE-2026-58225.html). No direct application use of untrusted stream comments or notification channel names was found; the fixes are still installed. |
| Hackney | 1.25.0 | Removed | [SOCKS TLS upgrade timeout](https://github.com/benoitc/hackney/security/advisories/GHSA-gp9c-pm5m-5cxr), query/cookie injection and encoded-host handling. No SOCKS proxy was configured; removal does not depend on treating the advisories as inapplicable. |

Only those six versions changed. Mix removed nine unused lock entries: Hackney,
JokenJwks, Tesla, certifi, idna, metrics, mimerl, parse_trans and
unicode_util_compat. Other versions and their checksums were preserved. All new
checksums come from the authenticated Hex resolver, not handwritten lock edits.
Phoenix stays in 1.7.x; no forced major upgrade or dependency override was used.

## Official ExAws transport migration

ExAws 2.6.1 already provides `ExAws.Request.Req`, compatible with the existing
Req 0.6.2 and Finch 0.23.0. `config/config.exs` explicitly selects that adapter.
It retains ExAws binary response bodies, status/error contracts and retry
ownership; implicit redirects remain disabled for signed requests. The
integration-logo seed task starts Req rather than Hackney.

Application code had no consumer of JokenJwks or Tesla. Cognito verification
still uses Joken/Jose and retrieves JWKS with Req; those dependencies and the
authentication code are unchanged. The official adapter avoids forcing Hackney
4.x through ExAws's optional 1.x constraints.

Req returns lowercase HTTP header names. The production Storage consumer now
compares `content-type` case-insensitively, retaining its existing parameter
stripping and absent-header behavior. HTTP errors still propagate unchanged.
An actual loopback test reproduced the original regression (`image/png` became
`application/octet-stream`) before the fix, then verified PNG, PDF and HTML MIME
types afterward. No new success fallback conceals transport failures.

## Verification and audit scope

- `mix format --check-formatted`: passed across the API with Elixir 1.17.3.
- `mix compile --warnings-as-errors`: passed. A subsequent offline
  `mix deps.get` retained the exact lock checksum
  `af08fdea688dbc63383c135d487d52d56a78281fd19b4dee1d7859a70844aaf5`.
- Complete API suite: **230 tests, zero failures**, with a fresh PostgreSQL 16 /
  pgvector fixture on a Docker internal network with no Internet route, no
  published database ports and no production credentials or data.
- Eight adapter/consumer tests use real loopback HTTP plus a configuration check
  to cover S3 binary GET, PUT payloads,
  SigV4 headers, Logs JSON serialization, 403 responses, no implicit 301 redirect,
  MIME preservation and Storage error propagation. Tests changing application
  configuration run synchronously and restore the exact previous values.
- Hex 2.5.1 checks known **security advisories and retired releases**, returning
  nonzero for either. Earlier Hex versions may only cover retirement. CI and the
  API Dockerfile install Hex 2.5.1 explicitly and run this audit before compiling.
- No `ignore_advisories`, `ignore_retirements`, `HEX_IGNORE_ADVISORIES` or
  `HEX_IGNORE_RETIREMENTS` exclusions were introduced. The result is an
  advisory-database snapshot, not proof that undisclosed vulnerabilities cannot
  exist. Rerun the live audit on each build.
- Hex receives only package metadata (names/versions); neither application code,
  private credentials nor customer content is submitted. Package archives are
  downloaded through Hex's normal signature/checksum verification.
- Trivy's packaged-image scan does not identify the BEAM dependency graph in
  this release. Its OS/runtime scan complements, but cannot replace, the Hex
  audit. Its existing `--ignore-unfixed` image policy means zero **fixable**
  HIGH/CRITICAL findings, not zero unfixed vulnerabilities.

The final local API image is
`sha256:34e7d82a1923c664e8de6fb7768e8e56d72bd5792d922f485e47d63e597e130c`
(`mokaid-api:security-final`, Linux ARM64). Its clean production build passed the
Hex 2.5.1 audit and compiled the release. Trivy 0.74.0 scanned an archive of this
exact image, offline with vulnerability and secret scanners enabled, and exited
zero under the existing HIGH/CRITICAL `--ignore-unfixed` policy. This result is
not an authorization to publish or deploy the image.

The real AWS S3/SQS/CloudWatch/Cost Explorer services were not contacted by these
tests. Live workload-role credential refresh, deployment smoke tests and the
Linux AMD64 CI build remain separate checks. ECS deployment builds Linux ARM64,
as do these local builds/tests, but the exact ECR artifact digests must still be
verified before deployment. No AMD64 acceptance is implied by this local run.

## Reproduce

Use the CI toolchain and a disposable PostgreSQL/pgvector database containing
synthetic data only. Do not reuse a production `DATABASE_URL`.

```sh
mix local.hex 2.5.1 --force
mix local.rebar --force
MIX_ENV=test mix deps.get
git diff --exit-code -- mix.lock
MIX_ENV=test mix hex.audit
MIX_ENV=test mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors
MIX_ENV=test mix test
```

Deployment is not performed by these commands. Promote only the immutable image
that passed the corresponding build, Hex audit, image scan and deployment smoke
tests. If an operational rollback is needed, use the deployment pipeline's
previous-image rollback and verification procedure; reverting to the previous
dependency lock also restores the documented vulnerabilities and is not a
security fix.
