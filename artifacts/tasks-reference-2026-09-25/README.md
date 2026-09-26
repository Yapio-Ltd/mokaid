# Native Tasks reference captures

Design reference: the user-supplied `ChatGPT Image Sep 25, 2026, 11_27_22 AM.png`. The native Qt Quick implementation follows the visual system in [DESIGN.md](../../apps/desktop/DESIGN.md).

These seven PNGs render the Tasks content area with synthetic fixtures served by an isolated local API. They exclude the global header, sidebar, and operating-system chrome. Wide captures use 1228 × 820; compact captures use 760 × 760. The fixture has 20 tasks (3 Todo, 4 In progress, 5 Needs attention, 8 Completed), so the displayed totals remain consistent with the lane counts. Dates are relative to the capture date.

| Screen | Wide | Compact |
| --- | --- | --- |
| Kanban board | [1228](tasks-board-1228.png) | [760](tasks-board-760.png) |
| Task details | [1228](tasks-inspector-1228.png) | [760](tasks-inspector-760.png) |
| Conversation and activity | [1228](tasks-activity-1228.png) | — |
| List view | — | [760](tasks-list-760.png) |
| Empty workspace | [1228](tasks-empty-1228.png) | — |

The [native Tasks test target](../../apps/desktop/tests/tasks_qml_tests.cpp) passed all 13 scenarios (15 QtTest passes including setup and cleanup): pointer dragging across columns; narrow-window drag auto-scroll; same-column no-op; Escape cancellation followed by another successful drag; failed status update and retry; keyboard movement from the card menu and the inspector; creator, assignee, overdue and text filters; list completion; responsive detail and empty views; scoped comment drafts across tasks, failed sends and retries; preserved SEO execution target after the drawer closes; and keyboard focus restricted to the open drawer with restoration to its source card.

Reproduce from the repository root:

```sh
cmake --build apps/desktop/build/macos-debug --target mokaid_tasks_qml_tests -j 4
MOKAID_TASKS_CAPTURE_DIR="$PWD/artifacts/tasks-reference-2026-09-25" \
  apps/desktop/build/macos-debug/application/features/mokaid_tasks_qml_tests
```

The test process needs permission to listen on the loopback interface. It does not contact production services or modify real tasks.

Additional contract checks passed: 56 native controller tests, the same 56 under UBSan, and 3 task API tests. The API tests were run directly against the existing test schema because an unrelated concurrent Mail migration blocked the normal migration alias. The isolated ASan binary compiled but its macOS sanitizer runtime stalled before `main`; no application test ran under ASan.

The updated desktop app was built and relaunched on the real Tasks page. API source changes were not deployed to production: personal-filter membership and enriched agent portraits require the updated task response. Real task status mutations were exercised only through the isolated test API.
