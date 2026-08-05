# SEO Measurement & Indexing Setup — mokaid.com

This is the operational checklist to get mokaid.com indexed and measurable. It incorporates the
findings of the August 2026 external audit: **mokaid.com was absent from the Google index**
(`site:mokaid.com` returned nothing) because the SPA served an empty `<body>` to crawlers,
`robots.txt`/`sitemap.xml` were swallowed by the SPA fallback, and `www` was not redirected.

The technical side is now fixed **inside the existing React site** (`apps/web`): public routes
are prerendered to static HTML post-build, and `infra/docker/nginx.conf` serves them with the
correct redirects and content types. The steps below require account-level actions only the
site owner can do.

## 1. Deploy the updated site (prerequisite)

1. Build with prerender: `npm run build:seo -w @mokaid/web` → `apps/web/dist`
   (requires Playwright Chromium locally: `npx playwright install chromium`).
   The Docker image (`infra/docker/web.Dockerfile`) does this automatically.
   If you use `web.runtime.Dockerfile` (prebuilt dist), always build with `build:seo`,
   not plain `build`.
2. Deploy as usual — same domain, same container, no DNS change needed.
3. Verify from outside:
   - `curl -s https://mokaid.com/ | grep '<h1'` returns real landing content (not an empty root)
   - `curl -s https://mokaid.com/robots.txt` returns the text file (not HTML)
   - `curl -s https://mokaid.com/sitemap.xml` returns XML listing ~30 URLs
   - `curl -so /dev/null -w "%{http_code}" https://www.mokaid.com/` returns `301`
   - `curl -s https://mokaid.com/ai-employees | grep canonical` shows the canonical tag

## 2. Google Search Console (critical — do first)

1. Go to [search.google.com/search-console](https://search.google.com/search-console).
2. Add a **Domain property** for `mokaid.com` (covers apex + subdomains + http/https).
3. Verify via the DNS TXT record Google provides (add it at your DNS host).
4. Submit the sitemap: `https://mokaid.com/sitemap.xml`.
5. Use **URL Inspection → Request indexing** for the priority pages:
   `/`, `/ai-employees`, `/use-cases`, `/compare`, `/blog`, `/glossary`.
6. Watch **Pages** (indexation) and **Core Web Vitals** reports weekly.

## 3. Google Analytics 4

1. Create a GA4 property for mokaid.com at [analytics.google.com](https://analytics.google.com).
2. Add the gtag snippet or GTM container to `apps/web/index.html`
   (keep it `async`; load after consent — the app already ships a cookie banner, and
   non-essential analytics require consent per the privacy policy).
3. Link GA4 ↔ Search Console (GA4 Admin → Product links).

## 4. Bing Webmaster Tools (also powers ChatGPT search & Copilot)

1. Go to [bing.com/webmasters](https://www.bing.com/webmasters) and add `mokaid.com`.
2. Easiest path: **Import from Google Search Console** after step 2.
3. Submit the same sitemap URL.

## 5. Google Cloud API key (for automated audits: PageSpeed / CrUX)

The audit could not fetch lab or field performance data because no API key exists.

1. In [Google Cloud Console](https://console.cloud.google.com), create (or reuse) a project.
2. Enable **PageSpeed Insights API** and **Chrome UX Report API**.
3. Create an API key, restrict it to those two APIs.
4. Store it as `GOOGLE_PSI_API_KEY` in your local env / CI secrets (never commit it).

Note: CrUX will have no field data until the site accumulates real Chrome traffic over a 28-day
window. Use PageSpeed Insights (lab) until then.

## 6. Rank tracking for the differentiated keywords

Track weekly (GSC Performance report, or any rank tracker) the target queries defined in
`SEO-STRATEGY.md`, at minimum:

- `ai employees in a virtual office`
- `3d virtual office ai agents`
- `ai workforce os`
- `visual ai workforce`
- `hire ai employees`
- `ai employee vs ai agent`

## 7. GEO / AI-search visibility checks (monthly)

- Ask ChatGPT, Perplexity, and Gemini: "What is mokaid?" and "best AI employee platforms" —
  record whether mokaid is cited and from which page.
- `https://mokaid.com/llms.txt` is served for AI crawlers; keep it in sync when pages are added.
- robots.txt explicitly allows GPTBot, OAI-SearchBot, PerplexityBot, ClaudeBot, Google-Extended.
