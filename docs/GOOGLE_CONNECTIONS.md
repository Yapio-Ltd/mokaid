# Google connections — 27 September 2026

This records the confirmed incident and the implementation prepared on 27 September. The production Google provider catalog repair is complete. A real Gmail connection completed after that repair: the browser displayed “Gmail connected”, the desktop automatically closed the dialog and showed one mailbox, and production recorded an active mailbox with 25 synchronized messages. API revision 57 and worker revision 50 rolled out successfully at that checkpoint. The production repair receipt is retained privately. The earlier mailbox implementation and deployment record remain in [Desktop mailbox connections](MAIL_CONNECTIONS.md).

The subsequent [Mail Center release](MAIL_CENTER.md) retains these Google components and is now deployed as API revision 58 and worker revision 51. The native application is compiled and tested; its final live UI check is blocked by the Mac lock screen. Production now has 106 synchronized Gmail messages, and a real attachment download has been verified. The production receipt is retained privately; see [the client validation report](RELEASE_VALIDATION_2026_09_27.md) for the later fixture-based desktop and web checks.

## Confirmed incident and repair

There were two independent problems. Google rejected the selected account because the OAuth application was in **Testing** and that account was absent from the test audience. The audience now contains two test users, including the account involved in the incident. Adding a test user permits that account to reach consent; it does not grant mailbox access on its behalf.

After Google consent, production still returned a connection failure. A read-only database diagnostic found **none of the six Google entries in `integration_providers`**. One attempt had failed with `mail_permission_required` because Gmail permission was not granted; the later attempt failed with `connection_failed` because the provider catalog row was missing. The existing workspace/provider/account unique index was present. This was not evidence of a PKCE, callback URL or encryption-key failure.

The immediate production repair inserted only the six missing Google provider definitions, without overwriting existing rows or changing credentials. All six enabled rows were then verified. The durable implementation adds:

- Migration `20260927100500_seed_google_integration_providers`, using inserts that ignore existing keys.
- A canonical `GoogleCatalog` reused by release seeding and development seeds.
- Catalog checks before authorization starts and when providers are listed, so an absent definition is repaired before consent.
- Preservation of existing provider settings, including an administrator's disabled state. A disabled provider cannot start authorization.

## Services and permissions

Each connection requests the selected service's scope plus `openid` and `email`. All scopes below use the `https://www.googleapis.com/auth/` prefix. Existing broader grants are accepted where they satisfy the required read scope; the new request itself uses the narrower scope.

| Provider key | Requested service scope | Implemented agent tools |
| --- | --- | --- |
| `gmail` | `gmail.modify` | List message IDs and read message content |
| `google_calendar` | `calendar.readonly` | List calendars and events |
| `google_drive` | `drive.readonly` | List files, read metadata and export supported files as text |
| `google_docs` | `documents.readonly` | Read document text, including tabs and tables |
| `google_sheets` | `spreadsheets.readonly` | Read spreadsheet metadata and cell ranges |
| `google_meet` | `meetings.space.readonly` | Read meeting spaces and conference records |

The built-in agent tools are read-only for all six services. Gmail retains its existing `gmail.modify` mailbox scope; it is not a read-only OAuth grant. The other five services request read-only authorization. This release does not create Calendar events, write Drive files, edit documents or spreadsheets, or create Meet meetings.

Gmail authorization creates or reconnects the matching mailbox and queues its initial synchronization. Calendar and Files connection controls authorize Google access; they **do not import Google events or files into the native Calendar or Files views**. The new service access is usable through the explicitly granted agent tools described below.

## Desktop authorization and API contract

The desktop opens Google's authorization page in the system browser. The existing API server completes the exchange using the confidential Google web client; client secrets and refresh tokens remain on the server. The registered callback stays `https://mokaid.com/api/mail/oauth/google/callback`, including for the other five services. No desktop URL handler or browser Mokaid login is required to complete that callback.

The flow retains S256 PKCE, encrypted state, a ten-minute lifetime, and authenticated polling bound to the initiating member and workspace. The persisted provider must match the encrypted state. Expiry and current member/user permissions are checked again after the network exchange, before the connection is committed. Cancellation is server-side: a pending flow becomes failed, while a connection that already committed is reported as connected. Transient cancellation failures retain the pending flow in the desktop.

