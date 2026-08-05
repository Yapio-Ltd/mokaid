/**
 * Post-build prerender for the public (SEO) routes of the mokaid SPA.
 *
 * The React app renders client-side, so the raw build serves an empty <body>
 * to crawlers — which is why the site was absent from Google's index. This
 * script serves the fresh build with `vite preview`, crawls the public routes
 * with Playwright (starting at "/" and following internal links), and saves
 * each fully rendered page as static HTML in dist/<route>/index.html.
 * It also generates dist/sitemap.xml.
 *
 * nginx then serves the snapshots to first hits (`try_files $uri
 * $uri/index.html /spa.html`) while the SPA takes over as soon as JS loads.
 *
 * Usage: node scripts/prerender.mjs  (run after `vite build`, from apps/web)
 */

import { spawn } from "node:child_process";
import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const DIST = join(ROOT, "dist");
const PORT = 4173;
const ORIGIN = `http://localhost:${PORT}`;
const SITE_URL = "https://mokaid.com";

/** Only routes under these exact paths / prefixes are crawled and snapshotted. */
const PUBLIC_PREFIXES = [
  "/pricing",
  "/ai-employees",
  "/use-cases",
  "/compare",
  "/blog",
  "/glossary",
  "/privacy",
  "/terms",
  "/cookies",
  "/legal",
  "/refund",
];

/** Kept out of sitemap.xml (still prerendered so crawlers get real HTML). */
const SITEMAP_EXCLUDE = new Set(["/privacy", "/terms", "/cookies", "/legal", "/refund"]);

function isPublicRoute(path) {
  if (path === "/") return true;
  return PUBLIC_PREFIXES.some((prefix) => path === prefix || path.startsWith(`${prefix}/`));
}

function normalize(path) {
  const noHash = path.split("#")[0].split("?")[0];
  if (noHash.length > 1 && noHash.endsWith("/")) return noHash.slice(0, -1);
  return noHash || "/";
}

/**
 * GSAP leaves reveal targets mid-animation (inline opacity/transform) in the
 * snapshot; Google devalues invisible content. The live SPA re-renders from
 * scratch on load, so stripping those inline properties from the static HTML
 * is safe and keeps every section visible to crawlers.
 */
function stripAnimationStyles(html) {
  return html.replace(/style="([^"]*)"/g, (full, css) => {
    const kept = css
      .split(";")
      .map((decl) => decl.trim())
      .filter(Boolean)
      .filter((decl) => {
        const prop = decl.split(":")[0].trim().toLowerCase();
        return !["opacity", "transform", "visibility", "translate", "scale", "rotate"].includes(
          prop,
        );
      });
    return kept.length > 0 ? `style="${kept.join("; ")}"` : "";
  });
}

function startPreviewServer() {
  return new Promise((resolve, reject) => {
    const child = spawn(
      "npx",
      ["vite", "preview", "--port", String(PORT), "--strictPort", "--host", "127.0.0.1"],
      { cwd: ROOT, stdio: ["ignore", "pipe", "pipe"] },
    );
    let settled = false;
    const onData = (chunk) => {
      if (!settled && chunk.toString().includes(String(PORT))) {
        settled = true;
        resolve(child);
      }
    };
    child.stdout.on("data", onData);
    child.stderr.on("data", onData);
    child.on("exit", (code) => {
      if (!settled) reject(new Error(`vite preview exited early (code ${code})`));
    });
    setTimeout(() => {
      if (!settled) reject(new Error("vite preview did not start within 30s"));
    }, 30_000).unref();
  });
}

async function renderRoute(page, route) {
  await page.goto(`${ORIGIN}${route}`, { waitUntil: "load", timeout: 60_000 });
  // Wait for React to mount real content (the raw shell has an empty #root).
  await page.waitForFunction(() => {
    const root = document.getElementById("root");
    return root !== null && root.childElementCount > 0;
  });
  // Let lazy chunks, fonts and the SEO head tags settle.
  await page.waitForTimeout(2_000);

  // Scroll through the page so IntersectionObserver-lazy sections (office tour,
  // agent tour, connectors on the landing) mount and end up in the snapshot.
  await page.evaluate(async () => {
    const step = window.innerHeight;
    for (let y = 0; y < document.body.scrollHeight; y += step) {
      window.scrollTo(0, y);
      await new Promise((r) => setTimeout(r, 150));
    }
    window.scrollTo(0, 0);
  });
  await page.waitForTimeout(1_500);

  const links = await page.$$eval("a[href]", (anchors) =>
    anchors
      .map((a) => a.getAttribute("href") ?? "")
      .filter((href) => href.startsWith("/") && !href.startsWith("//")),
  );
  const html = await page.content();
  return { html: stripAnimationStyles(html), links };
}

async function saveSnapshot(route, html) {
  const target =
    route === "/" ? join(DIST, "index.html") : join(DIST, route.slice(1), "index.html");
  await mkdir(dirname(target), { recursive: true });
  await writeFile(target, `<!doctype html>\n${html.replace(/^<!doctype html>/i, "").trim()}\n`);
}

function buildSitemap(routes) {
  const today = new Date().toISOString().slice(0, 10);
  const urls = routes
    .filter((route) => !SITEMAP_EXCLUDE.has(route))
    .sort()
    .map((route) => {
      const loc = route === "/" ? `${SITE_URL}/` : `${SITE_URL}${route}`;
      const priority = route === "/" ? "1.0" : route.split("/").length > 2 ? "0.7" : "0.8";
      return `  <url>\n    <loc>${loc}</loc>\n    <lastmod>${today}</lastmod>\n    <priority>${priority}</priority>\n  </url>`;
    })
    .join("\n");
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`;
}

async function main() {
  // Preserve the untouched SPA shell: nginx uses it as the fallback for app
  // routes (/dashboard, /login…) so they don't flash the landing snapshot.
  await cp(join(DIST, "index.html"), join(DIST, "spa.html"));

  const server = await startPreviewServer();
  const browser = await chromium.launch();

  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    page.on("pageerror", (err) => console.warn(`  page error: ${err.message}`));

    const queue = ["/"];
    const seen = new Set(queue);
    const rendered = [];

    while (queue.length > 0) {
      const route = queue.shift();
      process.stdout.write(`prerender ${route} ... `);
      try {
        const { html, links } = await renderRoute(page, route);
        await saveSnapshot(route, html);
        rendered.push(route);
        console.log("ok");
        for (const link of links) {
          const next = normalize(link);
          if (!seen.has(next) && isPublicRoute(next)) {
            seen.add(next);
            queue.push(next);
          }
        }
      } catch (err) {
        console.log(`FAILED (${err.message})`);
        process.exitCode = 1;
      }
    }

    await writeFile(join(DIST, "sitemap.xml"), buildSitemap(rendered));
    console.log(`\n${rendered.length} routes prerendered, sitemap.xml written.`);

    const landing = await readFile(join(DIST, "index.html"), "utf8");
    if (!landing.includes('rel="canonical"')) {
      console.warn("WARNING: landing snapshot is missing the canonical tag.");
      process.exitCode = 1;
    }
  } finally {
    await browser.close();
    server.kill("SIGTERM");
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
