# Shared header verification — 2026-09-26

**Current result: PASS.** The final compiled preview passed no-JavaScript and immediate-Escape checks after the two confirmed issues were fixed. Automated browser coverage used Chromium 151.0.7922.34. This is not a claim of a new full cross-browser or physical-device audit.

## Coverage

- Nine public routes: Home, Pricing, Download, AI Employees, Privacy, Terms, Cookies, Legal and Refund. One shared header per route, correct link destinations, centered desktop navigation and matching desktop geometry. Logo x=120, navigation center x=720, Download right edge=1320 and header height=65 at 1440px.
- Route flow: Home → Pricing → Download → Back → Experience anchor → Back → Sign in → Back.
- Twelve mobile combinations: Home/Pricing/Download/Privacy at 320, 390 and 767px. No horizontal overflow; native menu, Escape with focus restoration, Enter to open, and navigation closing all pass. At 768px, desktop navigation returns and the menu closes.
- Synthetic local auth: My account on desktop/mobile, isolated `/api/me` fixture, account route and Back. No real login, credentials, API writes or downloads.
- Actual production MP4: cinematic readiness, keyboard Experience link lands at 72px, reverse scroll to frame 0, and history Back to Home.
- Final compiled build: nine explicit prerender snapshots and all twelve mobile combinations pass without JavaScript; immediate Escape closes the menu and restores focus on Home, Download and Privacy.

Current machine-readable reports: `interactive-chromium-mobile.json`, `nojs-chromium.json`, `compiled-escape.json`. Desktop geometry and the signed-out route flow passed within the earlier `interactive-chromium.json` run before its later Privacy overflow assertion stopped that run. Screenshots named `interactive-*` and `nojs-*` cover desktop and mobile menus, including the authenticated fixture.

Root-run checks also passed: final TypeScript and scoped ESLint; full ESLint had 0 errors and 14 existing warnings; 55 focused Vitest tests; 5 prerender-policy tests; final production build and 36 prerendered routes.

## Confirmed fixes

1. A long PPA URL in the Privacy body extended the 320px document to 477px. The header itself stayed inside the viewport. Root added `overflow-wrap:anywhere` to the legal content container. Both interactive and final no-JavaScript checks now pass at 320px and 390px.
2. Escape could arrive after the native disclosure opened but before React's `toggle` effect attached its listener. Root made the listener permanent and checked the native `details.open` state. The final compiled check deliberately sends Escape immediately after opening.

## Superseded debugging evidence and setup

`interactive-chromium.json`, all `*-failure.png` files, and `overflow-privacy-320.json` retain earlier failure evidence. They are superseded by the current passing mobile/no-JavaScript/compiled reports; do not interpret them as unresolved current failures. Earlier setup failures included an approval-review timeout before launch, an overbroad API stub matching Vite's `/src/api/client.ts`, measurements before remote font stylesheets loaded, and a locator matching both desktop and hidden mobile links. The harness now distinguishes these correctly. A reverse-scroll check also originally ran before Lenis completed the anchor easing; it now waits for the actual scrolling state to settle.

Vite preview serves its SPA fallback for extensionless paths such as `/pricing`; the no-JavaScript check therefore visits the actual `/pricing/index.html` snapshot. This validates the prerendered header, not Vite fallback routing. Root confirmed production Nginx already resolves `$uri/index.html`. No product routing change was made. Print-only font links also cannot activate their `onload` handler without JavaScript, so no-JavaScript inspection waits for native page load rather than that handler.

## Reproduce

From the repository root, with the appropriate local server running:

```sh
node artifacts/header-unification-2026-09-26/browser-check.mjs http://127.0.0.1:5181 chromium
node artifacts/header-unification-2026-09-26/browser-check.mjs http://127.0.0.1:4173 chromium --nojs
node artifacts/header-unification-2026-09-26/compiled-escape.mjs http://127.0.0.1:4173
```

Tests use isolated contexts. Header-only cases abort the film and stub the release manifest as unavailable; the actual-media navigation case loads the real film explicitly.
