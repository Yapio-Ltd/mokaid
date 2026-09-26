# Native workspace design

The current desktop application uses Qt Quick/QML, not the web React/Tailwind shell. Its visual reference is the user-supplied `ChatGPT Image Sep 16, 2026, 10_36_57 PM.png`. Native changes must be built into the `mokaid_desktop` target and checked in `apps/desktop/build/macos-debug/app/Mokaid.app`; web changes do not update this executable.

## Scope and visual system

All native workspace pages share `Theme.qml`, locally bundled Manrope, dark midnight surfaces, a compact inset sidebar, violet focus/selection, and consistent controls. Agents follows the reference composition: filterable roster, exact-source portraits, a selected-agent inspector, and aggregate metrics. Office keeps its native 3D viewport and mission/chat behavior. Tasks, Projects, Files, Calendar, Mail, Analytics, and Settings use layouts suited to their content. Account and administration pages share the same visual system.

The separate Knowledge destination is removed from native navigation, feature registration, and global-search results. Existing backend knowledge and agent reference files are preserved.

## Data and behavior

- Overflow menus share `MokaidMenu`: content-sized width, compact rows, anchored placement, live action models, keyboard navigation and focus restoration. Replacing the background of a raw Qt menu without preserving its implicit width collapses the popup; do not reintroduce that pattern.
- Tasks open in board mode on navigation. Four lanes retain every backend status; canceled work is clearly labeled within Completed. Cards prioritize title, assignee, category, priority and actual progress. The inspector presents the brief and useful actions before expandable metadata.
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
- `TasksPage.qml`, `TasksBoard.qml`, `TaskBoardCard.qml`, `TasksInspector.qml`: task board, local filters, drag targets and task detail drawer.
- `FeaturePage.qml`, `FeatureCollection.qml`, `FeatureCalendar.qml`, `FeatureSummary.qml`, `FeatureInspector.qml`, `FeatureLogic.js`: other workspace and administrative views.
- `OfficePage.qml`, `OfficeStat.qml`, `AgentCard.qml`: native Office chrome.
- `application/features/FeatureController`: real data and endpoint-backed operations.

## Moked companion

Moked extends the native workspace with an always-available bottom-right launcher and a compact floating Conversation/Missions panel. It retains the existing midnight surfaces, bundled Manrope, violet selection and focus, rounded controls, and live-controller data model. The panel leaves the surrounding workspace usable and contracts at the minimum desktop size. Shared highlighted `MokaidButton` actions keep readable light text across resting, hover, and pressed violet fills.

The companion is a smooth asymmetric seed with a nacre shell, folded violet leaf, expressive ink eyes, and small floating hands. Its laptop signals active mission work; listening and speaking replace the smile with audio bars, while thinking changes its gaze. Keep these state cues legible when motion is reduced. Ambient animation pauses when the window is minimized; reduced motion removes transitions and looping movement.

Conversation, mission proposals, progress, and delivery links use the existing mission review and detail flows. Local dictation inserts an editable draft for review before Send, and spoken replies receive the reply's language. Preserve Ctrl/Cmd+J, Escape and focus restoration, explicit microphone controls, offline drafts, protected work during close/update, and workspace/sign-out reset behavior.

`presentation/qml/MokedDock.qml` owns the surface, `MokedMascot.qml` its character, and `Main.qml` the shell integration. Behavioral and service contracts live in [the coordinator contract](../../docs/desktop-orchestrator-contract.md) and [local voice documentation](voice/README.md). The 13 captures in `artifacts/desktop-orchestrator/` and `tests/orchestrator_qml_tests.cpp` are isolated synthetic UI evidence, not live-backend or physical-device voice evidence; keep fixture content confined to tests.

## Marketplace extension

The Marketplace design authority is the user-supplied `ChatGPT Image Sep 25, 2026, 10_54_54 AM.png`. It extends the existing native system with midnight cards, violet selection and actions, bundled Manrope, source-matched agent portraits, and a luminous purple hero. The supplied reference governs Marketplace composition while shared shell controls, accessibility, and minimum-width behavior remain inherited.

