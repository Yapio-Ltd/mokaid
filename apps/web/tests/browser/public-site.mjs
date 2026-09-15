/** Public website acceptance against an isolated compiled preview.
 * Build the account-only website and start Vite preview before running:
 * PLAYWRIGHT_BROWSERS_PATH=/private/tmp/mokaid-landing-browsers \
 *   node tests/browser/public-site.mjs http://127.0.0.1:5189 /private/tmp/mokaid-public-browser-results
 * No requests are sent to production or to external services. The desktop
 * release is intentionally unavailable; manifest/download states have separate tests.
 */
import assert from "node:assert/strict";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium, expect } from "@playwright/test";
import { PUBLIC_ROOTS, SITE_URL, publicRoute } from "../../scripts/prerender-policy.mjs";

const origin = new URL(process.argv[2] ?? "http://127.0.0.1:5189");
assert.equal(origin.hostname, "127.0.0.1", "Only an isolated loopback preview is allowed");
assert.equal(origin.protocol, "http:");
const artifacts = resolve(process.argv[3] ?? "/private/tmp/mokaid-public-browser-results");
const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
await mkdir(artifacts, { recursive: true });

// Independently enumerate authored detail content, so accidentally removing all
// links to an existing page cannot make the crawl pass with fewer routes.
const expectedRoutes = new Set(["/", ...PUBLIC_ROOTS]);
for (const [file, prefix] of [["roles.ts", "/ai-employees"], ["useCases.ts", "/use-cases"], ["comparisons.ts", "/compare"]]) {
  const source = await readFile(resolve(webRoot, "src/data/seo", file), "utf8");
  for (const match of source.matchAll(/\bslug:\s*"([a-z0-9-]+)"/g)) expectedRoutes.add(`${prefix}/${match[1]}`);
}
for (const file of await readdir(resolve(webRoot, "src/content/blog"))) {
  if (file.endsWith(".md")) expectedRoutes.add(`/blog/${file.slice(0, -3)}`);
}

