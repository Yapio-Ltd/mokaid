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
- The marketing header exposes downloads immediately and sign-in/account through
  the menu on small phones. The hero and final call to action lead to desktop downloads.

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

The landing, public articles, pricing, downloads, and legal documents share one
sticky header and one responsive footer. Product and connector anchors render
immediately and clear the header. Route changes return to the new page heading;
Back restores the previous scroll position. Clicking the current page link from
the header or footer returns to the top.

Hero copy, wordmark, and actions stay in normal document flow, including at short
desktop heights. The office illustration has keyboard-accessible view tabs and
all employee examples remain available without scroll-driven animation. Reduced
motion keeps the first rotating phrase visible. Legal tables scroll within their
own labelled region instead of widening the mobile page. Long URLs wrap, and
secondary public/account text uses the readable secondary foreground token. Unknown URLs have a
useful noindex error page.

## Regression checks

Route integration tests cover sessions, legacy links, safe payment returns and
an obsolete rollout flag explicitly set to false. Chromium covers signed-in and
anonymous landing visits at desktop/mobile sizes, navigation to downloads,
retired work routes, all account sections, invoice export and desktop consent.
Network interception verifies that the account/landing paths start no Office
renderer or WebSocket. Fixture billing data is never sent to production.
The production smoke check requires the `marketing-account` HTML marker and
landing download/sign-in links, and rejects a landing dashboard link.

The public Chromium suite independently enumerates every authored public route,
crawls internal links, checks image loads and page errors, and tests the shared
header, footer, keyboard menus, anchors, pricing cycle, office preview tabs, FAQ,
and missing-page recovery. Its viewport matrix includes 1512×750, 1440×900,
1024×768, 768×1024, 390×844 and 320×640 with normal and reduced motion samples.
Account tests cover billing recovery, missing checkout destinations, and changing
the current subscription between monthly and yearly billing.
