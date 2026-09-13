# Mokaid Desktop

Native **C++20 / Qt 6.11.2 / QML** client, added alongside the existing web and
Phoenix applications. This is a runnable development implementation, **not the
completed product-parity or public-release milestone**. No example workspace
records, simulated successful mutations, or production authentication bypasses
are included in the app.

## Build

Supported product targets: macOS 13+ arm64 and Windows 11 x64. Use a full Xcode
installation plus the Metal compiler on Mac; Visual Studio 2022 C++/Windows SDK
and DXC on Windows. Qt must match **6.11.2 exactly** and include WebEngine,
WebChannel, WebSockets, Positioning, ShaderTools and TaskTree alongside Qt Base
and Declarative. CMake 3.30+, Ninja, Python with Pillow and Node 22 are needed.
The release tool versions, SDK hashes and Conan lock are maintained in
[distribution](distribution) and the CI workflows.

From `apps/desktop` (replace the SDK path for your machine):

```sh
npm ci --ignore-scripts --prefix tools/asset-cooker
node tools/asset-cooker/cook.mjs build/assets
cmake --preset macos-debug -DCMAKE_PREFIX_PATH=/path/to/Qt/6.11.2/macos
cmake --build --preset macos-debug --parallel 4
ctest --preset macos-debug --output-on-failure
build/macos-debug/app/Mokaid.app/Contents/MacOS/Mokaid --assets build/assets
```

Use `windows-debug` in a VS developer shell for Windows. If CMake selects a
Python without Pillow, set `-DPython3_EXECUTABLE=/path/to/python`. Newer Xcode
versions install Metal separately: use `xcodebuild -downloadComponent
MetalToolchain` and, when necessary, pass the installed component's
`toolchainIdentifier` as `-DMOKAID_METAL_TOOLCHAIN=...`.

The cooker resolves the current hashed office/avatar assets from the web and
backend catalogs. Do not substitute older optimized GLBs for the catalog packs.
Cook before configuring so the real-asset CTest is registered. Core/simulation
tests also build without Qt via the `portable-tests` preset.

## Connect to a development server

The native session requires the new Phoenix endpoints and database migration
in this change, plus the web `/desktop/authorize` consent page. See
[the server integration guide](../api/DESKTOP_AUTH.md). Existing web login alone
is not sufficient. The production site and infrastructure are not deployed by
building this client.

Configure trusted origins explicitly for a local API and separate Vite server:

```sh
cmake --preset macos-debug -DCMAKE_PREFIX_PATH=/path/to/Qt/6.11.2/macos \
  -DMOKAID_API_ORIGIN=http://localhost:4000 \
  -DMOKAID_WEB_ORIGIN=http://localhost:5173
```

Set the backend's `DESKTOP_AUTH_WEB_BASE_URL` to the same trusted web origin. Public
origins require HTTPS; HTTP is allowed only for explicit loopback development.
Browser sign-in accepts only the configured origin's `/desktop/authorize` with
one transaction ID. It never accepts an arbitrary server-returned redirect.
The temporary loopback callback is bound to PKCE and state. OS credential
storage holds the rotating refresh token; workspace cache contains no session
token. API and WebSocket credentials are headers, not URL parameters.
The serialized SQLite worker retains at most 500 entries / 256 MiB of payloads,
with an 8 MiB per-entry ceiling; database pages and its WAL add storage overhead.

## Validation and current limits

The normal app builds and launches on the local Apple M4 Pro. Native contract
tests cover domain policies, real cooked assets, incremental models, user and
workspace isolation, admin revocation, HTTP transport, authorization URLs,
Phoenix joins/rejoins, activity/search and preview resource filtering. The
[graphics probe](tests/graphics/README.md) is a separate test executable using
real GPU rendering and an explicitly labelled HTML fixture. It tests QML,
Metal and protected WebEngine together without accessing workspace data.

Run structural checks from this directory:

```sh
python3 scripts/check_boundaries.py
python3 -m unittest discover -s scripts/tests -v
python3 -m unittest discover -s distribution/tests -v
```

Read the exact remaining work before interpreting a successful build:

- [Native feature coverage and gaps](application/features/PARITY.md): all 32
  registered screens use actual APIs, but rich screen layouts, onboarding,
  some nested workflows and visual/copy parity are not complete.
- [Renderer coverage and gaps](renderer/README.md): authored assets and native
  GPU skinning work; full lighting, shadows/bloom, compressed textures, LOD,
  Recast/Detour and complete POI behavior still need work.
- [Architecture and performance gates](docs/architecture.md): M4 Pro smoke
  results are not M1/Iris Xe 60-FPS acceptance. Windows interop, screen changes,
  sleep/device loss, prolonged sessions and whole-process memory remain tests
  to run on real target hardware. QML lint currently reports context-property
  typing warnings; lint execution alone is not a clean static-analysis gate.
- ASan on this macOS 26.5.1 toolchain can deadlock before `main`; tested UBSan
  suites are recorded separately. CI has a portable ASan/UBSan job, but its
  configuration is not evidence of a successful remote run.

## Packaging and releases

[Release instructions](docs/releases.md) cover local development DMGs, signed
installers, updater SDKs, GitHub Actions and immutable candidate promotion.
Developer builds default to `MOKAID_ENABLE_UPDATES=OFF`. A local ad-hoc DMG is
**not** Developer-ID signed/notarized and is not a public distribution build.

Public promotion fails closed without signing, matching update keys and actual
acceptance evidence. Apple/Azure signing accounts, protected GitHub environments,
AWS/OIDC/download hosting and a deployed `/download` page must be connected by
an authorized operator. This implementation has not published or deployed them.