const results = [];
const browser = await chromium.launch({ headless: true });
const forbiddenResource = /\.(?:glb|gltf|wasm)(?:\?|$)|\/assets\/(?:app-shell|dashboard|office-scene|agent-preview|babylon|recast)|\/socket(?:\/|\?)/i;
const accountPath = /^\/(?:login|signup|forgot-password|reset-password|account(?:\/[^?#]*)?)$/;

class PublicSite {
  constructor(page) {
    this.page = page;
    this.header = page.locator("[data-site-header]");
    this.footer = page.getByRole("contentinfo", { name: "Site footer" });
    this.heading = page.getByRole("heading", { level: 1 });
  }

  async open(path) {
    const response = await this.page.goto(new URL(path, origin).href, { waitUntil: "load" });
    assert.equal(response?.status(), 200, `${path}: document must load successfully`);
    await this.ready();
  }

  async ready() {
    await expect(this.heading).toHaveCount(1);
    await expect(this.heading).toBeVisible();
    await this.page.evaluate(() => document.fonts.ready);
  }

  async screenshot(name, locator) {
    const options = { path: resolve(artifacts, `${name}.png`), animations: "disabled" };
    if (locator) await locator.screenshot({ ...options, style: "[data-site-header] { visibility: hidden !important; }" });
    else await this.page.screenshot(options);
  }

  async topIsReadable() {
    await this.page.waitForFunction(() => {
      const header = document.querySelector("[data-site-header]")?.getBoundingClientRect();
      const heading = document.querySelector("h1")?.getBoundingClientRect();
      return header && heading && heading.top >= header.bottom - 2 && heading.top < innerHeight - 40;
    });
    const header = await this.header.boundingBox();
    const heading = await this.heading.boundingBox();
    assert.ok(header && heading, "Header and page heading have visible bounds");
    assert.ok(heading.y >= header.y + header.height - 2, "Page heading must clear the sticky header");
    assert.ok(heading.y < this.page.viewportSize().height - 40, "Navigation must reveal the new page heading, not preserve the previous page's footer position");
  }

  async noHorizontalOverflow() {
    const dimensions = await this.page.evaluate(() => ({
      viewport: innerWidth,
      document: document.documentElement.scrollWidth,
      body: document.body.scrollWidth,
    }));
    assert.ok(dimensions.document <= dimensions.viewport + 1 && dimensions.body <= dimensions.viewport + 1,
      `Horizontal document overflow: ${JSON.stringify(dimensions)}`);
    const headerBounds = await this.header.boundingBox();
    assert.ok(headerBounds && headerBounds.x >= -1 && headerBounds.x + headerBounds.width <= dimensions.viewport + 1,
      "Header must fit the viewport");
    assert.ok(headerBounds.y >= -1 && headerBounds.y < 2, "The shared header stays reachable while the page is scrolled");
    const controls = await this.header.locator("a, button").evaluateAll((elements) => elements.flatMap((element) => {
      const box = element.getBoundingClientRect();
      if (!box.width || !box.height || getComputedStyle(element).visibility === "hidden") return [];
      // The skip link is intentionally visually hidden until focused.
      if (element.getAttribute("href") === "#main-content" && document.activeElement !== element) return [];
      return [{ text: element.textContent.trim() || element.getAttribute("aria-label"), x: box.x, right: box.right, width: box.width }];
    }));
    for (const control of controls) assert.ok(control.x >= -1 && control.right <= dimensions.viewport + 1,
      `Header control is clipped: ${JSON.stringify(control)}`);
  }

  async revealAll() {
    // Walking the viewport triggers lazy sections/images and reveal effects.
    // Two animation frames synchronize with layout without arbitrary sleeps.
    await this.page.evaluate(async () => {
      for (let y = 0; y < document.documentElement.scrollHeight; y += Math.max(300, innerHeight * 0.8)) {
        window.scrollTo({ top: y, behavior: "instant" });
        await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
      }
    });
    await this.footer.scrollIntoViewIfNeeded();
    await this.page.waitForFunction(() => Array.from(document.images).every((image) => image.complete || image.loading === "lazy"));
    const missing = await this.page.locator("img").evaluateAll((images) => images
      .filter((image) => image.complete && image.naturalWidth === 0)
      .map((image) => image.currentSrc || image.src));
    assert.deepEqual(missing, [], "Public image assets must load");
  }

  async follow(link, target) {
    const destination = new URL(target, origin);
    await link.click();
    await this.page.waitForURL((url) => destination.pathname.startsWith("/account")
      ? url.pathname === "/login" || url.pathname === destination.pathname
      : url.pathname === destination.pathname && url.hash === destination.hash);
    await this.ready();
    if (destination.hash) {
      const id = decodeURIComponent(destination.hash.slice(1));
      await this.page.waitForFunction((id) => {
        const target = document.getElementById(id);
        const header = document.querySelector("[data-site-header]");
        if (!target || !header) return false;
        const y = target.getBoundingClientRect().top;
        return y >= header.getBoundingClientRect().bottom - 3 && y < innerHeight - 40;
      }, id);
    } else if (publicRoute(destination.pathname)) {
      await this.topIsReadable();
    }
  }
}

async function probe(name, run, viewport = { width: 1440, height: 900 }, reducedMotion = "reduce") {
  const context = await browser.newContext({ viewport, reducedMotion });
  const faults = [];
  const calls = [];
  await context.addInitScript(() => localStorage.setItem("mokaid_cookie_consent", "rejected"));
  await context.tracing.start({ screenshots: true, snapshots: true });
  await context.route("**/*", async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    calls.push(url.href);
    if (url.hostname === "downloads.mokaid.com" && url.pathname === "/stable/release.json") {
      return route.fulfill({ status: 404, headers: { "access-control-allow-origin": "*" }, json: { error: "No public release" } });
    }
    if (url.pathname.startsWith("/api/")) {
      if (url.pathname === "/api/me") return route.fulfill({ status: 401, json: { error: { code: "unauthorized", message: "Sign in required" } } });
      faults.push(`Unexpected public API request: ${request.method()} ${url.pathname}`);
      return route.fulfill({ status: 403, json: { error: { code: "probe_denied" } } });
    }
    if (url.origin !== origin.origin) return route.abort("blockedbyclient");
    if (forbiddenResource.test(url.href)) {
      faults.push(`Desktop business resource on public website: ${url.pathname}`);
      return route.abort("blockedbyclient");
    }
    return route.continue();
  });
  const page = await context.newPage();
  page.setDefaultTimeout(15_000);
  page.on("pageerror", (error) => faults.push(error.message));
  page.on("websocket", (socket) => faults.push(`Unexpected websocket: ${socket.url()}`));
  page.on("response", (response) => {
    const url = new URL(response.url());
    if (url.origin === origin.origin && !url.pathname.startsWith("/api/") && response.status() >= 400) {
      faults.push(`Broken local response: ${response.status()} ${url.pathname}`);
    }
  });
  page.on("requestfailed", (request) => {
    const url = new URL(request.url());
    const failure = request.failure()?.errorText;
    // Navigating away may legitimately cancel an image/fetch that was in flight.
    if (url.origin === origin.origin && !/ERR_ABORTED|NS_BINDING_ABORTED/.test(failure ?? "")) {
      faults.push(`Failed local request: ${url.pathname}: ${failure}`);
    }
  });
  const site = new PublicSite(page);
  try {
    const details = await run({ page, site });
    assert.deepEqual(faults, [], "No page errors, broken assets, or unexpected public API calls");
    results.push({ name, status: "pass", ...details });
  } catch (error) {
    await page.screenshot({ path: resolve(artifacts, `${name}-failure.png`), animations: "disabled" }).catch(() => {});
    results.push({ name, status: "fail", error: String(error), faults });
  } finally {
    await context.tracing.stop({ path: resolve(artifacts, `${name}-trace.zip`) });
    await context.close();
  }
}

async function crawl({ page, site }) {
  const queue = ["/", ...PUBLIC_ROOTS];
  const seen = new Set(queue);
  const reached = new Set();
  const linksByRoute = new Map();
  const idsByRoute = new Map();
  while (queue.length) {
    const path = queue.shift();
    await site.open(path);
    assert.equal(new URL(page.url()).pathname, path, `${path}: must render its own route`);
    await expect(page.locator('link[rel="canonical"]')).toHaveAttribute("href", `${SITE_URL}${path}`);
    await site.topIsReadable();
    await site.noHorizontalOverflow();
    await site.revealAll();
    await site.noHorizontalOverflow();
    assert.ok((await site.heading.innerText()).trim().length > 0, `${path}: nonempty page heading`);
    const metadata = await page.evaluate(() => ({
      title: document.title,
      description: document.querySelector('meta[name="description"]')?.content ?? "",
      ids: [...document.querySelectorAll("[id]")].map((element) => element.id),
      links: [...document.querySelectorAll("a[href]")].map((link) => link.getAttribute("href")),
    }));
    assert.ok(metadata.title.length >= 10 && metadata.description.length >= 40, `${path}: complete page metadata`);
    const localLinks = [];
    for (const href of metadata.links) {
      assert.ok(href && href !== "#" && !href.startsWith("javascript:"), `${path}: dead or placeholder link ${href}`);
      const target = new URL(href, page.url());
      if (target.origin !== origin.origin) continue;
      const targetRoute = publicRoute(target.pathname);
      assert.ok(targetRoute || accountPath.test(target.pathname), `${path}: unexpected local destination ${href}`);
      localLinks.push(target.pathname + target.search + target.hash);
      if (targetRoute && !seen.has(targetRoute)) {
        queue.push(targetRoute);
        seen.add(targetRoute);
      }
    }
    linksByRoute.set(path, localLinks);
    idsByRoute.set(path, new Set(metadata.ids));
    reached.add(path);
    if (path === "/download") await expect(page.getByRole("button", { name: "Download not available", exact: true })).toHaveCount(2);
  }
  assert.deepEqual([...reached].sort(), [...expectedRoutes].sort(), "Every authored public page must be reachable from the website");
  for (const [source, links] of linksByRoute) for (const href of links) {
    const target = new URL(href, origin);
    if (target.hash && publicRoute(target.pathname)) {
      assert.ok(idsByRoute.get(target.pathname)?.has(decodeURIComponent(target.hash.slice(1))), `${source}: broken section link ${href}`);
    }
  }
  return { routes: [...reached].sort(), internalLinks: [...linksByRoute.values()].flat().length };
}

async function desktopNavigation({ page, site }) {
  await site.open("/ai-employees");
  const headerTargets = ["/#product", "/ai-employees", "/#connectors", "/pricing", "/download", "/login"];
  for (const target of headerTargets) {
    await site.open("/ai-employees");
    await site.follow(site.header.locator(`a[href="${target}"]:visible`), target);
  }
  for (const target of ["/use-cases", "/compare", "/blog", "/glossary"]) {
    await site.open("/pricing");
    await site.header.getByRole("button", { name: "Resources", exact: true }).click();
    const menu = page.getByRole("menu", { name: "Resources" });
    await expect(menu).toBeVisible();
    await site.follow(menu.locator(`a[href="${target}"]`), target);
    await expect(menu).toBeHidden();
  }
  await site.open("/ai-employees");
  await site.follow(site.header.getByRole("link", { name: "mokaid home", exact: true }), "/");

  await site.open("/ai-employees");
  const footerTargets = [...new Set(await site.footer.locator('a[href^="/"]').evaluateAll((links) => links.map((link) => link.getAttribute("href"))))];
  for (const target of footerTargets) {
    await site.open("/ai-employees");
    await site.footer.scrollIntoViewIfNeeded();
    await site.follow(site.footer.locator(`a[href="${target}"]`), target);
  }

  // This reproduces the screenshot's bottom-of-page navigation regression.
  await site.open("/ai-employees");
  const pricing = site.footer.getByRole("link", { name: "Pricing", exact: true });
  await pricing.scrollIntoViewIfNeeded();
  const previousScroll = await page.evaluate(() => window.scrollY);
  assert.ok(previousScroll > 100, "Back regression must start on a scrolled page");
  await site.follow(pricing, "/pricing");
  await page.goBack();
  await page.waitForURL((url) => url.pathname === "/ai-employees");
  await page.waitForFunction((previous) => Math.abs(scrollY - previous) <= 150, previousScroll);
  return { headerDestinations: headerTargets.length + 5, footerDestinations: footerTargets.length, backRestoresScroll: true };
}

async function keyboardNavigation({ page, site }) {
  await site.open("/ai-employees");
  await page.keyboard.press("Tab");
  const skip = site.header.getByRole("link", { name: "Skip to content", exact: true });
  await expect(skip).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(page.locator("#main-content")).toBeFocused();
  const resources = site.header.getByRole("button", { name: "Resources", exact: true });
  await resources.focus();
  await page.keyboard.press("Enter");
  const menu = page.getByRole("menu", { name: "Resources" });
  await expect(menu).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(menu).toBeHidden();
  await expect(resources).toBeFocused();
  await page.keyboard.press("ArrowDown");
  await expect(menu).toBeVisible();
  // Radix puts focus on the first item for keyboard opening.
  await expect(menu.getByRole("menuitem").filter({ hasText: "Use cases" })).toBeFocused();
  await page.keyboard.press("Enter");
  await page.waitForURL((url) => url.pathname === "/use-cases");
  await site.ready();
  await site.topIsReadable();
  return { skipLink: true, resourcesKeyboard: true };
}

async function publicControls({ page, site }) {
  await site.open("/");
  const officeTabs = page.getByRole("tablist", { name: "Explore the desktop office" });
  await officeTabs.scrollIntoViewIfNeeded();
  const panelContent = new Set();
  for (const label of ["At their desks", "Working together", "The whole team"]) {
    const tab = officeTabs.getByRole("tab", { name: label, exact: true });
    await tab.click();
    await expect(tab).toHaveAttribute("aria-selected", "true");
    const panel = page.getByRole("tabpanel", { name: label, exact: true });
    await expect(panel).toBeVisible();
    await expect(panel.getByRole("heading")).toBeVisible();
    panelContent.add((await panel.innerText()).trim());
    await expect(page.getByRole("tabpanel")).toHaveCount(1);
  }
  assert.equal(panelContent.size, 3, "Each office tab must display its own content");
  await page.keyboard.press("ArrowRight");
  await expect(officeTabs.getByRole("tab", { name: "At their desks", exact: true })).toHaveAttribute("aria-selected", "true");
  await expect(page.getByRole("tabpanel", { name: "At their desks", exact: true })).toBeVisible();

  await site.open("/pricing");
  const cycle = page.getByRole("group", { name: "Billing cycle", exact: true });
  const monthly = cycle.getByRole("button", { name: "Monthly", exact: true });
  const yearly = cycle.getByRole("button", { name: /^Yearly/ });
  await expect(monthly).toHaveAttribute("aria-pressed", "true");
  const monthlyCount = await page.getByText("Billed monthly", { exact: true }).count();
  assert.ok(monthlyCount > 0, "Paid plans must show their billing frequency");
  await yearly.click();
  await expect(yearly).toHaveAttribute("aria-pressed", "true");
  await expect(monthly).toHaveAttribute("aria-pressed", "false");
  await expect(page.getByText(/^\$[\d,]+ billed yearly$/)).toHaveCount(monthlyCount);
  await expect(page.getByText("Billed monthly", { exact: true })).toHaveCount(0);
  await monthly.click();
  await expect(monthly).toHaveAttribute("aria-pressed", "true");
  await expect(page.getByText("Billed monthly", { exact: true })).toHaveCount(monthlyCount);
  await expect(page.getByText(/^\$[\d,]+ billed yearly$/)).toHaveCount(0);

  const disclosures = await page.locator("main details").all();
  assert.ok(disclosures.length > 0, "Pricing includes its FAQ answers");
  for (const disclosure of disclosures) {
    const summary = disclosure.locator("summary");
    await expect(disclosure).not.toHaveAttribute("open");
    await summary.click();
    await expect(disclosure).toHaveAttribute("open", "");
    await expect(disclosure.locator("p")).toBeVisible();
    assert.ok((await disclosure.locator("p").innerText()).trim().length > 20, "An expanded FAQ shows a complete answer");
    await summary.focus();
    await page.keyboard.press("Space");
    await expect(disclosure).not.toHaveAttribute("open");
  }
  await site.noHorizontalOverflow();
  return { officeTabs: panelContent.size, pricingCycles: 2, faqDisclosures: disclosures.length };
}

async function missingPages({ page, site }) {
  const destinations = [
    ["/this-page-does-not-exist", "/"],
    ["/ai-employees/missing-role", "/ai-employees"],
    ["/use-cases/missing-case", "/use-cases"],
    ["/compare/missing-comparison", "/compare"],
    ["/blog/missing-article", "/blog"],
  ];
  for (const [path, recovery] of destinations) {
    await site.open(path);
    await site.topIsReadable();
    await site.noHorizontalOverflow();
    await expect(page.locator('meta[name="robots"]')).toHaveAttribute("content", /noindex/);
    await site.follow(page.locator(`main a[href="${recovery}"]`), recovery);
    await expect(page.locator('meta[name="robots"]')).not.toHaveAttribute("content", /noindex/);
  }
  return { missingRoutes: destinations.length, recoveryLinks: destinations.length };
}

async function responsiveLayout({ page, site }, name) {
  const viewport = page.viewportSize();
  for (const [route, slug] of [["/", "home"], ["/ai-employees", "ai-employees"]]) {
    await site.open(route);
    await site.topIsReadable();
    await site.noHorizontalOverflow();
    if (route === "/") {
      await page.waitForFunction(() => [...document.querySelectorAll("[data-hero-wordmark], [data-hero-tagline], [data-hero-sub]")]
        .every((element) => Number(getComputedStyle(element).opacity) >= 0.99));
      const selectors = ["[data-hero-wordmark]", "[data-hero-tagline]", "[data-hero-intro]", "[data-hero-sub]", "[data-hero-actions]"];
      const boxes = [];
      for (const selector of selectors) {
        const locator = page.locator(selector);
        await expect(locator).toHaveCount(1);
        const box = await locator.boundingBox();
        assert.ok(box && box.width > 0 && box.height > 0, `${selector}: visible hero content`);
        assert.ok(box.x >= 0 && box.x + box.width <= viewport.width + 1, `${selector}: hero content fits horizontally`);
        boxes.push({ selector, ...box });
      }
      for (let i = 1; i < boxes.length; i++) {
        assert.ok(boxes[i].y >= boxes[i - 1].y + boxes[i - 1].height - 1,
          `Hero text must not overlap: ${JSON.stringify([boxes[i - 1], boxes[i]])}`);
      }
      if (viewport.width >= 1024) {
        const actions = boxes.at(-1);
        assert.ok(actions.y + actions.height <= viewport.height, "Desktop download/account actions must fit the initial viewport");
      }
    }
    await site.screenshot(`${slug}-${name}-top`);
    await site.revealAll();
    await site.noHorizontalOverflow();
    const footerColumns = [];
    for (const title of ["Product", "Resources", "Account", "Legal"]) {
      const heading = site.footer.getByRole("heading", { name: title, exact: true });
      await expect(heading).toBeVisible();
      footerColumns.push({ title, ...await heading.boundingBox() });
    }
    if (viewport.width >= 1024) {
      const row = footerColumns.map((column) => column.y);
      assert.ok(Math.max(...row) - Math.min(...row) <= 2, "All four desktop footer columns belong to the same row");
      for (let i = 1; i < footerColumns.length; i++) {
        assert.ok(footerColumns[i].x > footerColumns[i - 1].x, "Footer columns must remain distinct");
      }
    }
    await site.screenshot(`${slug}-${name}-footer`, site.footer);
  }
  if (viewport.width < 1024) {
    await site.open("/ai-employees");
    const trigger = site.header.getByRole("button", { name: "Open menu", exact: true });
    const mobile = site.header.getByRole("navigation", { name: "Mobile navigation", exact: true });
    await trigger.click();
    await expect(mobile).toBeVisible();
    await site.noHorizontalOverflow();
    await site.screenshot(`menu-${name}`);
    await page.keyboard.press("Escape");
    await expect(mobile).toBeHidden();
    await expect(trigger).toBeFocused();
    for (const target of ["/pricing", "/#connectors", "/blog"]) {
      await trigger.click();
      await site.follow(mobile.locator(`a[href="${target}"]`), target);
      await expect(mobile).toBeHidden();
      await expect(site.header.getByRole("button", { name: "Open menu", exact: true })).toHaveAttribute("aria-expanded", "false");
    }
  }
  if (viewport.width === 1440 || viewport.width === 390 || viewport.width === 320) {
    for (const route of ["/pricing", "/download", "/privacy"]) {
      await site.open(route);
      await site.topIsReadable();
      await site.noHorizontalOverflow();
      await site.screenshot(`${route.slice(1)}-${name}-top`);
      await site.revealAll();
      await site.noHorizontalOverflow();
    }
  }
  return { viewport, motion: name.includes("normal") ? "no-preference" : "reduce" };
}

const matrix = [
  { width: 1512, height: 750 },
  { width: 1440, height: 900 },
  { width: 1024, height: 768 },
  { width: 768, height: 1024 },
  { width: 390, height: 844 },
  { width: 320, height: 640 },
];
const jobs = [
  () => probe("crawl", crawl),
  () => probe("crawl-mobile", crawl, { width: 390, height: 844 }),
  () => probe("desktop-navigation", desktopNavigation),
  () => probe("keyboard-navigation", keyboardNavigation),
  () => probe("public-controls", publicControls),
  () => probe("missing-pages", missingPages),
  ...matrix.map((viewport) => {
    const name = `${viewport.width}x${viewport.height}-reduced`;
    return () => probe(`layout-${name}`, (test) => responsiveLayout(test, name), viewport);
  }),
  ...[matrix[0], matrix[4]].map((viewport) => {
    const name = `${viewport.width}x${viewport.height}-normal`;
    return () => probe(`layout-${name}`, (test) => responsiveLayout(test, name), viewport, "no-preference");
  }),
];
try {
  // Keep two isolated browsers contexts busy without overloading small CI hosts.
  await Promise.all(Array.from({ length: 2 }, async () => {
    while (jobs.length) await jobs.shift()();
  }));
} finally {
  await writeFile(resolve(artifacts, "results.json"), JSON.stringify(results, null, 2));
  await browser.close();
}
console.log(JSON.stringify({ expectedPublicRoutes: expectedRoutes.size, artifacts, results }, null, 2));
if (results.some((result) => result.status === "fail")) process.exitCode = 1;
