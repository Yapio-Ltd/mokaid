# Native task completion results

September 27, 2026. This is an Operate-mode extension of the native Qt Quick application. It replaces the brief completed-AI-task toast with a reviewable result dialog while preserving the established midnight surfaces, bundled Manrope, violet actions/focus and shared controls. Other mission updates retain their existing notification route. `Theme.qml` and `.impeccable/design.json` were not changed for this extension.

## Implemented behavior

- The task title, assigned agent identity, project and completion time come from the loaded task/notification. `WorkforcePortrait` uses the actual avatar metadata and falls back to initials for an unresolved source.
- The full agent response is selectable plain text with Copy. Long text scrolls without truncating the stored response; missing-response, loading and retryable error states remain explicit.
- Files come from the task inspector's curated deliverable extraction, independently of its current selection. Each file has a preview card, View and Download. Image previews use the existing thumbnail service. Download status/errors remain visible, and active or pending downloads disable duplicate actions.
- `ActivityController` accepts canonical completion notifications, loads each result through the workspace-scoped task endpoint, queues different tasks and deduplicates notifications. A newer completion for the same task refreshes its result. Context changes cancel requests and clear the queue; stale or mismatched results cannot populate it.
- The modal waits while an existing action form, preview, quit/sign-out confirmation, close-deliverables confirmation or desktop preferences dialog is open. Preview closes the modal temporarily and returns to the pending result afterward. Direct download normalizes the file without replacing retained previews. Open task uses the actual task ID. Done/Next result marks the current notification read; Close/Escape dismisses queued presentation without marking those notifications read.
- The original 1.25-second chime is synthesized without external samples by [generate_completion.py](../../apps/desktop/presentation/assets/sounds/generate_completion.py) and embedded as `qrc:/sounds/mission-complete.wav`. It plays once at the configured volume, honors the existing mission-sound preference, stops immediately when muted and does not overlap or restart while playing. Reduced motion disables the dialog fades.

## Capture provenance

All six captures use [completion_qml_tests.cpp](../../apps/desktop/tests/completion_qml_tests.cpp), an isolated QML fixture with authored in-memory data and native macOS Metal rendering. No account, live backend or saved workspace content is used. The fixture's Aria identity, brand task, response, file names, sizes and timestamps are synthetic. The existing design-agent portrait is reused as a test thumbnail; it is not delivered brand artwork.

| Capture | Logical content size | PNG pixels | State |
| --- | --- | --- | --- |
| [completion-1440.png](completion-1440.png) | 1440 × 845 | 2880 × 1690 | Response, portrait and deliverables |
| [completion-1000.png](completion-1000.png) | 1000 × 680 | 2000 × 1360 | Compact desktop result |
| [completion-loading-1000.png](completion-loading-1000.png) | 1000 × 680 | 2000 × 1360 | Loading |
| [completion-error-1000.png](completion-error-1000.png) | 1000 × 680 | 2000 × 1360 | Retryable failure |
| [completion-no-response-1000.png](completion-no-response-1000.png) | 1000 × 680 | 2000 × 1360 | No written response or files |
| [completion-long-response-1000.png](completion-long-response-1000.png) | 1000 × 680 | 2000 × 1360 | Long selectable plain-text response |

The wide test requests 1440 × 900; macOS clamps its logical height to 845 on the capture display. The filenames record requested width, not an unclamped 900-pixel height. Retina captures use twice the logical dimensions.

## Validation and limits

- `mokaid_desktop` builds successfully. Native output: `apps/desktop/build/macos-debug/app/Mokaid.app`.
- `desktop-activity-contracts` and `desktop-mission-contracts` pass with local loopback permitted. Completion contracts cover canonical notification selection, queueing, retry, workspace mismatch and context reset.
- The native Metal completion suite reports 7 passed, 0 failed and 0 warnings. It covers reference/compact layout, source-matched portrait, complete response text, action targets, download availability/errors, queue advance, Escape/focus restoration, loading/error/empty states and long literal text.
- The focused preview test `artifactDownloadNormalizesFileWithoutEvictingRetainedPreview` passes. Dependency-boundary and diff checks pass.
- The independent finish reviewer returned **SHIP**, with no material findings, after inspecting all six captures and the relevant modal, Main handlers, shared controls, curated deliverables, queue code and tests. That review did not independently exercise full-app preview restoration, backend delivery or perceived sound quality.

These results do not establish a full live authenticated end-to-end run or Windows validation. The captures document the isolated native surface rather than a production task completion.