`MarketplacePage.qml` coordinates five presentation components: `MarketplaceDiscover.qml` for browsing, categories and search; `MarketplaceCard.qml` for listings; `MarketplaceDetail.qml` for details, checkout and success; `MarketplaceSeller.qml` for seller listings and publication; and `MarketplaceEarnings.qml` for revenue and orders. Runtime content comes from real records. Keep fixture names, ratings and statistics out of fallback data, and derive historical charts only from actual dated records. Favorite listing IDs persist locally under the current workspace.

Purchasing opens secure external checkout. A checkout response or return to the app alone must not display success: require the matching persisted order to have `status: fulfilled` and a `cloned_agent_id`. Show pending/error states and allow payment-status refresh until that confirmation is available. The [Marketplace capture guide](../../artifacts/marketplace-reference-2026-09-25/README.md) identifies synthetic native content-area screenshots and their limits; no real payment was charged for those captures. Hero generation provenance is recorded beside the asset in `presentation/assets/marketplace-hero.provenance.json`.


## Office immersion

Office retains its original overview and adds an explicit “Enter office” mode. The native camera moves at eye level over a fixed, collision-validated network joining all nine desks and eight shared destinations. A small route map and named destination selector expose the available paths; dragging or arrow keys changes the view without creating a path. Scene labels retain actual agent identity and current visual activity. Selecting an agent in immersive mode approaches their desk, settles the view toward their face, and then opens the conversation. Agents away from their desk return through their existing movement sequence.

The immersion controls inherit the native midnight surfaces, Manrope typography, violet selection, existing spacing and focus tokens. Clicking an agent opens the existing controller-backed conversation in a compact overlay; typing, panel interaction, loss of focus and page changes stop walking. Overview/Escape restores the original camera and prior overview chat selection, retaining per-agent drafts. Reduced motion disables automatic camera rotation. `OfficeTourControls.qml` owns the route map; `NativeViewport` bridges the deterministic engine tour. Isolated screenshots and their limits are documented in [the immersion capture guide](../../artifacts/office-immersion-2026-09-25/README.md).

## Tasks reference extension

The Tasks surface follows `ChatGPT Image Sep 25, 2026, 11_27_22 AM.png`: four compact metrics, five ownership/date filters, four midnight Kanban columns, violet controls, category/priority chips and restrained completion styling. Counts come from actual loaded tasks; the inconsistent sample totals in the supplied reference are not copied into runtime data. At narrow desktop sizes, columns keep a readable minimum width and scroll horizontally. Each column scrolls vertically; dragging near an edge scrolls the board or column.

A move sends only the new status through `FeatureController::moveTask`. The source card stays until the server confirms the update. Offline/read-only/in-flight states prevent mutation; failed requests keep the original card and show recovery feedback. Escape cancels a drag, while the card action menu supplies a keyboard alternative. Backend waiting, blocked and overdue states remain in Needs attention, canceled tasks remain explicitly labeled in Completed, and SEO report pauses preserve their existing grouping.

The right-hand drawer exposes Overview, Activity and Files, all eight task statuses, the real brief/subtasks, agent actions and a fixed comment composer. It blocks underlying board controls while open, and closing it returns focus to the task. Drafts remain per task while navigating the current workspace, survive failed sends, and protect application close/update; changing workspace or signing out clears them. A successful comment clears only the matching submitted draft. Response feedback stays inline: accept the response, or enter a prompt to continue and improve the same task. Feedback submits the reviewed run ID, keeps per-task instruction drafts on close or error, and clears only the matching submitted draft after success. Technical action-review forms are not exposed. PDF export runs automatically and legacy PDF pauses display progress without approval controls. Genuine non-PDF permissions and delivery-format questions remain inline with their actual request ID supplied by the controller.

The API now returns current membership, task-update capability, assigned-member identity and real agent portrait metadata. Native ownership filters and enriched portraits require that API version; status changes continue to use the existing task PATCH endpoint. Synthetic content-area captures and test details are documented in [the Tasks capture guide](../../artifacts/tasks-reference-2026-09-25/README.md). No production task was changed to generate these captures.

## Native mailbox connection

