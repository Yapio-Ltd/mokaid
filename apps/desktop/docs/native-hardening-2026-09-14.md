# Native workflow hardening — 2026-09-14

This checkpoint extends the desktop implementation. It is **not** full product
acceptance, a public release or authorization to switch off the web office.

## Delivered changes

- Hierarchical native Drive navigation, breadcrumbs, trash and selected-row
  restore use the existing server endpoints. Atomic native export is bounded to
  32 MiB, with cancellation, overwrite confirmation and destination/context
  freshness checks. Partial HTTP responses never become successful files.
- The preview toolbar returns to native Files without evicting the preview.
  Account/workspace/folder changes invalidate open mutation forms; only an
  explicit successful mutation closes a submitted form.
- Native conversation histories and concurrent streams are scoped to the
  account, workspace, agent and original conversation. The API and worker carry
  that conversation through replies and task creation/resumption. A late reply
  cannot silently fall back into a newer conversation. Old producers lacking a
  conversation ID retain their legacy server behavior; their unidentified
  stream fragments are not rendered by the native client.
  When interrupted streams exhaust the eight-preview budget, the oldest preview
  is evicted with an explicit notice and history resynchronization. Its late
  fragments stay retired, but its canonical final message remains accepted.
- A separate, fail-closed Mac signing/notarization probe is prepared. It cannot
  publish a release and has not run against real credentials. Its authorization
  prerequisites and evidence boundary are in the
  [probe runbook](private-macos-signing-probe.md).

## Local verification

Executed against this change set on the development Mac with Qt 6.11.2:

| Check | Result |
| --- | --- |
| Complete C++/QML application and graphics probe build | Passed |
| Foreground Mac graphics bundle, synthetic HTML and real scene, Metal validation enabled | 16 functional checks passed; timing sample unqualified |
| CTest, including native network, cache, conversations, Drive and QML components | 16 suites passed |
| API suite with dedicated local PostgreSQL and no worker dispatch | 238 tests passed |
| AI worker tests with fake provider callbacks | 134 tests passed |
| Distribution safety tests using synthetic credentials | 137 passed, 2 existing opt-in tests skipped |
| GitHub deployment/signing policy tests | 110 tests passed |
| Native module-boundary checker and its tests | Passed |
| Targeted conversation/Drive UBSan tests | Passed |
| Python lint/type checks and new workflow actionlint | Passed |

The dedicated PostgreSQL instance was stopped cleanly after testing; no fixture
database or unrelated files were deleted. Tests do not use production accounts,
customer data, paid AI requests or real signing secrets. The worker fixture
does not load the developer's personal `.env`.

Local AddressSanitizer binaries compile but hang before `main` in this host's
runtime; execution was stopped after a bounded timeout. ASan is **not** validated
on this host. No sanitizer or CI requirement has been disabled.

File publication tests cover a blocked worker synchronization, cancellation and
context changes before/after synchronization, failed native publication, and
replacement confirmation. A Windows descriptor-error guard was added by review;
actual Windows execution, including its native filesystem behavior, still needs
this commit's hosted CI and physical-machine acceptance. A confirmed shutdown can
wait for an already-running disk synchronization. Directory-entry durability
after power loss and cloning extended ACLs/ownership are not claimed.

The preview component test exercises keyboard navigation and preserved
controller state without a live HTML document. It does not prove preservation of
an active HTML form, the complete shell, physical GPU behavior or Windows.
New source commits require their own macOS/Windows CI runs; earlier green runs
are not evidence for these changes.

The separate physical integration probe was launched through LaunchServices as
`com.mokaid.desktop.graphicsprobe` at 14:40:27 UTC. On this M4 Pro, its report at
14:40:50 UTC passed all 16 functional checks, including real HTML dirty-state
protection, hide/show/resize recovery and native composition. No Metal validation
error was emitted. A Qt warning recommends the newer profile-creation API; this
run is not claimed warning-free. The sample recorded 625 intervals but reported
`performanceSampleQualified=false` because focus was interrupted. Neither this
Debug/Metal-validation sample nor the two preceding failed unbundled attempts
(zero-frame sample, then initialization-phase timeout) is a release benchmark.
Bundling the test makes foreground launch reliable without loosening its checks,
90-second timeout or qualification rules. It is not packaged into Mokaid releases.

## Public delivery still gated

Production was last independently verified at source
`d6f8eba891eef26ba6589ede3ab6c3c886e71815`; the changes above were local at this
checkpoint. Do not describe a local test or PR as a production deployment.

The website's desktop-only flags stay disabled until usable signed downloads
and desktop acceptance exist. CloudFront account verification, a Windows
signing service, real Mac notarization, clean-machine installation and signed
upgrade tests remain outstanding. The
[feature coverage matrix](../application/features/PARITY.md) records remaining
native workflow gaps. Physical M1/Iris Xe/NVIDIA performance and complete
32-screen parity are separate, still-required acceptance work.
