# Browser account portal / desktop business access

`MOKAID_DESKTOP_ONLY_BUSINESS=false` is the default. No existing browser workflow
is removed merely by deploying this code. `true` enables the restriction; other
values fail configuration explicitly. The web build has its own matching
`VITE_DESKTOP_ONLY_WEB` rollout switch; coordinate both during release promotion.
`GET /api/me` also exposes the authoritative server setting in
`client_policy.desktop_only_business`.

## Authenticated HTTP allowlist when enabled

Browser credentials may call only these existing account/support actions:

| Purpose | Method and route |
|---|---|
| Account and profile | `GET /api/me`, `PATCH /api/me`, `POST /api/me/password` |
| Personal avatar | `GET`, `POST`, `DELETE /api/me/avatar` |
| Workspace selection/details | `GET /api/workspaces`, `GET /api/workspaces/:id`, `GET /api/workspaces/:id/logo` |
| Membership inspection | `GET /api/members` |
| Subscription, usage and spending | `GET /api/billing/overview` (usage, daily usage, credits and ledger) |
| Invoices/catalog/config | `GET /api/billing/invoices`, `/plans`, `/credit-packs`, `/config` |
| Billing management | `POST /api/billing/change-plan`, `/checkout`, `/credits/checkout`, `/auto-recharge`, `/portal` |
| Desktop consent | `GET /api/desktop/auth/requests/:id`, `POST /api/desktop/auth/requests/:id/approve` |
| Existing integration OAuth completion | `POST /api/integrations/{google,github,linear,slack,notion,microsoft}/oauth/callback`, `POST /api/mcp/figma/oauth/callback` |

All other authenticated controller/actions are default-deny for browser sessions:
agents, office, training, conversations, tasks, projects, knowledge, drive/raw
files, mail, calendar, search, notifications, analytics, operational integrations,
workspace/member mutations and every admin action. New actions are denied unless
explicitly reviewed and added to `Mokaid.Auth.ClientPolicy`.

The matched method/path is resolved by Phoenix's compiled router, not textual
prefix matching. A denied authenticated browser call returns HTTP 403 with
`error.code=desktop_required`, a public download-page URL and `Cache-Control:
no-store`. Anonymous/invalid authentication still returns its existing 401/403.

## Identity and permissions

Only session metadata from the existing cryptographic verifier identifies a
desktop credential. A desktop access token must pass its signature, expiry,
live session-family and account checks before the policy runs. Changing a
User-Agent, `X-Mokaid-Client`, bearer prefix or WebSocket header is insufficient.
This is credential-class enforcement, not binary/device attestation: possession
of a valid native bearer credential still confers its authorized access.

Native requests retain all existing workspace membership/resource permissions.
An operator needs the current database admin role and a valid native session for
admin APIs; being an operator never implies customer-workspace membership.
Browser billing still requires `billing.view` / `billing.manage`; membership
inspection and workspace details retain their original permissions.

Public login/register/Google identity, desktop request/token/revoke, health and
public logos remain unchanged. New-user registration may still provision its
initial workspace as part of account creation. Existing users without any
workspace must create one from the desktop before workspace-scoped billing.
Signed Stripe/webhook routes and independently authenticated worker routes remain
outside this client gate; a browser credential is not a worker credential.

## Phoenix Channels

When enabled, browser credentials cannot establish a Phoenix socket, including
when placed into the native handshake header. Existing browser transports stop
before processing the next incoming frame or delivering the next outgoing data,
or within 15 seconds while idle after the flag changes in that process. Native
session revocation/expiry checks remain active, along with topic membership.
The account portal must not create the former business/notification sockets.

Already-joined workspace/task/agent topics are reauthorized against current
active memberships before incoming frames, outgoing data (including Phoenix
fastlane broadcasts), and idle checks. Removing a membership closes the transport
before its next data delivery; the user may reconnect to their remaining allowed
topics. Current account status is also rechecked for existing browser sockets,
not only native sessions. Identifier-only queries are batched by topic kind;
payloads are not decoded or logged for authorization. The transport-state adapter
and Phoenix framing are covered by regression tests when upgrading Phoenix.

## Promotion prerequisites and rollback

1. Deploy migration `20260913000001_create_desktop_sessions.exs`, the desktop auth
   endpoints and browser consent route with the gate **OFF**.
2. Verify complete browser sign-in/consent/native exchange, live `/me`, desktop
   HTTP/Channels, refresh/revocation, account switching and admin restrictions.
3. Publish and verify signed installable binaries, trusted download hosting and
   working update feeds. Confirm supported users can obtain the desktop app.
4. Validate the account-only web build (profile, security, billing, plans, usage,
   spending, invoices), its matching rollout flag and OAuth callback routing.
5. Only then explicitly promote both rollout settings. Deploy consistently
   across API replicas and drain old processes/WebSockets; runtime config is
   loaded per process, not globally distributed feature-flag storage.
6. Rollback sets both flags false and redeploys; existing credentials and schema
   remain compatible. This code makes no external deployment or flag change.

Native integration OAuth initiation/return remains a separate product gap: this
gate preserves existing callbacks, but does not invent a desktop handoff flow or
restore the former integrations management page in the account-only portal.

## Production authentication compatibility audit

The repository's production Terraform currently selects `auth_mode=dev_fallback`.
That mode verifies Phoenix-signed credentials with the Endpoint secret, a
dedicated salt and seven-day lifetime, then validates UUID/current account state.
It is not an unsigned or arbitrary-user fallback. Confirm strong Endpoint secret
management and access controls without exposing the secret. Browser sessions lack
per-session server revocation; the existing logout endpoint does not revoke them.

Do not switch `AUTH_MODE` to Cognito in isolation: current password and Google
controller flows still issue local Phoenix credentials, which Cognito mode would
reject. A compatible identity migration requires the new browser login flow,
issuer/client configuration, existing-account linking and explicit session
transition. Native PKCE authorization can continue to follow the selected browser
identity provider. No authentication-mode change is made by this client policy.

## Validation

`mix test test/mokaid_web/client_access_test.exs` covers rollout-off compatibility,
account/billing access, business reads/mutations, spoofed client headers, actual
native task creation, cross-workspace isolation, billing role checks, operator
restrictions and live role removal, revoked tokens, worker separation, consent,
OAuth callback validation, topic scope and already-open browser transports.
Run alongside `test/mokaid/desktop_auth_test.exs` and
`test/mokaid_web/desktop_auth_test.exs` on an isolated migrated PostgreSQL database.
`test/mokaid_web/channel_access_test.exs` additionally covers membership removal,
account disablement, mixed/unknown/foreign scopes, resource moves and preserved
heartbeat/notification framing. These regressions reproduced outgoing delivery
after revoked membership or account status before the transport fix.
