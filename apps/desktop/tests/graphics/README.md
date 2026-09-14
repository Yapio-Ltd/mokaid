# Native/WebEngine integration probe

This is a separate test executable, **not** an authenticated product feature or
an application login bypass. It renders the real cooked office and eight clearly
synthetic agent fixtures beside the unmodified production `DeliveryView.qml`.
The latter uses `PreviewDocument`'s real off-the-record profile, isolated activity
script, scheme handler, request interceptor and CSP. Its only external-navigation
handler is a recording test double; no system browser is opened.

Build `mokaid_graphics_probe` with the normal desktop toolchain, then run it from
a visible macOS/Windows desktop session. On Windows, run
`mokaid_graphics_probe.exe` from the build's `tests/graphics` directory, providing
the `--assets`, `--output` and `--machine-label` arguments below with local paths.

On macOS the probe is a separate `.app`, with the distinct identifier
`com.mokaid.desktop.graphicsprobe`. Launch it through LaunchServices in the
foreground, using absolute paths for its arguments (launched apps do not inherit
the shell's working directory):

```sh
open -W -n /absolute/build/tests/graphics/mokaid_graphics_probe.app --args \
  --assets /absolute/build/assets \
  --output /private/tmp/mokaid-graphics-probe-results \
  --machine-label "Actual physical development host — not a target-device substitute"
```

Keep the test window visible and focused until it closes. The terminal command's
exit alone is not a test result: inspect `report.json` and require `status=passed`;
only interpret timings when `performanceSampleQualified=true`. Starting the bare
`.app/Contents/MacOS/mokaid_graphics_probe` executable behind another window can
produce an occluded-window timeout or zero frames. Such runs remain failures,
not successful performance evidence. `--help` describes the portable flags.
For independent iteration, `tests/graphics/standalone` is an alternative CMake
source directory that compiles the same production modules without configuring
the main application's build directory. Supply Qt's `CMAKE_PREFIX_PATH` and the
same platform shader compiler options as the desktop build.
To run through CTest, opt into `MOKAID_RUN_GRAPHICS_PROBE_CTEST=ON` and set
`MOKAID_PROBE_ASSETS` / `MOKAID_PROBE_MACHINE`. Normal CI builds the test executable
without pretending a hosted runner establishes physical-GPU acceptance.

The test verifies document JavaScript, a button action, local-file denial using
an existing harmless temporary file, API request rejection with a real `connect-src`
CSP violation, an initially clean activity tracker, and dirty-state protection
against a main-world reset. The API hostname is reserved `.invalid`; no production
API or credentials are used. It hides/shows the preview and scene, resizes the
window and checks that the draft and native rendering survive.

After those checks it warms up for **5 seconds**, samples **10 seconds** of
`QQuickWindow::frameSwapped` wall-clock intervals, then writes `report.json` and
`native-webengine.png`. The screenshot uses a test-only CPU readback **after**
measurement, never the production presentation path. Errors exit nonzero, and
an overall 90-second timeout is also a failure.

Frame p50/p95/p99 are presentation intervals, **not GPU timings**; renderer CPU
statistics are reported separately. The report also records maximum/mean interval,
actual measurement duration, first-frame delay and focus interruption. A sample
with lost focus, late first frame or insufficient duration is explicitly marked
unqualified for performance interpretation even if functional checks pass.
The report records the declared physical
host, OS, Qt, DPR, refresh rate and window/render sizes. A successful probe proves
only this integration slice, not 32-screen parity, visual fidelity to the web,
GPU device-loss recovery, multi-monitor/sleep behavior or 60 FPS on M1/Iris Xe.
It does not create a release acceptance record. Hardware budgets and sustained
GPU captures remain separate acceptance work.

For a sanitizer run configure a distinct build directory with
`MOKAID_ENABLE_SANITIZERS=ON`; do not compare sanitizer frame timing with release
performance. Record any unavailable sanitizer/platform execution explicitly.

On the implementation host (Apple M4 Pro, macOS 26.5.1, AppleClang 17), the
combined ASan/UBSan executable was built but ASan deadlocked in its own allocator
initialization **before `main`**. A process sample showed `AsanInitInternal` /
`InitializeShadowMemory` recursively re-entering the sanitizer allocator from
`dyld_shared_cache_iterate_text_swift`, then waiting in `StaticSpinMutex::LockSlow`.
The test process was stopped after diagnosis; this is not an ASan pass. The
standalone wrapper supports `MOKAID_SANITIZER_SET=undefined` to execute UBSan
independently. UBSan plus `MTL_DEBUG_LAYER=1` completed all 16 integration checks
on this host without an undefined-behavior or Metal-validation diagnostic.
ASan still needs a compatible host/toolchain run, and Windows remains unexecuted
locally. The portable Ubuntu CI job is configured for both sanitizers.
