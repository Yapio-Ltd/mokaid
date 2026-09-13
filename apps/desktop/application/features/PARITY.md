# Native feature coverage

This is an endpoint-backed native feature controller, not a claim of visual or
functional parity with every web screen. The registry has 17 client descriptors
and 15 administrator descriptors. Every registered GET/mutation uses an existing
API; there are no example records or placeholder successes in the application.

## Implemented controller behavior

| Existing area | Native behavior backed by live APIs |
|---|---|
| Office / agents / profile / training / creation | Agent list/detail/catalog/training/progression; create, edit, remove, paid copy to another workspace, assign task and upload knowledge; read schedules and permission rules |
| Tasks | List/detail, create/edit/delete, execute/stop, comments, execution history and approval decisions |
| Projects | List/detail, create/edit/delete and assign agents; scoped task list and existing project-folder contents |
| Knowledge | List/full content, create/edit/delete, multipart upload, graph snapshot, rebuild and reindex |
| Files | List/detail, folder creation, rename/move, upload, child/trash inspection, trash/restore and delivery-open signal |
| Calendar | Event list and event creation; the existing API does not expose update/delete event routes |
| Mail | Message list/body, connected accounts, rules, rule creation and mailbox synchronization |
| Analytics | Overview and agent/task metric responses |
| Members | List, invite, edit, remove, link human agent and read leave requests |
| Integrations | MCP catalog merged with actual installation state; install/uninstall, read provider connections; browser handoff for existing OAuth management |
| Profile / settings | Profile/password/avatar and workspace settings/logo |
| Billing | Overview, invoices, plans, credit packs, checkout/portal browser redirects, automatic recharge |
| Admin overview / users / user detail | Metrics/history; user list/detail/summary, update, suspend/unban, password reset, schedule/cancel deletion |
| Admin workspaces / workspace detail | List/detail, update, suspend and restore |
| Admin subscriptions / plans / invoices | List/detail where API supports it; subscription update, plan create/update, invoice mark-paid/void |
| Admin credits / costs / usage | Credit ledger and idempotent adjustments; provider costs/summaries/sync; AI usage events |
| Admin members / invites / audit / logs | Paginated lists, membership changes and invitation cancellation |

## UI contract

`FeatureController` exposes the properties requested by the desktop shell and
`fieldsForAction`, `hasMore`, and `loadMore`. `actions` includes `id`, `title`,
`selection`, `destructive`, `enabled`, `confirmation`, and typed `fields`.
Each field has `key`, `label`, `type`, `required`, `options`, `value`, and
`defaultValue`. Field types are text, multiline, password, email, enum, int,
bool, datetime (ISO 8601), json, and files (local file URLs).

`submit(action, values)` accepts only registered fields. Sensitive operations
require `_confirmed: true`; `_id` can explicitly identify a selected resource.
Credit adjustment requests retain an idempotency key across identical retries
until success or context reset. Other mutations are never automatically retried.
The existing API remains the authoritative authorization/validation boundary.

`records` supports virtualized QML ListView delegates with roles `record`,
`rowId`, `title`, `subtitle`, and `status`. Updates insert/remove/move individual
rows without resetting the model. Non-tabular API metrics are rendered as
named rows with their actual values. Secondary GET actions expose their full
result through `detailView` rather than silently replacing the primary resource.
Edit defaults retain the primary resource independently of secondary reports;
empty fields absent from the server representation do not clear undisclosed
relationships. Nested subscription plan keys are carried into billing-cycle edits.

`detailView` provides a breadcrumb inspector backed by a virtualized list model.
Each object or collection is opened one level at a time; large text is selectable
plain text in Unicode-safe chunks, not truncated or interpreted as HTML. Known
credential/secret fields are withheld at every visited level, and raw nested
objects are never passed through the list's public `record` role. Token-usage
counts remain visible. This is a defensive display filter, not an assertion that
arbitrary free-form user content cannot contain secrets.

Newly consultable real response paths include:

- Task subtasks, comments, approval payloads, run plans/tool activity/output/token
  usage, execution-history collections, and attachment-open actions.
- Project members, agent references, task collections, existing drive-folder
  contents, and primary response metadata (counts/activity) via **Overview**.
- Admin user summaries with memberships, logins, subscriptions and nested plans,
  invoices, credits, usage and audit data; metric histories, provider cost rows,
  totals and reconciliation objects.
- Nested mail rules/accounts, knowledge graphs, calendar metadata and other
  secondary reports exposed by the registered GET actions.

**Record** restores the primary details after inspecting a report. Known nested
resource references open their actual registered detail endpoints; administrator
references remain in administrator navigation and never grant workspace access.
Off-page UUID selections load their detail after the list resolves. Navigation,
account-generation changes and clear operations cancel/discard pending selections.

Only successful client GET responses enter SQLite, under a length-prefixed key
containing server, user, workspace and exact path/query. Navigation epochs and
session generations discard stale replies, including asynchronous cache reads.
Administrator responses are memory-only and clear when access/connectivity is
lost. Offline views read previously synchronized data; mutations require online
authorization. Admin lists implement the existing page/per_page contract.

## Not yet represented as complete native workflows

- Rich calendar grids and interactions, graph visualization, analytics charts
  and nested project/task board interactions. The shell's onboarding controller
  is separate from this registry.
- Schedule/rule editing, team/role pickers populated from catalogs, leave review,
  full hierarchical drive navigation, a unified selected-trash-row restore flow,
  and file download/save dialogs. IDs required by exposed advanced actions are
  currently entered explicitly.
- Mailbox connection setup, rule update/delete and rich mail formatting.
- OAuth provider transactions returning directly to the native client.
- Full notification/search/conversation/streaming integration belongs to the
  shell's dedicated controllers, outside this generic registry.
- Browser-layout parity, all copy, accessibility behavior and end-to-end human
  acceptance on the 32 existing screens still need dedicated verification.

`desktop-feature-contracts` tests registry security boundaries, response-shape
extraction, genuine installation-state merging, incremental model invariants,
server/user/workspace cache isolation, stale network responses after account
changes, administrator revocation and zero administrative SQLite writes,
secondary-report/edit isolation, undisclosed relationship preservation, and
explicit confirmations with stable credit-adjustment retry keys. It also covers
deferred/off-page selection, navigation/account cancellation, nested online and
cached execution reports, 2,000-row model invariants, Unicode-safe complete text,
credential display filtering, attachment metadata and admin-only references.
`desktop-feature-qml` renders the actual FeaturePage with production Basic style
and real controller models against a local HTTP fixture, then navigates comments
and verifies an offscreen rendered frame and zero QML runtime warnings. HTTP tests use
an isolated loopback fixture and SQLite tests use temporary directories.

The native suite runs with Qt 6.11.2. On this macOS 26.5.1 / AppleClang 17 host,
the combined AddressSanitizer runtime deadlocks before `main` in its shadow-memory
initialization; a process sample confirms the recursive sanitizer allocator lock.
Normal builds and separate UBSan tests remain runnable. ASan execution is not claimed validated on
this host; supported CI/machine sanitizer runs remain required.
