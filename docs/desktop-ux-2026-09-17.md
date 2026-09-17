# Native workspace UX verification — 2026-09-17

## Changes

- Fixed thin, empty overflow menus on Agents, feature pages, inspectors, account controls and deliverable previews. All use the shared native menu with a real content width, anchored placement, dynamic item insertion/removal, visible disabled/destructive states and Escape focus restoration. Menus use the stable window content as their parent so selecting an agent cannot destroy the popup when its list row is rebuilt.
- Fixed default view selection during navigation: the new route now determines its own mode, so Tasks reliably opens as a board. All eight task statuses remain represented in four lanes.
- Added compact task cards, per-lane scrolling, board pagination, selection reveal and a clearer task inspector. Brief, actual progress, assignee, due date, project, comments and execution history remain available. Subtask completion recognizes the backend's `done` field.
- Added a two-step agent creation flow with real catalog roles/skills, explicit selection, a compact preview and customization form. Name validation, working style, thinking style, optional settings, cancellation and successful return to the roster are covered.
- Reduced shared collection, metric and shell spacing; kept calendar and detail controls usable at the minimum desktop content size.

## Validation

Built the native `mokaid_desktop` target against Qt 6.11.2 on macOS. No production records were created, deleted or modified by the automated tests.

Passing regression suites:

- `desktop-feature-contracts`: real controller/API contracts, record selection, caches, stale contexts, permissions and action handling.
- `desktop-feature-qml`: 7 QtTest cases, including creation form validation, accessibility text changes, chosen options, preserved specialization, cancellation and successful submission routing.
- `desktop-native-pages-qml`: 34 QtTest cases. Populated Agents, Tasks, Projects, Files, Calendar, Mail, Analytics, Settings, Profile, Members, Integrations, Billing and agent-creation screens; wide and minimum content sizes; route defaults; all task statuses; compact selection; role selection/search.
- `desktop-menu-qml`: 7 QtTest cases for rendered width, dynamic items, disabled actions, pointer activation, checks, submenus, keyboard navigation, Escape focus and row replacement during popup opening.
- `desktop-mission-qml`: 4 QtTest cases for existing mission/preview interactions.
- `desktop-preview-navigation`: 4 QtTest cases, including opening the preview menu and closing it with Escape while retaining the open deliverable.

HTTP fixtures bind isolated loopback ports and require the permitted local-network test environment. Tests assert that fixture servers are listening; an offline empty frame is not evidence of a populated page passing.

Visual checks used the real QML components, including the task board, task inspector, role selection, customization form and minimum-size calendar. Selected captures and the final confirmation log are in `artifacts/desktop-ux-2026-09-17/`.

The rebuilt macOS application was restarted with the user's approval. Connected-workspace checks confirmed the task board with existing records, the creation catalog and required-name form, and the agent row menu after changing selection. The row menu remained visibly open with all actions readable; Escape closed it and returned focus to its opener. The application was left on the Tasks board.

## Scope of evidence

These checks cover native presentation and isolated functional contracts. They do not certify every external integration, paid transaction, Windows behavior, or every administrative workflow against production. Existing feature-parity limits remain documented in `apps/desktop/application/features/PARITY.md`.
