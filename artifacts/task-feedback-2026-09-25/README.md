# Task response feedback

Native Qt captures use an isolated loopback API and synthetic task records. They do not show a production account or an actual PDF export.

- `tasks-response-feedback-1228.png`: delivered response with direct acceptance or improvement.
- `tasks-improvement-prompt-1228.png`, `tasks-improvement-prompt-760.png`: inline instructions at wide and compact sizes.

The native regressions cover exact response/run targeting, empty-prompt validation, draft retention after close and errors, delayed completion after selection changes, and automatic PDF export displaying neither action approval nor response feedback while it is pending.

Reproduce via the `mokaid_tasks_qml_tests` target, with `MOKAID_TASKS_CAPTURE_DIR` set to this directory. The tests require loopback HTTP access. Server-side policy and recovery tests verify the PDF behavior separately.
