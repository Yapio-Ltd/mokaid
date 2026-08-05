# SEO Strategy — mokaid.com

**Goal:** own the new category "AI employees in a visible 3D virtual office" (position 1 on
differentiated queries) while capturing qualified traffic from the crowded "AI employees /
digital workers" category through content.

## Starting point (August 2026 audit)

- mokaid.com was a client-side React SPA with an empty pre-JS `<body>` → **absent from the
  Google index entirely** (`site:mokaid.com` = 0 results).
- No robots.txt, sitemap, canonical, structured data, or content pages; `www` unredirected;
  soft-404s everywhere; no GSC/GA4.
- Fix shipped: the public routes of the React site are prerendered to static HTML at build
  (Playwright crawler), per-page metadata via a `useSeo` hook, SEO content pages added in
  `apps/web`, nginx corrected. One site, one domain. See `docs/SEO-SETUP.md`.

## Positioning: two-tier keyword strategy

### Tier 1 — Differentiated terms to dominate (low competition, category-defining)

No competitor owns these. Every page reinforces them; the homepage and the pillar target
them directly.

| Keyword | Primary page |
|---|---|
| ai employees in a virtual office | Homepage |
| 3d virtual office with ai agents | Homepage |
| watch ai agents work / ai employees you can see | Homepage, /ai-employees |
| visual ai workforce | Blog: the visual AI workforce |
| ai workforce os | Homepage, /glossary, blog |
| virtual office ai simulation | Homepage |

### Tier 2 — Category terms to capture via content (high volume, high competition)

Competitors (Lindy, Artisan, 11x, Sintra, Sistava) fight here. We compete with better-structured,
more citable content plus the differentiation angle.

| Keyword | Primary page |
|---|---|
| ai employees / what is an ai employee | /ai-employees (pillar) |
| hire ai employees | /ai-employees + blog how-to |
| digital workers / digital employees | /glossary + blog |
| ai employee vs ai agent | blog + /ai-employees section |
| ai workforce platform | homepage + blog |
| managing ai employees | blog |

### Tier 3 — Long-tail role and audience terms (programmatic)

- Roles: `ai sdr`, `ai marketing employee`, `ai developer agent`, `ai support agent`,
  `ai executive assistant`, `ai data analyst`, `ai content writer`, `ai recruiter`
  → `/ai-employees/<role>` (8 pages)
- Audiences: `ai employees for startups / agencies / ecommerce / saas / solo founders`
  → `/use-cases/<audience>` (5 pages)
- Brand-adjacent: `mokaid vs lindy|artisan|11x|sintra` and reverse-intent
  `lindy alternatives`, `artisan alternatives` → `/compare/<slug>` (4 pages)

## E-E-A-T approach

- First-hand product perspective in every piece ("in mokaid, …") — experience signal.
- Honest comparisons that state when a competitor is the better choice — trust signal.
- Precise, quotable definitions (pillar, glossary, key-takeaway blocks) — expertise signal.
- Organization + SoftwareApplication schema, consistent author entity ("The mokaid Team"),
  a disclaimer on comparison pages, no invented statistics.

## GEO (Generative Engine Optimization)

AI answers (ChatGPT, Perplexity, AI Overviews) are the second battlefield — arguably the first
for a category that does not exist yet, since users ask assistants "what is an AI employee
platform where you can see the agents?".

- `llms.txt` at the root summarizing the product and linking every money page.
- robots.txt explicitly allows GPTBot, OAI-SearchBot, PerplexityBot, ClaudeBot, Google-Extended.
- Every important concept has a one-paragraph, standalone, citable definition
  (pillar page definition card, glossary `DefinedTermSet` schema, blog `keyTakeaway` blocks).
- FAQPage schema on the homepage, product, roles, use cases, and comparisons.

## Technical standards (enforced in `apps/web`)

- Static prerendered HTML for every public page (post-build Playwright snapshot) — full
  content visible without JavaScript; the SPA hydrates on top for users.
- Canonical on every page; one host (apex), one protocol (https).
- `sitemap.xml` generated at build by the prerender script; legal pages excluded.
- JSON-LD: Organization, WebSite, SoftwareApplication, BreadcrumbList, FAQPage,
  DefinedTermSet (glossary), BlogPosting (blog).
- OG image 1200x630 (`/branding/og-image-wide.jpg`), `summary_large_image` Twitter cards.
- Fonts non-blocking; hashed assets cached immutable; prerendered HTML no-cache.
- Internal linking: header, footer (all sections), breadcrumbs, related-content blocks,
  and in-copy contextual links. Every page reachable within 2 clicks from home.

## Link building (requires human action)

1. Directories and launch platforms: Product Hunt, G2, Capterra, There's An AI For That,
   AlternativeTo, Futurepedia.
2. Comparison-page magnets: being fair to competitors makes these linkable; pitch them to
   "X alternatives" roundup authors.
3. Category-creation PR: the "visible AI workforce" angle is novel — pitch AI/future-of-work
   newsletters and podcasts.
4. Founder content on LinkedIn/X pointing at the pillar and blog posts.

## KPI targets

| Metric | Baseline (Aug 2026) | 3 months | 6 months | 12 months |
|---|---|---|---|---|
| Indexed pages | 0 | 25+ | 35+ | 60+ |
| Organic clicks / month | 0 | 200 | 1,500 | 8,000 |
| Tier 1 keywords in top 3 | 0 | 3 | 6 | all |
| Tier 2 keywords in top 20 | 0 | 2 | 5 | 10 |
| Referring domains | ~0 | 15 | 40 | 100 |
| AI-assistant citations (monthly spot-check) | 0 | first citations | consistent for brand queries | cited for category queries |

## Risks and mitigations

- **New domain, zero authority:** expect 2-3 months before meaningful rankings. Mitigate with
  Tier 1 (uncontested) terms, directories, and PR for early links.
- **Category confusion:** "AI employee" definitions vary. Mitigate by publishing the clearest
  definitions and pushing them for citations (GEO).
- **Content staleness on comparisons:** competitors change quickly; review /compare quarterly
  (disclaimer already on-page).
