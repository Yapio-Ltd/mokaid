# Real, isolated desktop login validation

This launcher runs the real Phoenix application and auth/channel endpoints, not
an API mock. It is not a production launcher. It requires an already migrated
PostgreSQL test database; it never runs generic seeds or starts an AI worker.

Fixed boundaries:

- PostgreSQL: numeric `127.0.0.1:55437`, user `mokaid`, database name ending `_test`.
- API: `http://127.0.0.1:4002`.
- Vite/browser consent: `http://127.0.0.1:5178`.
- `MIX_ENV=test`, explicit `DATABASE_URL`, `mix run --no-start`.

The launcher rejects invalid boundaries before connecting, then verifies the
actual PostgreSQL peer and database before fixture writes. It uses SQL Sandbox
in `:auto` mode for real concurrent HTTP/WebSocket processes. Oban is manual with
no queues/plugins. Provider credentials are removed; Req and ExAws HTTP adapters
refuse outbound requests. IMAP probing, catalog seeding and telemetry export are
disabled. These are application guards, not a general OS network sandbox.

## Launch

Use a clean environment without sourcing `.env` or retaining cloud credentials.
The temporary cluster used during desktop development is
`/private/tmp/mokaid-desktop-auth-pg.VWqQxW` (this directory is PGDATA itself).
First verify the ports are unused and the directory contains PostgreSQL 17.

```sh
/opt/homebrew/bin/pg_ctl -D /private/tmp/mokaid-desktop-auth-pg.VWqQxW -o '-h 127.0.0.1 -p 55437' -l /private/tmp/mokaid-desktop-auth-pg.VWqQxW/desktop-validation.log start
```

From `apps/api`, with a clean inherited environment:

```sh
MIX_ENV=test DATABASE_URL=ecto://mokaid@127.0.0.1:55437/mokaid_desktop_auth_test DESKTOP_AUTH_WEB_BASE_URL=http://127.0.0.1:5178 mix run --no-start ../desktop/tests/local_backend.exs
```

Append `--check` to validate configuration without connecting or writing fixtures.
The process prints its PID and `LOCAL_BACKEND_READY`, but never session tokens.
From `apps/web`:

```sh
VITE_API_URL='' VITE_WS_URL=/socket VITE_DEV_PROXY_TARGET=http://127.0.0.1:4002 VITE_DISABLE_3D=true node ../../node_modules/vite/bin/vite.js --host 127.0.0.1 --port 5178 --strictPort
```

An empty `VITE_API_URL` is essential: otherwise the web default bypasses the proxy
and uses port 4000. Set these process variables explicitly to override local Vite
env files. Vite's dev proxy removes Origin before the backend hop; the endpoint
also allows the isolated browser origin explicitly.

## Public synthetic fixture

- Email: `desktop.validation@example.invalid`
- Password: `Desktop-Fixture-Only-2026!`
- Workspace/name: `Desktop Local Validation (SYNTHETIC)`

These are intentionally public fixture credentials, never production secrets.
The password is stored by the normal bcrypt registration path. Existing matching
fixtures are reused; conflicting identities are rejected, never overwritten.
The workspace is created with `bootstrap: false`, so it starts empty and does not
create subscriptions, jobs or agents. No administrator role is assigned.

Compile a separate native development build with API origin port 4002 and trusted
web origin port 5178. Use the native **Sign in** button, sign into the browser with
the fixture, return to the consent tab and explicitly approve. Verify `/api/me`,
workspace selection and both workspace/notification channel joins. Do not test
uploads, external OAuth, payments or AI execution in this environment.

## Recorded local validation — 2026-09-14

The native development app completed a real browser PKCE sign-in and consent flow
against this isolated Phoenix instance, returned to the synthetic workspace and
created the task `Desktop E2E synthetic validation` through keyboard entry in the
native task form. Its creation was confirmed in both the UI and the local database.
The task creation used the real backend, with no AI provider or worker execution.

That UI run found an accessibility defect: setting the title through the native
accessibility value interface changed its visible text, but submission still
reported `Title is required`. Keyboard entry succeeded. `ActionDialog.qml` only
copied single-line `textEdited` signals into its payload; multiline changes also
required focus. Accessibility property changes do not require either condition.

The dialog now observes text changes regardless of input source and compares them
with the current model representation before writing back. This preserves typed
JSON prefill and absent optional fields, avoids a binding feedback loop and keeps
model-to-editor updates intact. A test loading the actual QML dialog reproduced
the stale payload before the fix and passed afterward, covering unfocused text
changes, their submitted payload, real keyboard events, model refresh, idempotent
updates and reopening with different initial values.

Validation on Qt 6.11.2: 20 feature-contract QtTest entries and 4 QML QtTest entries
(including setup/cleanup) passed in both normal and UBSan builds. Loopback fixture
tests require permission to bind local sockets; the action-form regression itself
does not use a network endpoint. This is a targeted regression check, not a claim
of complete product parity or production readiness. The corrected native app
was then rebuilt and checked through a fresh native accessibility interaction.

After that rebuild, the app automatically restored the existing local desktop
session and showed the synthetic workspace as **Connected**. The task
`Desktop AX regression validation` was created using only native accessibility
`setValue` calls for its title and description, without keyboard-entry fallback.
Both the UI and PostgreSQL confirmed the persisted task. This completed the
previously pending post-rebuild accessibility regression check.

Native **Sign out**, followed by its confirmation, returned the app to the
**Sign in** screen. The fixture's `desktop_sessions` rows then showed **0 active
and 1 revoked** session, confirming local server-side revocation as well as the UI
transition.

All of these checks used only the isolated local fixture and real local Phoenix
backend. No external product/API, production service, AI provider or worker was
used. They do not establish a live AI conversation/task-execution journey, full
client/admin parity, or production readiness.

## Checks and shutdown

`GET /api/health` should return the real Phoenix health response through both API
and Vite. `GET /api/me` without credentials must return 401. Do not print login or
token-exchange response bodies. Keep process/session IDs for the two foreground
servers and stop only those exact processes after the UI run.

Then stop the validated temporary cluster, preserving its files for inspection:

```sh
/opt/homebrew/bin/pg_ctl -D /private/tmp/mokaid-desktop-auth-pg.VWqQxW stop -m fast
```

No automatic destructive cleanup is performed. Synthetic fixture rows persist
only in the named temporary test database.
