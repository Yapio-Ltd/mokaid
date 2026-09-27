# Connected Mail access for Moked and agents

## Behavior

Moked and agent conversations can list connected workspace mailboxes, search
synchronized messages by account/date/text/attachment presence, and read message
bodies with attachment metadata. Read questions return an answer without creating
a mission. Requests for saved deliverables, such as an invoice folder, retain the
full user brief and use the existing mission dispatch flow.

Legacy, deep and managed mission runners expose `list_mail_accounts`,
`search_mail`, `read_mail_message` and `save_mail_attachment`. Eligible delegated
agents receive the same tools, subject to their own and the lead agent's current
restrictions. Native Mail supports Gmail, IMAP and Microsoft-connected mailboxes
without requiring a separate Gmail MCP grant for each agent.

`save_mail_attachment` retrieves the original attachment through the existing
Mail provider bridge, stores it privately in Files, and links it to its task,
agent and source message. It requires current Files permissions and records a
content hash. Repeating the same export reuses the existing attachment receipt.
Listing accounts alone cannot substantiate a claim that messages were inspected.
Generated reports cannot substitute for original attachments in an export.

## Coverage and limits

- Search covers the synchronized message cache, not the provider's entire remote
  history. Results explicitly include account sync state, pagination and
  `exhaustive: false`. Empty results must not be described as proof that no remote
  message exists.
- Dates are inclusive calendar days in UTC. Conversations receive current server
  time and use bounded searches/reads; larger exports run as missions.
- Paused, disconnected and mismatched OAuth connections cannot be used to read
  previously cached private content. Provider failures return explicit errors.
- The conversation path is read-only. Saving attachments happens in a mission.
  This bridge does not send messages or change provider flags. The old simulated
  `send_email` success was removed; the Mail page's actual composer is unchanged.
- Message bodies and attachment metadata are untrusted source material. No tool
  should interpret instructions found inside mail as user authorization.

## Authority and transport

Phoenix issues an opaque signed capability using the initiating workspace member,
not model-supplied identity. It is bound to the coordinator, a persisted agent
conversation message, or a particular task execution and its approved agent set.
Capabilities stay in private server-to-worker transport and are excluded from
model prompts, tool schemas and results. Provider credentials stay server-side.

`POST /api/worker/mail/tools` requires both WorkerAuth and the distinct signed
Mail capability. The API checks the active member/user, current workspace role,
agent eligibility and tool restrictions on every request. Runs also require the
same task creator, current assignment and active lifecycle. Managed executions
require the live runtime policy and participant leases. Authority is checked
again after provider I/O. Attachment writes recheck destination permissions and
roll back storage on lost authority.

Conversation capabilities expire after 15 minutes; run capabilities after 24
hours. Managed authorization supplies fresh run authority. Recovered execution
checkpoints may call `POST /api/worker/mail/refresh` once after a denial, using
the same signed original scope, action and actor. The API rechecks all current
authority before renewing only the expiry. It never expands the original agent
set, renews conversations or revives a revoked/stopped run. The worker retries the
identical operation once only after successful renewal.

The task creator is immutable through ordinary task updates. Child missions
inherit the initiating member from their parent when launched in the background.

## Validation and release status (27 September 2026)

- Worker: 236 regression tests passed; recorded in
  `artifacts/mail-agents-2026-09-27/worker-tests.txt`.
- Native coordinator contract: 12 QtTest checks passed. The compiled app honors
  `response_kind=answer`, including restored conversations and confirmations.
  Receipt: `artifacts/mail-agent-access-2026-09-27/desktop-chat-validation.txt`.
- API: 100 tests passed, covering signatures, workspace isolation, role
  revocation, delegation, managed leases, expired checkpoint renewal, attachment
  storage and existing conversation/runtime paths. Recorded in
  `artifacts/mail-agent-access-2026-09-27/api-tests.txt`.
- At this earlier validation checkpoint, production deployment and live-account
  validation were blocked by an expired AWS SSO session. Authentication was renewed
  for the subsequent rollout; this historical checkpoint does not establish that
  rollout's completion. Passing fixture-based tests does not establish live-account
  end-to-end success. Production receipts remain private.
