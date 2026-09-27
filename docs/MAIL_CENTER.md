# Native mail center

The desktop mail center uses the connected workspace mailboxes. Its folder pane, message list and reader share a selected account. Search, unread/starred filters, sorting and pagination are server-backed; folder and label counts describe synchronized messages.

## Delivery checkpoint — 27 September 2026

API revision 58 and worker revision 51 are deployed and stable, with all four mail-center migrations confirmed in the production database. The real Gmail account is active with 106 synchronized messages. A read-only production check hydrated an existing message and downloaded its 690-byte attachment successfully; no provider state was changed and no email was sent. The production receipt is retained privately. Later fixture-based client checks are recorded in [the desktop and web validation report](RELEASE_VALIDATION_2026_09_27.md).

The new desktop application is compiled at `apps/desktop/build/macos-debug/app/Mokaid.app`. Automated verification passed 104 API tests, 184 Python tests and 157 QtTest invocations (including setup/cleanup). Wide and compact native views were inspected using fixtures. Opening the built application for a final check against the live mailbox is still blocked by the Mac lock screen. The sanitizer executable compiled but timed out before running tests; it is not counted as passing.

## Message reading and attachments

Previously imported messages are hydrated when opened, so reconnecting a mailbox is not required to retrieve their HTML, attachment metadata or reply headers. A provider failure remains visible and does not erase the cached message.

Message HTML is structurally sanitized on the worker and reconstructed as inert rich text in the desktop. Email images and active content do not load automatically. Attachments are retrieved through authenticated, workspace-scoped API routes; provider tokens and arbitrary download URLs never reach the desktop. Each download is bound to its message and account, bounded to 20 MiB, returned with `no-store`, `nosniff` and an attachment content disposition.

View and Download are available on attachments. HTML and SVG previews remain inert text, including when their MIME type is misleading. On macOS, validated PDF attachments use native Quick Look; the live Quick Look check remains pending the Mac unlock. Unsupported previews retain the download option.

## Sending

Compose and reply submit the selected mailbox through Gmail, Microsoft Graph or verified TLS/STARTTLS SMTP. The server chooses the sender from the authorized account and derives reply headers from a message in that same account. Only Owner and Admin roles receive `mail.send` and `mail.manage`; the API enforces these permissions independently of the interface.

An outgoing message supports To, Cc, Bcc, a plain-text body and up to ten attachments totaling 5 MiB. The worker constructs MIME, includes a safe HTML alternative, and does not accept arbitrary sender headers. SMTP does not transmit Bcc headers to recipients.

Every send has a durable, member/workspace-scoped request UUID and content hash. A repeated UUID returns the existing receipt; a changed payload conflicts. Provider acceptance means `sent`, a definite rejection means `failed`, and an interrupted or ambiguous submission means `unknown`. Unknown sends are never automatically resubmitted. Acceptance is not a guarantee of delivery to the recipient's inbox.

Compose and reply drafts remain in memory and survive ordinary request failures; they are not durable drafts across application restarts. The desktop guards closing or switching workspaces while a draft or uncertain submission needs attention. An uncertain request retains its original UUID and payload so checking its status cannot create a second provider submission.

Accepted messages appear in Sent. Outgoing attachment bytes are encrypted in the outbox so they remain downloadable when SMTP does not provide an immediate provider message identifier. No real email is sent by the automated tests.

## API

| Route | Purpose |
| --- | --- |
| `GET /api/mail/messages` | Filtered, sorted and paginated message list |
| `GET /api/mail/folders` | Synchronized folder and label counts |
| `GET /api/mail/messages/:id` | Hydrated reader content and attachment metadata |
| `PATCH /api/mail/messages/:id` | Provider-backed read, star, archive, spam and soft-trash actions |
| `GET /api/mail/messages/:id/attachments/:attachment_id` | Authenticated attachment download |
| `POST /api/mail/send` | Validate, claim and submit an outgoing message |
| `GET /api/mail/outbox/:id` | Read the initiating member's durable send status |

Message actions update the local view only after provider confirmation. No permanent deletion is implemented. IMAP moves require the server's supported MOVE operation and an identified destination folder; unsupported actions fail explicitly.

Google connection configuration and the verified browser-to-desktop flow are documented in [Google connections](GOOGLE_CONNECTIONS.md).
