# Native desktop architecture and release gates

## ADR 001 — dependencies point toward domain policies

The application composition root owns service construction and destruction.
QML calls view-model/application services; network, storage and OS adapters are
below those services. Domain policies in `core` and the simulation in `engine`
are portable C++20 without Qt. Adapters may use Qt's object ownership and event
loop; core resource ownership remains explicit RAII.

The independently compiled libraries are `mokaid_core`, `mokaid_engine`,
`mokaid_renderer`, `mokaid_viewport`, `mokaid_platform`, `mokaid_storage`,
`mokaid_network`, and `mokaid_application`; presentation and preview integration
sit above them. The native renderer has no Qt dependency. The bridge is the only
place that imports a rendered native texture into Qt's scene graph.

`python3 scripts/check_boundaries.py` checks source includes and CMake links.
Its regression tests run with `python3 -m unittest discover -s scripts/tests`.
Run both in CI before SDK installation. This structural check does not replace
a review of object ownership, interfaces or data flow.

## ADR 002 — graphics composition has explicit native ownership

macOS uses Qt Quick on Metal and records the office render pass into the same
Metal command buffer before Qt records its 2D composition. Borrowed Qt Metal
handles are direct object pointers, as shown in Qt's
[Metal texture import example](https://doc.qt.io/qt-6/qtquick-scenegraph-metaltextureimport-example.html).
Every submitted frame retains its texture/buffer/pipeline references through a
completion handler, protecting resize and item destruction even if an upstream
command buffer uses unretained references. Every subsequent Qt composition of
a paused image also leases that final texture until completion. A render-pass
RAII guard ends the borrowed encoder even on a C++ allocation failure.

Windows uses Qt Quick's D3D11 device and creates D3D12 on that same DXGI adapter.
Three shared RGBA8 targets are imported into Qt through NT handles. D3D12 waits
for the last Qt consumer fence before reuse; Qt waits for the producer fence
before sampling. Every Qt composition has a unique consumer fence value, even
when Qt redraws the same native image several times. Upload staging and command
allocators are reused only after their producer fence completes. Device removal
is detected before waiting/reusing resources.

Both paths keep images on the GPU. The interface remains at native density;
only the offscreen 3D target is downscaled. Render work is scheduled from native
scene synchronization, not every unrelated Qt frame. Renderer failure pauses
that node and exposes an error; an explicit `retryRenderer()` or scenegraph
recreation constructs fresh graphics resources. Repeated driver failures are
not silently replaced with a different renderer.

Native viewport generation changes replace the entire Qt texture node. Qt 6.11
requires a non-null argument to `QSGSimpleTextureNode::setTexture`; clearing it
is not a reset mechanism. This was found and corrected in a real Qt/Metal/
WebEngine integration run, not inferred from a build-only check.

## ADR 003 — deterministic assets and bounded simulation

Build-time conversion resolves the seven current, content-addressed avatar GLBs
from `apps/api/lib/mokaid/assets_3d.ex` and verifies their SHA-256 before decoding;
the legacy `female` pack aliases the catalogue's `design` entry. Unversioned
`assets/optimized/avatar_*.glb` files are authoring intermediates and must not be
used by default: they predate shipped sitting/rest-pose corrections. The office
comes from `apps/web/src/three/office-asset.ts`. Conversion decodes Draco and normalized
accessors, expands instance transforms, emits mipchains and retains authored
skeleton tracks. A versioned binary reader validates counts, hierarchy,
indices, finite values and GPU skin palette bounds. A SHA-256 manifest pins
the cooked outputs to their source GLBs. Asset parsing and image decoding never
run inside the steady-state drawing loop.

Some catalogue finance desk clips contain repeated constant lower-body outputs
with a count different from their input times. The cooker reconciles this only
after proving every output equal. Nonconstant count mismatches fail cooking;
silently retiming a moving channel is forbidden. Pure Node tests check source
revisions, legacy aliasing and this narrowly scoped repair.

The current renderer's precise supported feature set and outstanding visual
parity work are maintained in `renderer/README.md`. Raw RGBA8 mipchains and
occupancy-grid paths are baseline implementations, not claimed substitutes for
the planned compressed GPU assets and Recast/Detour final path.

Simulation owns a fixed 60 Hz worker. It publishes immutable frames; Qt reads a
snapshot at synchronization boundaries. Data/model changes are protected by a
bounded critical section and never mutate a frame already consumed by the GPU.
The animation mixer snapshots all currently weighted clips before a transition,
then applies the web's 0.28-second smoothstep in local translation/rotation/scale
space. Interruption does not discard partially blended poses. A missing state
resolving to the already-active idle clip retains its time. The two graphics
passes share one evaluated pose per instance.
The raw glTF office is rotated by PI around Y, matching Babylon's imported root
after converting its left-handed world to our right-handed one. Avatar roots
reflect Z because the web explicitly clears Babylon's importer rotation. Desk
and navigation positions reflect Z, their yaw angles change sign, and the camera
uses the corresponding reflected authored frame. No renderer-specific axis
correction is hidden in a shader. The nine physical desk indices and 0.51 m seat
height are stable fixtures. Network updates remain independent of whether the
viewport is visible or paused.

## Tests and evidence required before shipping

Portable checks cover projection/inverse math, quaternion interpolation, parent
animation, skin bind poses, interrupted blend continuity, clip fallback, seat indices, every real cooked asset
and obstacle-safe patrol routes. Build both native platforms with warnings,
then run ASan/UBSan and concurrency checks on supported runners. A test timeout
or unavailable SDK is a failed validation gate, never a passing test.

The graphical gate requires real Metal and D3D11/D3D12 runs with QML and WebEngine
visible concurrently. Exercise repeated resize, 1x/2x display moves, minimization,
sleep/wake, preview loading/closing, account/workspace replacement, texture-ring
reuse and forced GPU loss. GPU validation must report no stale resources,
cross-device import, fence deadlock or CPU image readback. Compare rendered
office/avatar screenshots with the existing web scenes and seating fixtures.

Benchmark a Mac M1 8 GiB, Intel Iris Xe 16 GiB and an NVIDIA machine using the
same office, nine agents, resolution and scene duration. Capture p50/p95/p99
frame time (not average FPS alone), native render CPU time, GPU time, all-process
resident memory, GPU texture residency, cold/warm startup, wake latency and
thermal behavior. Repeat with a long HTML deliverable and while resizing it.
The product target is 60 FPS with adaptive 3D quality; no current code/test
asserts that target has been achieved.

Publish only after visual/functional parity, measured performance budgets,
signed clean-machine install, interrupted/invalid update tests, and a verified
signed version-to-version upgrade. Record actual hardware, OS, driver and build
identifiers next to results. CI without a real GPU can compile and inspect the
engine but cannot certify these runtime gates.