| Method and path | Contract |
| --- | --- |
| `POST /api/integrations/google/desktop/start` | Body `{ "provider_key": "google_calendar" }`, or another supported key; returns `data.authorize_url` and `data.flow_id` |
| `GET /api/integrations/google/desktop/:id` | Returns the initiating member's `pending`, `connected` or `failed` state with provider/connection metadata |
| `DELETE /api/integrations/google/desktop/:id` | Cancels that member's pending flow; retains its terminal state for polling |
| `GET /api/mail/oauth/google/callback` | Public server callback shared by all six services; validates the saved flow and encrypted state |
| `GET /api/integrations` | Lists saved integration connections for the current workspace |

Successful generic polling includes `provider_key`, `connection_id`, `connected_account`, `mcp_status` and `mcp_connected_account`. `account_id` identifies a Gmail mailbox when applicable. The existing `/api/mail/oauth/google/start` and `/api/mail/oauth/:id` mailbox contracts remain compatible; the generic routes add service metadata without changing the old responses. Migration `20260927100000_extend_native_google_oauth_flows` adds the provider and integration-connection references to the saved flow.

Google may show an `access_denied` page without returning to the callback. The desktop waiting screen therefore includes test-audience guidance and a retry/cancel path. Callback errors use fixed, sanitized messages; arbitrary Google query text is not displayed or trusted as diagnosis.

## Agent grants and account selection

Saving an OAuth connection does not grant access to an agent. An explicit agent MCP grant is still required. The built-in Google transport uses fixed Google HTTPS endpoints and bounded GET requests; it does not require a remote MCP server URL. Redirects are refused, pagination is explicit, and upstream errors are sanitized.

Multiple accounts can be authorized for a service, but the current MCP catalog has **one installation per service per workspace**. The first connected account binds that installation to its exact integration connection. Reconnecting the same account updates that binding safely. Connecting a different account saves its independent authorization and reports `mcp_status: "different_account"`; it does not silently switch the account accessible under existing agent grants. The desktop shows the selected account. There is no new automatic account-switching or agent-grant operation in this release. Gmail mailboxes retain independent mailbox synchronization.

The installation stores an `integration_connection_id` pointer and account identity, not a duplicate token. Before a managed tool call, the API resolves the live connected integration by workspace, provider, account and pointer, refreshes credentials if required, then rechecks grants, connection status and binding. Only the access token and its scope/expiry metadata reach the worker; the refresh token remains encrypted on the API server. Revoking a grant, disconnecting, or changing the binding during refresh prevents that call from obtaining a descriptor. If the MCP installation is unavailable, including because of a plan limit, authorization can remain saved with `mcp_status: "unavailable"`.

## Testing mode limitation

The Google application remains in **Testing**, with two allowed test users at this checkpoint. Other Google accounts cannot use these service authorizations until the audience or publication state changes. Because these requests include service-data scopes, Google's seven-day refresh-token expiry for external applications in Testing applies; reconnecting may be necessary even when the initial connection succeeds. The identity-only exception does not apply here. See [Google's refresh-token expiration rules](https://developers.google.com/identity/protocols/oauth2#expiration).

OAuth publication and any required Google scope verification remain separate from adding test users or repairing the application catalog. This document does not claim either is complete.

## Verification checkpoint

The combined local API regression run passed **87 tests**, covering the existing Gmail contract, six-provider authorization, catalog repair and disabled-state preservation, scopes and refresh-token requirements, cancellation, account binding, explicit grants and revocation during token refresh. From `apps/api`:

```sh
mix test test/mokaid/google_mail_oauth_test.exs test/mokaid/mail_oauth_flow_test.exs test/mokaid/native_google_integrations_test.exs test/mokaid_web/mail_oauth_controller_test.exs test/mokaid_web/client_access_test.exs test/mokaid/mcp_google_test.exs test/mokaid/mcp_test.exs test/mokaid/managed_runtime_test.exs
```

These tests stub Google responses. Separately, real Gmail consent completed at 21:48:58 UTC on 26 September (27 September local time), followed by 25 synchronized messages at 21:50:00 UTC. The initiating desktop updated automatically. The real-account verification receipt is retained privately and is not published with the source. No live Calendar/Drive tool read is claimed by these checks.

For the original official OAuth, Gmail and Pub/Sub references, see [Provider references](MAIL_CONNECTIONS.md#provider-references).
