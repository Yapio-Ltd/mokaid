# Native Google connections validation — 2026-09-27

The final macOS debug application built successfully with Qt 6.11.2. It includes native Gmail, Calendar, Drive, Docs, Sheets and Meet OAuth service selection, authenticated polling/cancellation, account status, readonly service descriptions and explicit different-account/tool-availability feedback. Mail success now requires a saved account ID.

App: `/Users/olimservice/mokaid/apps/desktop/build/macos-debug/app/Mokaid.app`
Binary SHA-256: `16ec26a5b3b198056da2821b098b02d44a117a63f07095398d063df15accf4fb`
Build finished: 2026-09-27 00:55:48 IDT. Runtime restart is managed by the root task; this validation did not restart the user's application.

| CTest name | QtTest methods | Expanded cases | Result including init/cleanup |
| --- | ---: | ---: | --- |
| desktop-feature-contracts | 61 | 69 | 71 passed, 0 failed |
| desktop-feature-qml | 5 | 5 | 7 passed, 0 failed |
| desktop-native-pages-qml | 16 | 45 | 47 passed, 0 failed |

Counts were read with `-functions` and `-datatags`; pass totals are in the saved logs. Native UI tests run offscreen against isolated loopback fixtures, without live Google credentials. Screenshots contain synthetic accounts only and were reviewed at 760 × 620, including scrolling to Sheets/Meet and an account-mismatch warning. The root task separately validated real Gmail authorization and synchronization.

Reproduce from repository root:

```sh
cmake --build apps/desktop/build/macos-debug --target mokaid_feature_tests mokaid_feature_qml_tests mokaid_native_pages_qml_tests mokaid_desktop -j6
ctest --test-dir apps/desktop/build/macos-debug -R 'desktop-(feature-contracts|feature-qml|native-pages-qml)$' --output-on-failure
```

The final controller executable was additionally run directly after build completion to avoid any ambiguity from the first CTest run overlapping the linker. No sanitizers were rerun in this pass; the earlier September 25 sanitizer experiment failed before main in this environment. `git diff --check -- apps/desktop` passed.

The SDK was repaired after temporary-directory cleanup removed CMake metadata. Preserve `/private/tmp/mokaid-qt-sdk/6.11.2/macos` while using this development build. Obsolete generated staging and old sanitizer outputs were removed to recover disk space; source files and the running application were preserved.
