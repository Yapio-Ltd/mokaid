# Website and desktop boundary

The public website is the landing page, product information, pricing, downloads,
and authenticated account management. The website must not open the Office, even
when a visitor already has a session or follows a saved application URL.

- `/` stays public for signed-in and anonymous visitors.
- Sign-in defaults to `/account`; validated account, billing and desktop consent
  return URLs retain their destination.
- Account sections cover profile, security, plans, usage, spending, invoices and
  payment management through the existing billing endpoints.
- Legacy work routes redirect to `/download`; `/billing`, `/settings` and
  `/profile` retain compatible account destinations.
- The marketing header exposes download and sign-in/account immediately, including
  on mobile. The hero and final call to action lead to desktop downloads.

The previous `VITE_DESKTOP_ONLY_WEB` environment flag no longer controls the web
surface. Its disabled production value had kept publishing the web application.
The website now always builds in account-only mode and excludes the Office's
application shell and rendering modules. CI exercises that ordinary build.

`MOKAID_DESKTOP_ONLY` still controls server business-client restrictions and keeps
its signed-release readiness check. It cannot restore the web Office. Installer
publication is a separate release operation: `/download` only offers artifacts
from the verified stable manifest and reports missing or unavailable releases.

## Visual scope

This is a refinement of the existing dark/violet Mokaid landing, using its existing
wordmark, fonts, product imagery, page sections and design tokens. It brings the
website's two main actions into the first viewport, improves the explanatory
copy's size/contrast, and keeps the hero visible with reduced motion enabled.
No new visual identity or fabricated product/download claims are introduced.

## Regression checks

Route integration tests cover sessions, legacy links, safe payment returns and
an obsolete rollout flag explicitly set to false. Chromium covers signed-in and
anonymous landing visits at desktop/mobile sizes, navigation to downloads,
retired work routes, all account sections, invoice export and desktop consent.
Network interception verifies that the account/landing paths start no Office
renderer or WebSocket. Fixture billing data is never sent to production.
The production smoke check requires the `marketing-account` HTML marker and
landing download/sign-in links, and rejects a landing dashboard link.
