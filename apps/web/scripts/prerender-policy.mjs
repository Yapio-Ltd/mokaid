import { JSDOM } from "jsdom";

export const SITE_URL = "https://mokaid.com";
export const PUBLIC_ROOTS = ["/pricing", "/download", "/ai-employees", "/use-cases", "/compare", "/blog", "/glossary", "/privacy", "/terms", "/cookies", "/legal", "/refund"];
const DETAIL_ROOTS = ["/ai-employees", "/use-cases", "/compare", "/blog"];
const LEGAL = new Set(["/privacy", "/terms", "/cookies", "/legal", "/refund"]);

/** Accept only marketing paths; never crawl auth, API or account data. */
export function publicRoute(href) {
  if (!href.startsWith("/") || href.startsWith("//") || href.includes("\\")) return null;
  const path = href.split(/[?#]/, 1)[0].replace(/\/$/, "") || "/";
  if (path === "/" || PUBLIC_ROOTS.includes(path)) return path;
  return DETAIL_ROOTS.some((root) => new RegExp(`^${root}/[a-z0-9]+(?:-[a-z0-9]+)*$`).test(path)) ? path : null;
}

export function buildSitemap(routes) {
  // Deployment date is not content-modified date. Omit misleading lastmod.
  const entries = [...new Set(routes)].filter((route) => publicRoute(route) === route && !LEGAL.has(route)).sort();
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${entries.map((route) => `  <url><loc>${SITE_URL}${route}</loc></url>`).join("\n")}\n</urlset>\n`;
}

export function assertSnapshot(route, html) {
  const dom = new JSDOM(html);
  try {
    const document = dom.window.document;
    if (document.querySelectorAll('link[rel="canonical"]').length !== 1 || document.querySelector('link[rel="canonical"]')?.getAttribute("href") !== `${SITE_URL}${route}`) throw new Error(`${route}: missing/conflicting canonical`);
    if ((document.querySelector("title")?.textContent?.trim().length ?? 0) < 10) throw new Error(`${route}: missing title`);
    if ((document.querySelector('meta[name="description"]')?.getAttribute("content")?.length ?? 0) < 40) throw new Error(`${route}: missing description`);
    if (/noindex/i.test(document.querySelector('meta[name="robots"]')?.getAttribute("content") ?? "")) throw new Error(`${route}: public page is noindex`);
    if (!document.querySelector("h1")?.textContent?.trim() || (document.querySelector("#root")?.textContent?.trim().length ?? 0) < 100) throw new Error(`${route}: empty/loading snapshot`);
    for (const script of document.querySelectorAll('script[type="application/ld+json"]')) JSON.parse(script.textContent);
    if (html.length > 2_000_000) throw new Error(`${route}: snapshot exceeds HTML budget`);
  } finally { dom.window.close(); }
}

export function privateShell(html) {
  const dom = new JSDOM(html);
  try {
    const document = dom.window.document;
    document.querySelectorAll('link[rel="canonical"], script[data-seo-jsonld], meta[name="robots"], meta[property^="og:"], meta[name^="twitter:"]').forEach((node) => node.remove());
    document.title = "Mokaid Account";
    document.querySelector('meta[name="description"]')?.setAttribute("content", "Sign in to manage your Mokaid account, plan, usage and invoices.");
    const robots = document.createElement("meta");
    robots.name = "robots";
    robots.content = "noindex, nofollow";
    document.head.append(robots);
    return dom.serialize();
  } finally { dom.window.close(); }
}