Mail exposes “Connect mailbox” in its header and empty state. `MailConnectDialog.qml` offers Google browser sign-in and IMAP/SMTP setup; iCloud, Yahoo and Gmail app-password presets fill verified server settings, while optional settings expose custom usernames, explicit TLS/STARTTLS and separate SMTP credentials. The reconnect form keeps the email identity fixed. `MailAccountsBar.qml` filters messages by actual account IDs, and `MailAccountsDialog.qml` provides status, sync, reconnect and confirmed disconnection.

`MailAccountsController` sends credentials only to the authenticated API and never writes them to desktop storage. Google authorization runs in the system browser; an owner-scoped server transaction completes it, and native polling waits for persisted connection status before reporting success. Cancellation is acknowledged by the server and handles an already-completed connection. Account/workspace changes discard forms, pending native state and secrets. Mail synchronization refreshes accounts and messages automatically for two minutes after connection or a sync request, and only a fresh persisted sync timestamp confirms completion.

Native transport and QML coverage includes Google completion/cancellation races, strict browser URLs, credential filtering, IMAP/SMTP payloads, server errors, account filtering, workspace reset and the 760×620 connection form. [Mailbox captures](../../artifacts/mail-desktop-2026-09-25/README.md) use isolated synthetic HTTP fixtures; they do not claim access to real mailboxes or live provider sign-in.


## Office render and presence refinement

The September 25 `office.png` reference governs the office refinement: satin floor
reflections, violet/blue light inlays, warm desk lamps, clean existing character
identities, and adjacent furnished offices in place of empty black surroundings.
The environment reuses the authored furniture and adds a ceiling only in immersion;
overview keeps the room open and reserves a small margin for its neighbors.

Floor markers are projected through the native camera, hidden behind furniture,
and lead only along validated paths. Their keyboard names identify destinations.
The entrance looks into a clear aisle so the first marker is immediately visible.
Walking accelerates and brakes; talking agents put their hands at rest and gently
turn their upper body toward the visitor, then return to their existing pose.
Custom rigs without a recognized gaze chain retain their valid original animation.

Bundled characters use coherent surface normals and recovered original 2K facial
atlases where verified against their current UV layouts. Each of the seven
character families has a calibrated, gentle smile; Legal's expression also
relaxes the inner brows. Preserve existing teeth, identity, outfits and variant
colors. In immersive automatic quality mode, render at native pixel density so
these details survive close conversations.

Work indications come from assigned task records and run state. Active badges have
a restrained mint sweep, current percentage when present, and the actual title in
the accessible description. Physical monitors display the same task's title,
progress and recent server-reported actions. No fabricated charts, code, or
progress appear on assigned monitors. Offline/unavailable states remain explicit;
reduced motion keeps the state text while suppressing looping effects.

## Agent detail reference extension

The September 26 `ChatGPT Image Sep 26, 2026, 08_44_10 PM.png` governs the agent drawer in Office overview and Agents: a large source-matched portrait, live presence and level, a compact metric strip, violet segmented navigation, activity and recent tasks, and five persistent bottom actions. `AgentDetailPanel.qml` owns this shared composition; `AgentDetailContent.qml` owns Tasks, Knowledge and Settings. Immersive Office keeps its direct conversation overlay.

The three metrics use actual completed missions, recorded performance and average elapsed duration for completed assigned tasks with timestamps. Missing metrics display a dash; reference-image numbers and agent identities are never runtime defaults. Current Office activity prefers live roster/task state to older detail responses. Agent tasks and references are loaded through workspace-scoped endpoints, with independent loading, cache, failure and stale-selection handling.

Chat opens inside the drawer with a reduced profile to reserve room for messages. Missions, reference uploads, marketplace offers and destructive actions retain the existing controller/dialog flows. Tasks offer scoped search and filters; Knowledge exposes actual reference indexing states, skills, progression and training; Settings saves only edited fields and presents permission rules and schedules in readable form. Unsaved settings survive tab/agent changes and navigation within the current account/workspace and participate in application close/update protection. Account and workspace changes clear them.

The header contracts at short window heights, the main content scrolls, and actions stay fixed. Keyboard tab arrows, Escape, native focus indicators, readable empty/error/offline states and reduced-motion behavior remain available. Verification and synthetic screenshot provenance are recorded in `artifacts/agent-detail-2026-09-26/README.md`.
