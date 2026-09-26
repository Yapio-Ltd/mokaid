# Agent detail drawer validation

These captures render the production native QML components with synthetic fixture records served by an isolated loopback API. Names, metrics, tasks, reference documents and messages are test data, not a production account. The character portrait is the application's existing source-matched Legal asset; the supplied reference establishes layout and styling, not replacement character geometry.

The shared drawer is used by Office overview and Agents. Captures cover Overview, Tasks, Knowledge, Settings, the More menu and embedded chat at 450×850 and 360×600, plus the shorter 340×500 layout. Screenshots use Qt's software rendering backend; the actual application uses its native renderer.

The tests exercise keyboard tab navigation, close signals, task search/filter/navigation, knowledge refresh/upload routing, chat draft/send, assignment, rent-out routing, settings PATCH contents and panel/control geometry. They use the real FeatureController with local HTTP fixtures. They do not perform a real marketplace transaction, send a production message or validate a live model answer.

Build:

```sh
cmake --build apps/desktop/build/macos-debug --target mokaid_desktop mokaid_agent_detail_qml_tests --parallel 4
```

Capture:

```sh
QT_QPA_PLATFORM=offscreen QSG_RHI_BACKEND=software MOKAID_AGENT_DETAIL_CAPTURE_DIR="$PWD/artifacts/agent-detail-2026-09-26" apps/desktop/build/macos-debug/application/features/mokaid_agent_detail_qml_tests
```

Related checks: `mokaid_feature_tests` validates workspace scoping, stale responses and saved settings; `mokaid_native_pages_qml_tests` covers existing native screens and the Agents integration; `mokaid_office_tour_qml_tests` checks the Office drawer alongside the existing immersive conversation.

## Results

- Native app build succeeded (`mokaid_desktop`).
- FeatureController: 66 QtTest results passed, no failures.
- Existing native pages: 46 QtTest results passed, no failures.
- Dedicated panel: 8 QtTest results passed (6 interaction flows plus init/cleanup), no QML warnings; `agent-detail-tests.log` records the final run.
- Office GPU integration: the fixture compiles and now tracks the real window bounds after macOS display clamping. Full execution could not be verified: two bounded runs timed out on the pre-existing `diagnostics.triangles > 0` renderer prerequisite before the new drawer assertions. The renderer reported no error and QML reported no warnings. This is not evidence of successful immersive 3D validation.

Only macOS was exercised. No production mutations were used to produce these results.
