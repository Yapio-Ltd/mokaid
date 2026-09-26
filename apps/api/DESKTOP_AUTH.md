# Desktop authentication contract

Mokaid Desktop is a public OAuth-style client. It has no embedded client secret.
The existing browser identity flow (password/Google/Cognito as configured) remains
the identity provider. Desktop consent is explicit and happens in the system browser.

## Native flow

1. Bind a short-lived IPv4 loopback listener to `127.0.0.1`, a dynamically chosen
   port above 1023, and exactly `/callback`. Generate a cryptographically random
   PKCE verifier (43–128 RFC 7636 characters) and state (32–128 base64url characters).
2. `POST /api/desktop/auth/requests` with `code_challenge` (base64url SHA-256 of
   verifier without padding), `state`, `redirect_uri` (`http://127.0.0.1:PORT/callback`).
   S256 is the only supported method. The response is HTTP 201 with
   `data: {request_id, authorization_url, expires_in: 300}`.
3. Open `authorization_url` in the system browser. `DESKTOP_AUTH_WEB_BASE_URL`
   controls its trusted deployment origin; defaults to `https://mokaid.com`.
   The consent screen reuses the existing sign-in page in a separate tab, then
   lets the user explicitly approve the account displayed on the consent page.
4. Authenticated browser `GET /api/desktop/auth/requests/:id` returns request
   metadata and the live browser user. `POST .../:id/approve` returns
   `data: {redirect_url}`. That URL contains only `code` and `state`; request
   approval is single-use. No session credential enters the callback URL.
5. The listener validates Host, path, transaction lifetime and state before
   exchanging the code. `POST /api/desktop/auth/token` with
   `{grant_type: "authorization_code", code, code_verifier, redirect_uri}` returns
   `data: {access_token, refresh_token, token_type: "Bearer", expires_in, user}`.
   Close the loopback listener after success/cancellation/expiry. Never log codes,
   verifiers, state, credentials, or callback URLs.
6. HTTP APIs use `Authorization: Bearer <access_token>`. For Phoenix sockets use
   `X-Mokaid-Authorization: Bearer <access_token>` on the WebSocket handshake and
   `/socket/websocket?vsn=2.0.0` with no credential in the URL. Existing web clients'
   legacy token parameter stays supported; desktop tokens in it are rejected.
   When the optional desktop-only business rollout is enabled, browser Channels
   are refused; see [client access policy](CLIENT_ACCESS.md).
7. Persist the refresh token in the platform credential vault. Before renewal,
   generate a fresh 256-bit base64url `refresh_request_id` (43 characters, no
   padding), and atomically persist it alongside the current refresh token before
   sending the request. Renew before the access lifetime ends (600 seconds) with
   `POST /api/desktop/auth/refresh` and `{refresh_token, refresh_request_id}`.
   Atomically replace the vault entry with the returned refresh token, clearing
   the completed request ID; serialize renewals in the client. If the response is
   lost, malformed, or interrupted by sleep, network failure or process exit,
   retry the same persisted pair. The server returns the same successor credential
   while it remains unused, with a fresh access token. Reconnect channels with the
   fresh access credential and reload missed state. Transient failures preserve
   the vault entry for retry after reconnect or restart.
8. Logout posts `{refresh_token}` to `/api/desktop/auth/revoke`, then erases local
   credentials/cache state. Revocation returns 204 even for an unknown token.

## Security invariants

- Authorization code exchange locks the request. Its verifier, exact callback,
  approval, expiry and single-use consumption are checked within one transaction.
- Refresh/revoke lock the session family. Each rotation consumes one refresh
  credential and inserts a successor hash atomically. The retryable endpoint
  derives its successor with domain-separated HMAC-SHA-256 keyed by the old
  credential and the random request ID. Only the request ID hash is stored with
  the spent credential. An exact retry can recover only its immediate, unused
  successor. A different request ID, a legacy replay, or retry after the successor
  has itself been used revokes the whole family, including newer generations.
- Each first successful rotation renews a 30-day inactivity expiry. Replaying the
  same request does not extend it, and expired or revoked sessions cannot be
  renewed. Users who keep using the app stay signed in across restarts and sleep;
  thirty days of inactivity, explicit logout or account suspension still ends it.
- Legacy `POST /api/desktop/auth/token` with
  `{grant_type: "refresh_token", refresh_token}` remains strictly single-use.
  New clients must not fall back to it: a server without the dedicated retryable
  endpoint returns 404, so preserve local credentials and require a server update.
  The additive request-ID migration and API release must precede the desktop
  release. Never treat transient HTTP/network failures as definitive revocation.
- Live session revocation and current account status are checked on every HTTP
  authentication and socket connection. Established native transports also check
  on incoming frames, outgoing data and at least every 15 seconds while idle.
  Revocation broadcasts a disconnect to that family. Access expires after ten
  minutes even on an otherwise active socket.
- Already-joined workspace/task/agent subscriptions also recheck current active
  membership, including when Phoenix fastlane sends a broadcast directly through
  the transport. A stale successful join never authorizes data after removal.
- Platform roles are resolved from the database, never trusted from a credential.
  Existing workspace membership and platform-admin plugs remain authoritative.
- Auth responses are no-store; request logger filters cover tokens, refresh
  request IDs, PKCE material and codes. Controller rate limits apply separately
  to public request/token/refresh and
  browser consent actions. Browser approval authenticates via Bearer headers,
  not ambient cookies; cross-origin requests are subject to the existing CORS policy.
- Opaque codes and initial/legacy refresh credentials use 256 random bits;
  retryable successors use HMAC-SHA-256 and all use SHA-256 storage hashes;
  signed access payloads contain session/user IDs and expiry, never privileges.
- An hourly Oban job deletes expired authorization/session rows after one day;
  refresh rows cascade on session deletion. Spent refresh hashes are retained
  for 31 days (the full inactivity/recovery window plus one day), then removed
  even while the family stays active. Replaying a removed generation is rejected
  as an unknown token without revoking the live family. Unused current credentials
  are retained until family deletion. This bounds history for persistent sessions.

## Validation

Run `mix test test/mokaid/desktop_auth_test.exs test/mokaid_web/desktop_auth_test.exs`
against a local PostgreSQL instance with the existing pgvector extension. These
cover PKCE/redirect/state validation, code reuse, rotation retry/replay, family isolation,
lost-response recovery, request-ID validation, inactivity renewal,
expiry, suspension, current roles, native header transport, active-socket refusal,
legacy compatibility, route authentication, no-store responses and rate limiting.

Deployment requires the migration before enabling the desktop release and the
consent route in the web build. Integration-provider OAuth and billing retain
their existing browser routes; a native integration transaction/deep-return flow
is separate from this desktop identity handshake.

The optional account-only web/desktop business split is documented in
[CLIENT_ACCESS.md](CLIENT_ACCESS.md). It is disabled by default and must not be
activated before verified desktop installers and update feeds are available.
