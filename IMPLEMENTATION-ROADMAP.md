# SEO Implementation Roadmap — mokaid.com

Four phases over 12 months. Phase 1 engineering is **done in this repo**; the remaining Phase 1
items are owner actions (DNS, accounts).

## Phase 1 — Foundation (weeks 1–4) ✅ code shipped

**Done in repo (integrated into the existing React site, `apps/web`):**
- [x] Post-build prerender of all public routes to static HTML (Playwright crawler,
      `apps/web/scripts/prerender.mjs`) — crawlers now see full content instead of an empty body
- [x] Landing keeps its existing design; per-page metadata via `useSeo` hook
      (title, description, canonical, OG/Twitter, JSON-LD)
- [x] Pillar /ai-employees + 8 role pages, 5 use cases, 4 comparisons, glossary (14 terms),
      styled with the existing design system (`apps/web/src/pages/seo/`)
- [x] 6 launch blog posts (markdown in `apps/web/src/content/blog/`)
- [x] robots.txt (permissive + AI crawlers), sitemap.xml (generated at build), canonicals,
      llms.txt, OG image 1200x630
- [x] JSON-LD: Organization, WebSite, SoftwareApplication, FAQPage, BreadcrumbList,
      DefinedTermSet, BlogPosting
- [x] nginx: prerendered HTML served statically, www→apex 301, static robots/sitemap/llms,
      SPA fallback for app routes

**Owner actions (blocking go-live):**
- [ ] Deploy the updated web image (`infra/docker/web.Dockerfile` runs the prerender;
      with `web.runtime.Dockerfile` build locally via `npm run build:seo -w @mokaid/web`)
- [ ] Verify GSC Domain property (DNS TXT), submit sitemap, request indexing on 6 key pages
- [ ] Create GA4 property + add snippet; Bing Webmaster import; Google Cloud API key
      (full checklist: `docs/SEO-SETUP.md`)

**Exit criteria:** `site:mokaid.com` shows pages within 2–4 weeks of submission; GSC reports
25+ valid pages.

## Phase 2 — Expansion (weeks 5–12)

- [ ] 2 posts/month per `CONTENT-CALENDAR.md` (Q3 items)
- [ ] Directory submissions: Product Hunt, G2, Capterra, AlternativeTo, There's An AI For That
- [ ] Launch PR push on the "visible AI workforce" angle (newsletters, podcasts)
- [ ] Add real product screenshots/video of the 3D office to the landing and content pages
      (replace placeholders as the product UI evolves)
- [ ] Weekly GSC review: fix crawl anomalies, track Tier 1 positions

**Exit criteria:** first non-brand organic clicks; ≥3 Tier 1 keywords in top 10; ≥15 referring
domains.

## Phase 3 — Scale (weeks 13–24)

- [ ] Q4 content (roundup post, governance series, AI SDR guide)
- [ ] Comparison-page outreach ("X alternatives" roundups)
- [ ] Expand roles/use cases based on GSC query data (data-driven programmatic growth)
- [ ] First customer case study if available
- [ ] CWV field-data check once CrUX has data; performance budget: LCP < 2.0s mobile
- [ ] Monthly GEO checks: is mokaid cited by ChatGPT/Perplexity for category queries?

**Exit criteria:** 1,500+ organic clicks/month; Tier 1 terms dominated; 2+ Tier 2 terms top 20.

## Phase 4 — Authority (months 7–12)

- [ ] Thought-leadership series + founder distribution (LinkedIn/X)
- [ ] Digital-labor history piece + glossary expansion → become the citation source for the
      category (GEO flywheel)
- [ ] Guest posts / podcast circuit on future-of-work
- [ ] Quarterly technical audit (re-run external audit; keep zero soft-404s, valid schema)
- [ ] Evaluate international SEO (fr, de) only after English positions are established

**Exit criteria (12 months):** 8,000+ organic clicks/month; all Tier 1 keywords #1–3;
100+ referring domains; consistent AI-assistant citations for "AI employee" category queries.

## Dependencies & risks

| Dependency | Impact if delayed |
|---|---|
| DNS + deploy split (owner) | Nothing indexes; all other work idle |
| GSC verification (owner) | No indexing control or measurement |
| Product screenshots/video | /product persuasion weaker; rankings unaffected |
| First customers for case studies | Phase 4 E-E-A-T ceiling |

Review this roadmap monthly against `docs/SEO-SETUP.md` metrics.
