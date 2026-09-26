# Native Office immersion validation

The PNGs in this directory render the actual native OfficePage, Metal viewport and cooked office/avatar assets. Agents, missions and chat replies in these screenshots are explicitly synthetic test fixtures confined to `apps/desktop/tests/office_tour_qml_tests.cpp`. No production agent message was sent for this validation.

The feature adds an explicit overview/first-person switch, 16 fixed destinations (nine desks and seven shared spaces), an immutable collision-validated route network, drag/arrow look controls, and the existing OfficeController chat in a compact overlay. Returning restores the prior overview camera and chat selection while preserving drafts.

Capture sizes: 1440×900 requested wide window (bounded by available display), 1000×680 compact window, and 790×640 window with a 750×580 office area to represent the minimum desktop shell content. Qt screenshots use the display pixel ratio.

Validation uses `mokaid_guided_tour_tests` with real assets for route safety, all destinations, look/stop behavior, agent picking and exact camera restoration; `mokaid_office_tour_qml_tests` for real controls, interaction and responsive geometry; existing `desktop-office-conversations` for actual controller HTTP/channel isolation; and `desktop.agent_indicators` for label behavior. The UI test reply validates chat wiring, not a live model answer. Windows and other GPUs were not exercised here.

Build: `cmake --build apps/desktop/build/macos-debug --target mokaid_desktop mokaid_office_tour_qml_tests mokaid_guided_tour_tests --parallel 4`.

Set `MOKAID_OFFICE_CAPTURE_DIR` to this directory when running the QML executable from its app bundle in a visible desktop session. GPU/loopback tests require desktop/network access outside the filesystem sandbox.

Final checks passed on macOS: guided tour and real-asset guided tour; native UI integration (3 QtTest phases, zero failures/warnings); existing controller conversation tests; agent indicator tests. Both originally closed and originally open overview chat states are restored; Escape also works from the focused composer. `native-ui-tests.log` records the final UI run.
