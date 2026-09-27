# Desktop and web validation — 27 September 2026

This report covers the combined local desktop/web changes prepared for the
September 27 release. It records validation results, not a deployment or a signed
desktop installer release. Test servers and browser accounts use isolated
fixtures; these checks do not access or modify production mailboxes.

## Results

| Check | Result |
| --- | --- |
| Complete macOS debug build, Qt 6.11.2 arm64 | Passed |
| Complete desktop CTest suite | 46 suites passed |
| Metal office tour with completed image/text custom-avatar fixtures | Passed |
| Desktop dependency boundaries | Passed |
| Desktop build-script tests | 8 passed |
| Desktop distribution tests | 140 run, 2 optional skips |
| Asset cooker tests | 43 passed, 1 optional skip |
| Web Vitest suite | 41 files, 301 tests passed |
| Web TypeScript | Passed |
| Web ESLint | Passed with 14 existing React Hook warnings |
| Web production build | Passed |
| SEO policy tests | 5 passed |
| Public-page Chromium prerender | 36 routes and sitemap generated |
| Compiled account portal Chromium checks | 8 scenarios passed |

The desktop suites include loopback HTTP, session lifecycle, workspace isolation,
Mail controller/reader/composer, Google connections, avatar generation and credit
states, custom-avatar revision reloads, native QML pages, preview policies, task
completion and the Metal office tour. The full CTest run leaves two optional
character capture methods skipped unless their local fixture directories are
provided. A separate bounded CTest run supplied the completed image/text custom
avatars and passed their native rendering check alongside the interactive tour.
Browser acceptance blocks non-local traffic and checks the account
portal does not load business-renderer resources.

Reproduction commands from the repository root:

```sh
cmake --build apps/desktop/build/macos-debug --parallel 6
ctest --test-dir apps/desktop/build/macos-debug --output-on-failure -j 4
npm test --prefix apps/desktop/tools/asset-cooker
npm run test --workspace apps/web -- --run
npm run typecheck --workspace apps/web
npm run lint --workspace apps/web
npm run build --workspace apps/web
npm run test:seo --workspace apps/web
npm run prerender --workspace apps/web
```

The browser checks require the Chromium version locked by Playwright. Distribution
tests require Python's `cryptography` package; using a Python without it produces
setup errors rather than release-contract failures. The native suite requires
permission to bind loopback fixture servers and open macOS Qt/Metal test windows.

## Release limits

- Validation ran on macOS 26.5.1 arm64. It does not establish Windows 11 runtime,
  graphics, signing or installer acceptance, or performance on minimum hardware.
- The local debug application is not a newly signed/notarized public Mac release.
  Building and deploying the web/API does not distribute a new desktop binary.
  Follow [the desktop release process](../apps/desktop/docs/releases.md) for
  signed installers and update-channel promotion.
- Existing Qt font fallback and WebEngine deprecation warnings remain in fixture
  output. The passing tests do not make a clean QML static-analysis claim.
- API, worker, infrastructure and production rollout validation are recorded by
  their release owners separately from this client report.

## Public repository evidence

Raw live-account verification records, cloud deployment identifiers, generated
GLB/native binaries and transient source snapshots remain local validation
artifacts. They are not required to build the application. Public evidence should
use this aggregate report and selected screenshots whose fixture provenance is
documented, without mailbox addresses, OAuth links or media access tokens.
