# Moked desktop coordinator

The native floating coordinator uses `OrchestratorController`. Its transcript and
unsent draft are cached separately for each API origin, authenticated user and
workspace. Switching identity clears visible state, cancels requests and rejects
late replies. Local chat history is limited to 120 messages; a model turn receives
at most 24. The desktop never claims that a failed or unconfigured model replied.

## Deployment

Deploy the Phoenix API and Python worker together. No database migration is
required. The API's existing `:ai_worker` configuration must include a reachable
HTTP URL and token, independently of the mission dispatch transport (SQS in
production). The private endpoint is `http://ai-worker.mokaid-prod.internal:8100`;
see `infra/terraform/WORKER_HTTP.md` for its DNS and API-only ingress. The Python worker requires its existing Anthropic or OpenAI
conversation-model configuration. Missing credentials, timeouts or provider errors
produce `503 orchestrator_unavailable`, preserving the desktop draft.

Voice transcription and speech run through the separate desktop voice runtime.
The conversation coordinator uses the existing server model; the speech model is
not presented as a local reasoning model.

## Authenticated API

- `POST /api/orchestrator/chat`: `message`, `language`, and optional
  `conversation: [{role, body}]`. Requires `agents.view`, `tasks.view` and
  `agents.run_ai`, plus spendable AI credit (using the existing unlimited-plan
  and auto-recharge rules). The credit check happens before model inference.
  Returns `{reply, language, mission_instruction, task_id}`. Agent/task context
  is read from the authenticated workspace; client-supplied snapshots are ignored.
- `GET /api/orchestrator/missions`: up to 50 recently updated workspace tasks,
  including latest run, pending approval, composite wave metadata and verified
  attachment metadata. Requires `tasks.view`.
- `POST /api/orchestrator/missions/:id/stop`: requires `agents.run_ai` and
  `tasks.update`; cancels the task and outstanding composite children while
  retaining already delivered child work. Parent-row locking coordinates this
  with wave advancement. Repeated stops are idempotent.

## Execution and delivery

The model returns a structured proposal and never executes model text as a tool
call. `prepareMission()` passes its brief into the existing MissionController
analysis/review flow. The user reviews the agent, specialist creation and specific
integration grants before launch. The existing dispatch API uses a stable
`client_request_id` to recover uncertain launches without duplicate missions.
An initial proposal can contain multiple deliverables; the existing composite
orchestrator creates dependent waves and hands actual output files between agents.

Mission state is refreshed from the scoped API after launch, websocket rejoin,
task/run/file events and every 20 seconds. Only attachment records marked
`source=output` appear as deliverables. Opening a mission uses the existing task
detail to inspect its files and approve actions; the coordinator never approves
actions or marks work complete from an LLM assertion. A stopped composite parent
cannot advance further waves on a late child completion.

Model output is constrained by a Pydantic schema. The worker rejects task links
outside its supplied snapshot; the desktop also checks links against its currently
loaded task list. Language hints from transcription are sent explicitly and the
reply language is propagated to speech synthesis.

## Native interface and validation

`MokedDock.qml` keeps the companion in the bottom-right corner on every desktop
page, including sign-in. Click Moked or press Command/Control+J to open it.
Dictation is push-to-talk and inserts an editable draft; Enter sends, Shift+Enter
adds a line. Spoken replies are optional. The Missions tab opens actual task
details and only offers a delivery action when output records exist. Completed
status alone does not assert that a file was delivered.

The September 17 implementation builds as
`apps/desktop/build/macos-debug/app/Mokaid.app`. Ten affected native CTest suites
passed, including coordinator, mission, session, office, authorization, activity,
voice and QML coverage. After final fixes, the local voice suite passed 11 QtTest
entries and the interface suite passed nine. Provisioning passed four Python
tests; backend/worker coverage passed ten Elixir and four Python tests. The
distribution suite passed 140 tests with two explicit integration opt-ins skipped.
Dependency boundaries and whitespace checks passed.

The actual packaged Whisper/Kokoro helpers passed an offline French synthesis
and auto-language transcription roundtrip. The native rebuilt app was opened
under a separate validation bundle identity (other Mokaid copies were running),
and its voice settings reported the bundled models ready. No microphone audio
was captured during automated verification. Real acoustic quality and playback,
Windows/x64 acceptance and a live production conversation remain separate checks.

Thirteen labeled synthetic interface captures are in
`artifacts/desktop-orchestrator`. Independent visual review resolved its single
hover-contrast finding; that verdict covers the reviewed fix list. A separate
code review found and fixed duplicate asynchronous audio completion, canceled
model verification losing readiness, and Windows open-file cleanup on errors.

The approach follows explicit mission state, bounded context, scoped tools and
verification of actual outputs described in [OpenAI's agent-building guide](https://openai.com/business/guides-and-resources/a-practical-guide-to-building-ai-agents/)
and [Anthropic's orchestration guidance](https://www.anthropic.com/engineering/building-effective-agents).
These are architectural references, not a claim to reproduce Codex internals.

Chat generation itself has no mission side effects. A retry after an uncertain
network response can generate and meter another model turn; mission launches
use the separate idempotent dispatch contract above.
