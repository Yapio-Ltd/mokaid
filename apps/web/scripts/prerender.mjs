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
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";
import { PUBLIC_ROOTS, publicRoute, buildSitemap, assertSnapshot, privateShell } from "./prerender-policy.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const DIST = join(ROOT, "dist");
const PORT = 4173;
const ORIGIN = `http://127.0.0.1:${PORT}`;
const require = createRequire(import.meta.url);
const VITE_CLI = join(dirname(require.resolve("vite/package.json")), "bin", "vite.js");

/** Only routes under these exact paths / prefixes are crawled and snapshotted. */
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
      // Spawn Vite directly: terminating npx leaves its server grandchild and
      // inherited output pipes alive on Linux, hanging the production image.
      process.execPath,
      [VITE_CLI, "preview", "--port", String(PORT), "--strictPort", "--host", "127.0.0.1"],
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
    child.on("error", reject);
    setTimeout(() => {
      if (!settled) {
        child.kill("SIGTERM");
        reject(new Error("vite preview did not start within 30s"));
      }
    }, 30_000).unref();
  });
}

async function stopPreviewServer(server) {
  if (server.exitCode !== null || server.signalCode !== null) return;
  await new Promise((resolve) => {
    const deadline = setTimeout(() => server.kill("SIGKILL"), 5_000);
    server.once("close", () => { clearTimeout(deadline); resolve(); });
    server.kill("SIGTERM");
  });
}

async function renderRoute(page, route) {
  const response = await page.goto(`${ORIGIN}${route}`, { waitUntil: "load", timeout: 60_000 });
  if (response?.status() !== 200) throw new Error(`Unexpected HTTP status ${response?.status()}`);
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
  const snapshot = stripAnimationStyles(html);
  assertSnapshot(route, snapshot);
  return { html: snapshot, links };
}

async function saveSnapshot(route, html) {
  const target =
    route === "/" ? join(DIST, "index.html") : join(DIST, route.slice(1), "index.html");
  await mkdir(dirname(target), { recursive: true });
  await writeFile(target, `<!doctype html>\n${html.replace(/^<!doctype html>/i, "").trim()}\n`);
}

async function main() {
  // Preserve the untouched SPA shell: nginx uses it as the fallback for app
  // routes (/dashboard, /login…) so they don't flash the landing snapshot.
  await writeFile(join(DIST, "spa.html"), privateShell(await readFile(join(DIST, "index.html"), "utf8")));

  const server = await startPreviewServer();
  let browser;

  try {
    browser = await chromium.launch();
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    page.on("pageerror", (err) => console.warn(`  page error: ${err.message}`));

    const queue = ["/", ...PUBLIC_ROOTS];
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
          const next = publicRoute(link);
          if (next && !seen.has(next)) {
            seen.add(next);
            queue.push(next);
          }
        }
      } catch (err) {
        console.log(`FAILED (${err.message})`);
        process.exitCode = 1;
      }
    }

    if (process.exitCode) throw new Error("Incomplete SEO build; refusing to publish sitemap");
    await writeFile(join(DIST, "sitemap.xml"), buildSitemap(rendered));
    console.log(`\n${rendered.length} routes prerendered, sitemap.xml written.`);

    const landing = await readFile(join(DIST, "index.html"), "utf8");
    if (!landing.includes('rel="canonical"')) {
      console.warn("WARNING: landing snapshot is missing the canonical tag.");
      process.exitCode = 1;
    }
  } finally {
    try { await browser?.close(); }
    finally { await stopPreviewServer(server); }
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
