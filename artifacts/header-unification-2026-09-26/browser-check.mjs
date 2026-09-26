import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { chromium, webkit, firefox } from "../../node_modules/playwright/index.mjs";

const origin = process.argv[2] || "http://127.0.0.1:5181";
const engine = process.argv[3] || "chromium";
const nojs = process.argv.includes("--nojs");
const browsers = { chromium, webkit, firefox };
const output = new URL("./", import.meta.url);
const mobileOnly = process.argv.includes("--mobile-only");
const prefix = `${nojs ? "nojs" : "interactive"}-${engine}${mobileOnly ? "-mobile" : ""}`;
const report = { origin, engine, nojs, status: "running", checks: [], defects: [], geometry: [], screenshots: [], apiReads: [], errors: [], setup: "Isolated browser contexts. Film requests aborted; release.json returns404. Auth uses only a synthetic browser: marker in localStorage and a stubbed /api/me read. No login, downloads or API writes." };
const paths = ["/", "/pricing", "/download", "/ai-employees", "/privacy", "/terms", "/cookies", "/legal", "/refund"];
const fixtureUser = { id: "header-qa-user", email: "header-qa@example.invalid", full_name: "Header QA", avatar_url: null, auth_provider: "password", has_password: true };
const browser = await browsers[engine].launch();
let currentPage;
const contexts = [];
async function createPage(width = 1440, auth = false, actualMedia = false) {
  const context = await browser.newContext({ viewport: { width, height: 900 }, javaScriptEnabled: !nojs });
  contexts.push(context);
  if (!actualMedia) await context.route("**/*.mp4", (route) => route.abort());
  await context.route("https://downloads.mokaid.com/**", (route) => route.fulfill({ status: 404, body: "Not available in header test" }));
  await context.route("**/api/**", (route) => {
    const request = route.request();
    const path = new URL(request.url()).pathname;
    if (!path.startsWith("/api/")) return route.continue();
    report.apiReads.push({ method: request.method(), path, authenticatedFixture: auth });
    if (request.method() !== "GET") {
      report.errors.push(`Unexpected API write attempted: ${request.method()} ${path}`);
      return route.abort();
    }
    if (auth && path === "/api/me") return route.fulfill({ json: { user: fixtureUser, workspaces: [] } });
    return route.fulfill({ status: 503, json: { error: "API unavailable in isolated header test" } });
  });
  if (!nojs) await context.addInitScript(({ auth, user }) => {
    localStorage.setItem("mokaid_cookie_consent", "rejected");
    if (auth) localStorage.setItem("mokaid-auth", JSON.stringify({ version: 1, state: { token: "browser:header-qa-marker", user, workspaceId: null, workspaces: [] } }));
  }, { auth, user: fixtureUser });
  const page = await context.newPage();
  page.setDefaultTimeout(12000);
  page.on("pageerror", (error) => report.errors.push(String(error)));
  currentPage = page;
  return page;
}
async function loaded(page, path) {
  const servedPath = nojs && path !== "/" ? `${path}/index.html` : path;
  await page.goto(new URL(servedPath, origin).href, { waitUntil: nojs ? "load" : "domcontentloaded" });
  await page.locator("[data-site-header]").waitFor({ state: "visible" });
  if (!nojs) await page.waitForFunction(() => document.styleSheets.length > 0 && getComputedStyle(document.querySelector("[data-site-header]")).position !== "static");
  else assert.notEqual(await page.locator("[data-site-header]").evaluate((el) => getComputedStyle(el).position), "static");
  if (!nojs) await page.waitForFunction(() => Array.from(document.querySelectorAll('link[rel="stylesheet"]')).every((link) => link.sheet));
  await page.evaluate(() => document.fonts.ready);
  assert.equal(await page.locator("[data-site-header]").count(), 1);
}
async function headerBox(page, path, auth = false) {
  const h = page.locator("[data-site-header]");
  const primary = h.getByRole("navigation", { name: "Primary", exact: true });
  assert.equal(await primary.isVisible(), true);
  const expectedExperience = path === "/" ? "#product" : "/#product";
  assert.equal(await primary.locator("a").nth(0).getAttribute("href"), expectedExperience);
  assert.equal(await primary.locator("a").nth(1).getAttribute("href"), "/pricing");
  assert.equal(await h.getByRole("link", { name: auth ? "My account" : "Sign in", exact: true }).getAttribute("href"), auth ? "/account" : "/login");
  const nav = await primary.boundingBox();
  const home = await h.getByRole("link", { name: "mokaid home" }).boundingBox();
  const download = await h.getByRole("link", { name: "Download", exact: true }).boundingBox();
  const header = await h.boundingBox();
  assert.ok(Math.abs(nav.x + nav.width / 2 - page.viewportSize().width / 2) < 1, "Primary navigation centered");
  return { path, auth, nav, home, download, header };
}
async function screenshot(page, name) {
  const file = `${prefix}-${name}.png`;
  await page.screenshot({ path: new URL(file, output).pathname });
  report.screenshots.push(file);
}
async function mobileMenu(page, width, path) {
  await page.setViewportSize({ width, height: 900 });
  await loaded(page, path);
  const h = page.locator("[data-site-header]");
  assert.equal(await h.getByRole("navigation", { name: "Primary", exact: true }).isVisible(), false);
  const summary = h.locator("summary");
  assert.equal(await summary.getAttribute("aria-label"), "Open menu");
  await summary.click();
  const nav = h.getByRole("navigation", { name: "Mobile", exact: true });
  await nav.waitFor({ state: "visible" });
  assert.equal(await nav.getByRole("link", { name: "Experience", exact: true }).getAttribute("href"), path === "/" ? "#product" : "/#product");
  assert.equal(await nav.getByRole("link", { name: "Pricing", exact: true }).getAttribute("href"), "/pricing");
  assert.equal(await nav.getByRole("link", { name: "Sign in", exact: true }).getAttribute("href"), "/login");
  const noOverflow = await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth);
  if (!noOverflow) report.defects.push(`${width}px ${path}: horizontal body overflow (header remains inside viewport)`);
  const bounds = await nav.boundingBox();
  assert.ok(bounds.x >= -1 && bounds.x + bounds.width <= width + 1);
  if (!nojs) {
    await page.keyboard.press("Escape");
    await nav.waitFor({ state: "hidden" });
    assert.equal(await summary.evaluate((el) => el === document.activeElement), true);
    await summary.press("Enter");
    await nav.waitFor({ state: "visible" });
    await nav.getByRole("link", { name: "Pricing", exact: true }).click();
    await page.waitForURL("**/pricing");
    await page.locator("[data-site-header] details:not([open])").waitFor({ state: "attached" });
  } else {
    await summary.click();
    await nav.waitFor({ state: "hidden" });
  }
  report.checks.push(`${width}px ${path}: native disclosure, links, ${noOverflow ? "no overflow" : "body overflow recorded"}${nojs ? " without JS" : ", Escape focus, keyboard Enter, navigation closes"}`);
}
try {
  report.version = browser.version();
  if (!mobileOnly) {
  const desktop = await createPage();
  for (const path of paths) {
    await loaded(desktop, path);
    const box = await headerBox(desktop, path);
    report.geometry.push(box);
    if (["/", "/pricing", "/download", "/privacy"].includes(path)) await screenshot(desktop, `desktop-${path.slice(1) || "home"}`);
  }
  const baseline = report.geometry[0];
  for (const item of nojs ? [] : report.geometry) {
    for (const key of ["nav", "home", "download", "header"]) {
      for (const dimension of ["x", "y", "width", "height"])
        assert.ok(Math.abs(item[key][dimension] - baseline[key][dimension]) <= 1, `${item.path} ${key}.${dimension} matches landing`);
    }
  }
  report.checks.push(nojs ? "Nine explicit prerender snapshots: one header, centered nav and correct hrefs; Vite extensionless fallback bypassed" : "Nine public routes: exactly one header, identical desktop positions, centered nav, correct hrefs");
  await loaded(desktop, "/");
  assert.equal(await desktop.locator("[data-site-header][data-landing-header]").count(), 1);
  if (!nojs) {
    await desktop.locator('[data-site-header] nav[aria-label="Primary"] a[href="/pricing"]').click();
    await desktop.waitForURL("**/pricing");
    await desktop.locator('[data-site-header] a[href="/download"]').click();
    await desktop.waitForURL("**/download");
    await desktop.goBack({ waitUntil: "domcontentloaded" });
    await desktop.waitForURL("**/pricing");
    await desktop.locator('[data-site-header] nav[aria-label="Primary"] a[href="/#product"]').click();
    await desktop.waitForURL("**/#product");
    await desktop.waitForFunction(() => Math.abs(document.getElementById("product").getBoundingClientRect().top - 72) < 3);
    await desktop.goBack({ waitUntil: "domcontentloaded" });
    await desktop.waitForURL("**/pricing");
    await desktop.locator("[data-site-header]").getByRole("link", { name: "Sign in", exact: true }).click();
    await desktop.waitForURL("**/login");
    await desktop.goBack({ waitUntil: "domcontentloaded" });
    await desktop.waitForURL("**/pricing");
    report.checks.push("Home → Pricing → Download → Back → Experience anchor → Back → Sign in → Back");
  }
  }
  const mobile = await createPage(390);
  for (const width of [320, 390, 767]) {
    for (const path of ["/", "/pricing", "/download", "/privacy"])
      await mobileMenu(mobile, width, path);
    await loaded(mobile, "/pricing");
    await mobile.locator("[data-site-header] summary").click();
    await screenshot(mobile, `mobile-${width}-pricing-open`);
  }
  if (!nojs) {
    await mobile.setViewportSize({ width: 768, height: 900 });
    await mobile.locator("[data-site-header] details:not([open])").waitFor({ state: "attached" });
    assert.equal(await mobile.getByRole("navigation", { name: "Primary", exact: true }).isVisible(), true);
    report.checks.push("768px breakpoint restores desktop nav and closes disclosure");
    const authenticated = await createPage(1440, true);
    for (const path of ["/", "/pricing", "/download", "/privacy"]) {
      await loaded(authenticated, path);
      const box = await headerBox(authenticated, path, true);
      assert.ok(Math.abs(box.nav.x + box.nav.width / 2 - 720) < 1);
    }
    await authenticated.locator("[data-site-header]").getByRole("link", { name: "My account", exact: true }).click();
    await authenticated.waitForURL("**/account");
    await authenticated.getByRole("heading", { name: "Your account", exact: true }).waitFor();
    await authenticated.goBack({ waitUntil: "domcontentloaded" });
    await authenticated.waitForURL("**/privacy");
    await authenticated.setViewportSize({ width: 390, height: 900 });
    await authenticated.locator("[data-site-header] summary").click();
    assert.equal(await authenticated.getByRole("navigation", { name: "Mobile", exact: true }).getByRole("link", { name: "My account" }).getAttribute("href"), "/account");
    await screenshot(authenticated, "mobile-authenticated");
    report.checks.push("Synthetic local auth: My account desktop/mobile; stubbed account route and Back");
    if (engine === "chromium") {
      const movie = await createPage(1440, false, true);
      await loaded(movie, "/");
      await movie.waitForFunction(() => document.getElementById("product")?.dataset.mode === "cinematic", null, { timeout: 15000 });
      const experience = movie.locator('[data-site-header] nav[aria-label="Primary"] a[href="#product"]');
      await experience.focus();
      await experience.press("Enter");
      await movie.waitForURL("**/#product");
      await movie.waitForFunction(() => Math.abs(document.getElementById("product").getBoundingClientRect().top - 72) < 3);
      report.actualMedia = await movie.evaluate(() => ({ mode: document.getElementById("product").dataset.mode, top: document.getElementById("product").getBoundingClientRect().top, currentTime: document.querySelector("#product video").currentTime, paused: document.querySelector("#product video").paused }));
      await movie.waitForFunction(() => !document.documentElement.classList.contains("lenis-scrolling"));
      await movie.keyboard.press("Home");
      await movie.evaluate(() => window.scrollTo(0, 0));
      await movie.waitForFunction(() => scrollY < 2 && Number(document.querySelector("#product [data-presented-time]").dataset.presentedTime) < 0.1);
      await movie.goBack({ waitUntil: "domcontentloaded" });
      await movie.waitForURL((url) => url.pathname === "/" && !url.hash);
      assert.equal(await movie.locator("[data-site-header]").count(), 1);
      report.checks.push("Actual MP4: ready cinematic → keyboard Experience at72px → reverse scroll zero → history Back home");
    }
  }
  assert.deepEqual(report.errors, []);
  report.status = report.defects.length ? "failed" : "passed";
  if (report.defects.length) process.exitCode = 1;
} catch (error) {
  report.status = "failed";
  report.error = String(error.stack || error);
  report.failureUrl = currentPage?.url();
  await currentPage?.screenshot({ path: new URL(`${prefix}-failure.png`, output).pathname }).catch(() => {});
  process.exitCode = 1;
} finally {
  await browser.close();
  await writeFile(new URL(`${prefix}.json`, output), `${JSON.stringify(report, null, 2)}\n`);
  console.log(JSON.stringify({ status: report.status, engine, nojs, error: report.error, checks: report.checks, defects: report.defects, errors: report.errors, screenshots: report.screenshots }, null, 2));
}
