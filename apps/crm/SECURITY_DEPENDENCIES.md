# CRM dependency correction — 2026-09-14

The previously tested CRM image
`sha256:66aeebf9d26e6f770e50beb2886f08b9df1b03dc173c64748c3cacbbacae6383`
starts successfully, but contains vulnerable dependencies. A functional staging
pass is not a security waiver.

## Targeted versions

| Package | Target | Scope |
| --- | --- | --- |
| Next.js | 15.5.24 | Exact CRM dependency; no Next 16 migration |
| Sharp | 0.35.4 | Override under Next 15.5.24, whose official range permits it |
| PostCSS | 8.5.23 | PostCSS 8 only, including Next's otherwise pinned 8.4.31 |
| Nanoid | 3.3.18 | Nanoid 3 only; never rewrite a Nanoid 5 dependency to 3 |
| Browserslist | 4.28.7 | Browserslist 4 only |
| baseline-browser-mapping | 2.11.0 | Version 2 only |

[Next's AVIF advisory](https://github.com/vercel/next.js/security/advisories/GHSA-2xp9-vwfh-vxw4)
and [official 15.5.24 manifest](https://github.com/vercel/next.js/blob/v15.5.24/packages/next/package.json)
support the Next patch and Sharp range. [Sharp's fix](https://github.com/lovell/sharp/security/advisories/GHSA-rgj7-g3m4-5g8c)
requires 0.35.4 for its prebuilt libheif. Sharp 0.35 introduced documented
compatibility changes; Node 22 meets its Node >=20.9 requirement, but the CRM
must be rebuilt and tested. No direct Sharp API use was found in CRM source.

Other references: [PostCSS](https://github.com/postcss/postcss/security/advisories/GHSA-fxqj-rqcc-2cmp),
[Nanoid](https://github.com/ai/nanoid/releases/tag/3.3.18),
[Browserslist](https://github.com/browserslist/browserslist/security/advisories/GHSA-c83g-rgw3-j3cx),
[baseline mapping](https://github.com/web-platform-dx/baseline-browser-mapping/releases/tag/v2.11.0).

## Bundled copies and remaining checks

Next also ships compiled dependencies without individual version metadata.
The official Next 15.5.24 build manifest still pins its compiler inputs to
Browserslist 4.24.4 and Nanoid 3.1.32. npm overrides do **not** rewrite those
bundled files. The baseline runtime uses compiled Nanoid via `nanoid()` with
no attacker-controlled size; Browserslist references found were build helpers.
No runtime untrusted-CSS processing was found. These observations are not proof
of non-exploitability, and are not grounds to hide findings from Trivy.

Do not alter vulnerability severity, add suppression rules, or describe the
image as clean without the actual release-image scan. This patch does not
claim to fix dependencies outside these version-scoped targets.

## Validation — 2026-09-14

After explicit authorization to resolve/download packages and submit package
names/versions to npm's audit endpoint, the shared lockfile was regenerated.
`npm ls` and a real `npm ci --no-audit --no-fund` pass. CRM typecheck,
production build and all 17 generated pages pass. Web typecheck, lint (14
pre-existing warnings), 154 tests, five SEO tests and production build pass.
The authorized CRM-scoped npm audit reports **zero findings**. The later
full-monorepo tooling audit is recorded separately below.

The production Dockerfile built CRM image
`sha256:41cacc04f1be4747bd6a7ea5c9610971ecbf8b7bc567fc101a6ae8408b81487f`
on Linux ARM64. Offline inspection confirms Next 15.5.24, Sharp 0.35.4 with
libvips 8.18.6, PostCSS 8.5.23 and Nanoid 3.3.18. Its runtime also contains
Debian's fixed `libpcre2-8-0` 10.42-1+deb12u1, and no global npm, npx or
corepack executable or dependency tree.

Trivy 0.74.0, downloaded from the official release and SHA-256 verified, scanned
the local Docker archive offline with telemetry disabled. The public database
was updated at 2026-09-13T19:03:02Z. No image, code, SBOM or inventory was sent to
a scanner service. The unfiltered result has **zero Node package findings and
zero OS findings with a published fix**. It still lists 219 Debian findings
without a fixed version: 4 critical, 52 high, 90 medium, 72 low and 1 unknown.
These findings were not suppressed, and the image is not described as CVE-free.
Compiled dependency copies noted above remain a scanner limitation.

The deployment's exact Linux ARM64 ECR image scans and staging gate remain
mandatory; these local images do not replace them. CI also builds Linux AMD64
images, separately from the production ARM64 deployment.

The corrected CRM image also passed the real three-image staging harness with
API `sha256:70a5815f8247e92f7d0d041b1173c966839f3bb7501c81c567cd11ec24b96740`
and baseline WEB
`sha256:b2506e66a24e7591790c43f85db93a3b593456445db8993b2b5e50eddf6a8f92`.
This is an intermediate packaging check, not the final release-image set.
Migrations, API/database TLS, anonymous auth guards, production web verifier
and CRM login HTML passed; all owned disposable resources were removed.

## Shared-lock follow-up

The separate web follow-up pins runtime Phoenix to 1.8.9 and confines
brace-expansion fixes to their existing 1.x/5.x branches (1.1.18/5.0.9), plus
js-yaml 4.3.2. [Phoenix's advisory](https://github.com/phoenixframework/phoenix/security/advisories/GHSA-63mc-hw7g-86rr)
concerns attacker-selected Presence keys. The inspected server tracks database
user UUIDs and no web consumer instantiates Presence; nevertheless the shipped
Phoenix dependency is patched. [Brace expansion](https://github.com/advisories/GHSA-rgw5-rvv9-x895)
and [js-yaml](https://github.com/advisories/GHSA-2883-xcg3-v3hh) are ESLint
development dependencies, not runtime services in the Nginx image.

The first follow-up left five affected development packages: Vite 5.4.21,
esbuild 0.21.5, Vitest 2.1.9, vite-node 2.1.9 and @vitest/mocker 2.1.9
(one critical, one high, three moderate). These were then addressed in a
separately authorized tooling migration, rather than hidden from the audit.

The final toolchain uses **Vite 6.4.3 and Vitest/@vitest/mocker 4.1.11**.
Vite resolves esbuild 0.25.12 through its own supported `^0.25.0` dependency;
no esbuild override is used. A root Vite override keeps every consumer on the
same 6.4.3 version, with no Vite 5/8 or vite-node copy remaining. The official
[Vite manifest](https://github.com/vitejs/vite/blob/v6.4.3/packages/vite/package.json),
[Vitest manifest](https://github.com/vitest-dev/vitest/blob/v4.1.11/packages/vitest/package.json)
and published @vitejs/plugin-react 4.7.0 peer metadata all permit this
combination on Node 22. The chosen versions cover
[Vite's server fix](https://github.com/vitejs/vite/security/advisories/GHSA-fx2h-pf6j-xcff),
[Vitest's critical UI/API issue](https://github.com/vitest-dev/vitest/security/advisories/GHSA-5xrq-8626-4rwp)
and the newer [mocker fix](https://github.com/vitest-dev/vitest/security/advisories/GHSA-82fw-gwwq-j7x9).

npm 10.9.2 and 10.9.9 reproducibly crashed in Arborist `loadPeerSet` while
resolving this migration. Temporary npm 11.19.1 plus deduplication generated
the final lockfile, without `--force`, `--legacy-peer-deps` or a global npm
installation. **A subsequent real `npm ci` with standard npm 10.9.2 passes**;
CI does not require a package-manager migration. Deduplication also refreshed
compatible transitive Node types, ignore and minimatch patches/minors. All CRM
security targets remain unchanged.

The development server now binds only to `127.0.0.1` by default. Explicit
container/LAN `--host` remains possible; a `resolveConfig` check confirms both
the default loopback and an explicit `0.0.0.0` override. This follows
[Vite's host documentation](https://github.com/vitejs/vite/blob/v6.4.3/docs/config/server-options.md#serverhost).
The existing preview commands were not changed.

Fresh npm installation, both workspace typechecks, web lint (the same 14
warnings), **all 154 tests on Vitest 4**, five SEO tests and the Vite 6
production build pass without changing any test to accommodate the migration.
The final **unfiltered npm audit reports zero findings across 582 dependency
entries**, including development dependencies. This registry result does not
replace release-image scans or establish that compiled framework bundles are
free of vulnerabilities.

The unchanged browser acceptance scripts also passed after the migration:
Chromium rendered all **36 route snapshots**, including legal pages, and the
**31-entry indexable sitemap**; the separate
compiled account-only build passed portal navigation/billing/invoice export,
login direct-link continuation, desktop-consent return and the mobile account
view. These four portal cases use isolated API fixtures and block external
traffic; they do not claim live payment or provider validation. All report
zero business resources, renderer canvases or WebSocket connections. The two
loopback preview servers were stopped after verification.

The final CRM rebuild uses `npm ci` and the same immutable Node 22 base digest
for build and runtime. Its image is
`sha256:7f8d141e3a4cfc91d65d671371b31119e7cb34575efcac7d39e707bb1432fb7e`.
Compilation, types, 17 pages and the build's CRM npm audit pass; offline
runtime inspection reconfirms the exact fixed Next/Sharp/PostCSS/Nanoid and
PCRE2 versions above, with npm/npx/corepack absent.
Its final offline Trivy scan has the same result as the intermediate corrected
image: zero Node findings, zero fixable OS findings and 219 unfiltered OS
findings without a fixed version. No suppression was added.

The final local four-image staging set (API 70a5815f, WEB 45d3ca7b, CRM
7f8d141e and WORKER d6336ca4; full immutable IDs in the
[staging runbook](../../.github/scripts/staging-smoke.md)) passed together.
The gate exercised real migrations, database TLS, anonymous API guards,
production HTML, CRM login and Uvicorn worker health/anonymous authorization,
without running a job or contacting providers. Cleanup removed all owned
containers, volumes and network. This packaging result does not waive
findings from the separate API/worker dependency audits.
