# Runtime security validation — 2026-09-14

Local Docker images were scanned with the official, SHA-256-verified Trivy
0.74.0 executable and its database dated 2026-09-13T19:03:02Z. Scans used the
local daemon or an exported local archive, `--offline-scan`, disabled database
updates and telemetry, and no remote scanner. No image, code, secret, SBOM or
customer content was uploaded. Full reports retain findings without fixes.

## Changes and observations

- API and CRM explicitly install Debian Bookworm's fixed PCRE2
  `10.42-1+deb12u1`, and reject an older installed revision.
- The CRM standalone runtime removes unused npm/npx/Corepack executables and
  their global dependency trees. Application dependencies are retained and
  separately corrected; see [the CRM report](../../apps/crm/SECURITY_DEPENDENCIES.md).
- Both nginx runtime targets inherit the same patched base with Alpine
  `libuuid>=2.42.3-r1`. The base remains digest-pinned.
- The worker now pins its Python base by digest and applies signed Debian 13
  fixes for gzip, PCRE2, SQLite and perl-base. Minimum-version checks prevent
  a stale mirror from silently restoring the affected revisions. The worker
  does not invoke pip; pip is removed only from the final runtime, after copying
  all application dependencies. The original uvicorn command is unchanged.

Upstream version evidence: [Alpine libuuid](https://pkgs.alpinelinux.org/package/v3.24/main/aarch64/libuuid),
[Debian PCRE2](https://security-tracker.debian.org/tracker/CVE-2026-86145),
[gzip](https://security-tracker.debian.org/tracker/CVE-2026-41992),
[SQLite](https://security-tracker.debian.org/tracker/CVE-2026-11822),
[Perl](https://security-tracker.debian.org/tracker/CVE-2026-13221).
Package-level findings are not assertions that every affected code path is
reachable through Mokaid. No exploit was run against a live service.

## Tested intermediate image set

All are local Linux ARM64 **Docker daemon image IDs**, not public download or
ECR release references:

| Component | Image ID | Scan scope/result |
| --- | --- | --- |
| API | `sha256:70a5815f8247e92f7d0d041b1173c966839f3bb7501c81c567cd11ec24b96740` | No fixable HIGH/CRITICAL OS findings; Trivy found no BEAM package inventory |
| CRM | `sha256:41cacc04f1be4747bd6a7ea5c9610971ecbf8b7bc567fc101a6ae8408b81487f` | No Node findings and no OS findings with a published fix; 219 unfixed OS findings remain |
| Web | `sha256:76ac9be4e0e03abac7f32edece0c714d70705ea7c2c101c4de65fc6e25fb0ffd` | No OS findings; minified browser code needs its separate lockfile audit |
| Worker | `sha256:d6336ca4c619a869c138e1f8af255f80add1ebf91199672e0413f1e075c52120` | No Python findings or fixable HIGH/CRITICAL OS findings; 154 OS findings remain, including 44 unfixed HIGH/CRITICAL |

This set passed the real four-image staging harness: API release migrations,
database TLS, API health and anonymous guards, actual prerendered nginx
responses, CRM login HTML, and uvicorn worker startup/health/anonymous 401.
No AI task, provider request or production mutation was performed. All owned
disposable containers/networks were removed afterwards.

These are intermediate images. Subsequent lockfile or Dockerfile changes
require another build, scan and staging pass of the exact selected images.
The deployment workflow gates mutations on all four immutable release-image
scans and stages those same digests. `ignore-unfixed` means the HIGH/CRITICAL
gate only covers findings with available fixes; it does **not** mean an image
is free of vulnerabilities. Unfixed findings need continued review.

## Coverage limits and release blockers

Trivy's API release scan did not detect an Elixir dependency inventory. A green
OS scan therefore does not clear the separately identified Hex advisories.
Similarly, the nginx image contains compiled static JavaScript, not an npm
package inventory. CI performs an additional lockfile audit, including build
tools, before building production images.

No local result asserts production-data migration safety, real credentials or
provider integration, application feature parity, GPU acceptance, a public
desktop release, or an actual ECS deployment. Those checks remain independent.
