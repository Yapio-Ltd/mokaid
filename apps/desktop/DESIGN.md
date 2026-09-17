# Native workspace design

The current desktop application uses Qt Quick/QML, not the web React/Tailwind shell. Its visual reference is the user-supplied `ChatGPT Image Sep 16, 2026, 10_36_57 PM.png`. Native changes must be built into the `mokaid_desktop` target and checked in `apps/desktop/build/macos-debug/app/Mokaid.app`; web changes do not update this executable.

## Scope and visual system

All native workspace pages share `Theme.qml`, locally bundled Manrope, dark midnight surfaces, a compact inset sidebar, violet focus/selection, and consistent controls. Agents follows the reference composition: filterable roster, exact-source portraits, a selected-agent inspector, and aggregate metrics. Office keeps its native 3D viewport and mission/chat behavior. Tasks, Projects, Files, Calendar, Mail, Analytics, and Settings use layouts suited to their content. Account and administration pages share the same visual system.

The separate Knowledge destination is removed from native navigation, feature registration, and global-search results. Existing backend knowledge and agent reference files are preserved.

## Data and behavior

- Overflow menus share `MokaidMenu`: content-sized width, compact rows, anchored placement, live action models, keyboard navigation and focus restoration. Replacing the background of a raw Qt menu without preserving its implicit width collapses the popup; do not reintroduce that pattern.
- Tasks open in board mode on navigation. Four lanes retain every backend status; canceled work is clearly labeled within Finished. Cards prioritize title, assignee, project, status, priority and actual progress. The inspector presents the brief and useful actions before expandable metadata.
- Agent creation is a two-step flow: a searchable specialty catalog with a persistent selection, then a focused name/mission/working-style form. Technical settings remain available under optional settings. Creating from another agent surface enters this same flow.
- Shared collections use compact cards and rows; summary metrics and the shell header leave room for the actual work. Minimum-width detail views replace the collection temporarily and retain an obvious close action.

- Live controllers remain the source of records, selection, authorization, offline state, actions, and forms. No reference names or invented statistics are supplied as runtime fallback data.
- Performance is the current `performance_score`, not a success rate. Completed missions come from `missions_completed`. Missing measurements remain unavailable. Historical graphics require actual dated records.
- Portraits match the actual avatar source. Unknown sources get an honest identity fallback, not an unrelated stock character.
- Nested display records pass through bounded credential filtering. Technical identifiers belong to advanced forms; required missing fields must remain discoverable.
- Preserve keyboard access, visible focus, plain-text user content, protected drafts, retained deliverables, workspace isolation, and confirmation for destructive actions.
- Verify wide and minimum desktop sizes, empty/error/loading states, selection, and real action routes. Keep test fixtures confined to tests.

## Implementation map

- `presentation/qml/DesktopShell.qml`: navigation and top bar.
- `AgentsPage.qml`, `WorkforcePortrait.qml`: dedicated workforce view.
- `FeaturePage.qml`, `FeatureCollection.qml`, `FeatureCalendar.qml`, `FeatureSummary.qml`, `FeatureInspector.qml`, `FeatureLogic.js`: other workspace and administrative views.
- `OfficePage.qml`, `OfficeStat.qml`, `AgentCard.qml`: native Office chrome.
- `application/features/FeatureController`: real data and endpoint-backed operations.
