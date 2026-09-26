/** Focused keyboard and navigation integration checks; no media fixture or production mutation. */
import assert from "node:assert/strict";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const origin = process.argv[2] || "http://127.0.0.1:5173";
const compiledOrigin = process.argv[3] || "http://127.0.0.1:4173";
const compiledOnly = process.argv.includes("--compiled-only");
const story = JSON.parse(
  await readFile(new URL("../src/data/cinematic-story.json", import.meta.url), "utf8"),
);
const output = fileURLToPath(
  new URL("../../../artifacts/mokaid-cinema-2026-09-25/verification/", import.meta.url),
);
await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true });
const report = {
  origin,
  compiledOrigin,
  media: story.video,
  startedAt: new Date().toISOString(),
  checks: [],
  errors: [],
};
let hero = { heading: "mokaid" };
let nav = [{ href: "#product" }, { href: "/pricing" }];
if (compiledOnly) {
  const previous = JSON.parse(await readFile(`${output}/keyboard-navigation.json`, "utf8"));
  report.sourceChecksStartedAt = previous.startedAt;
  report.checks = previous.checks.filter(({ name }) => !name.startsWith("compiled "));
  const preserved = report.checks.find(({ name }) => name === "source hero and primary navigation");
  if (preserved) {
    hero = preserved.hero;
    nav = preserved.nav;
  }
}
let activePage;
const record = (name, evidence) => report.checks.push({ name, ...evidence });
const waitMode = (page, mode) =>
  page.waitForFunction(
    (wanted) => document.querySelector("#product")?.dataset.mode === wanted,
    mode,
    { timeout: 18000 },
  );
const pageState = (page) =>
  page.evaluate(() => {
    const section = document.querySelector("#product");
    return {
      mode: section?.dataset.mode,
      videoCount: section?.querySelectorAll("video").length,
      src: section?.querySelector("video")?.getAttribute("src") ?? null,
      scrollY,
      scrollHeight: document.documentElement.scrollHeight,
      sectionTop: section?.getBoundingClientRect().top,
      sectionHeight: section?.getBoundingClientRect().height,
      endTop: document.querySelector("#cinematic-story-end")?.getBoundingClientRect().top,
      presentedTime: section?.querySelector(".mk-cinema-stage")?.dataset.presentedTime,
      activeElement: document.activeElement?.outerHTML?.slice(0, 250),
      lenisCount: document.documentElement.classList.contains("lenis") ? 1 : 0,
    };
  });

try {
  if (!compiledOnly) {
    // A held request exposes the real hidden loading stage without changing controller code.
    const loadingContext = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    activePage = await loadingContext.newPage();
    let heldRoute;
    await activePage.route(`**${story.video}`, (route) => {
      heldRoute = route;
    });
    await activePage.goto(origin, { waitUntil: "domcontentloaded" });
    await waitMode(activePage, "loading");
    const hiddenLink = await activePage.locator(".mk-cinema-skip").evaluate((link) => ({
      tabIndex: link.tabIndex,
      stageHidden: link.closest(".mk-cinema-stage")?.getAttribute("aria-hidden"),
    }));
    assert.equal(hiddenLink.tabIndex, -1);
    assert.equal(hiddenLink.stageHidden, "true");
    await activePage.keyboard.press("Tab");
    const initialTab = await activePage.evaluate(() => ({
      text: document.activeElement?.textContent?.trim(),
      hiddenAncestor: !!document.activeElement?.closest('[aria-hidden="true"]'),
    }));
    assert.equal(initialTab.hiddenAncestor, false);
    record("loading stage skip is excluded from keyboard focus", { hiddenLink, initialTab });
    if (heldRoute) await heldRoute.abort();
    await loadingContext.close();

    const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    activePage = await context.newPage();
    await activePage.goto(origin, { waitUntil: "domcontentloaded" });
    await waitMode(activePage, "cinematic");
    hero = await activePage.locator("[data-hero-scene]").evaluate((element) => ({
      count: document.querySelectorAll("[data-hero-scene]").length,
      heading: element.querySelector("h1")?.textContent?.trim(),
      top: element.getBoundingClientRect().top,
      height: element.getBoundingClientRect().height,
      opacity: getComputedStyle(element).opacity,
    }));
    nav = await activePage
      .locator('[data-landing-header] nav[aria-label="Primary"] a')
      .evaluateAll((links) =>
        links.map((link) => ({ text: link.textContent.trim(), href: link.getAttribute("href") })),
      );
    assert.equal(hero.count, 1);
    assert.ok(hero.heading);
    assert.deepEqual(
      nav.map(({ href }) => href),
      ["#product", "/pricing"],
    );
    record("source hero and primary navigation", { hero, nav, state: await pageState(activePage) });

    // Focus the header entry point, then activate by keyboard rather than click.
    await activePage.locator('[aria-label="Primary"] a[href="#product"]').focus();
    await activePage.keyboard.press("Enter");
    await activePage.waitForFunction(
      () => Math.abs(document.querySelector("#product").getBoundingClientRect().top - 72) < 3,
    );
    const entryTop = await activePage
      .locator("#product")
      .evaluate((el) => el.getBoundingClientRect().top);
    const tabTrace = [];
    for (let i = 0; i < 20; i++) {
      await activePage.keyboard.press("Tab");
      const focused = await activePage.evaluate(() => ({
        text: document.activeElement?.textContent?.trim().slice(0, 100),
        href: document.activeElement?.getAttribute("href"),
        hiddenAncestor: !!document.activeElement?.closest('[aria-hidden="true"]'),
        skip: document.activeElement?.classList.contains("mk-cinema-skip"),
      }));
      tabTrace.push(focused);
      assert.equal(focused.hiddenAncestor, false, "Tab must not enter an aria-hidden subtree");
      if (focused.skip) break;
    }
    assert.ok(tabTrace.at(-1)?.skip, "Tour skip is reachable from primary navigation by Tab");
    await activePage.waitForTimeout(200);
    const beforeSkip = await pageState(activePage);
    await activePage.keyboard.press("Enter");
    await activePage.waitForFunction(() => {
      const end = document.querySelector("#cinematic-story-end");
      return end && end.getBoundingClientRect().top <= innerHeight && scrollY > 5000;
    });
    await activePage.waitForTimeout(800);
    await activePage.waitForFunction(
      () => Number(document.querySelector(".mk-cinema-stage")?.dataset.presentedTime) >= 73.9,
    );
    await activePage.keyboard.press("Tab");
    const afterSkip = await activePage.evaluate(() => ({
      text: document.activeElement?.textContent?.trim(),
      href: document.activeElement?.getAttribute("href"),
      cta: document.activeElement?.classList.contains("mk-cinema-cta"),
      hiddenAncestor: !!document.activeElement?.closest('[aria-hidden="true"]'),
    }));
    assert.equal(
      afterSkip.href,
      "/",
      "Native anchor advances the sequential focus origin to the footer after the tour",
    );
    assert.equal(afterSkip.hiddenAncestor, false);
    await activePage.keyboard.press("Tab");
    await activePage.keyboard.press("Tab");
    const footerDownload = await activePage.evaluate(() => ({
      text: document.activeElement?.textContent?.trim(),
      href: document.activeElement?.getAttribute("href"),
    }));
    assert.equal(footerDownload.href, "/download");
    assert.equal(
      await activePage.locator(".mk-cinema-stage .mk-cinema-cta").getAttribute("href"),
      "/download",
    );
    record("keyboard Experience, Tab to skip, Enter to end, footer and payoff download links", {
      entryTop,
      tabTrace,
      beforeSkip,
      afterSkip,
      footerDownload,
      state: await pageState(activePage),
    });

    for (let i = 0; i < 2; i++) {
      await activePage.locator('[data-landing-header] a[href="/download"]').focus();
      await activePage.keyboard.press("Enter");
      await activePage.waitForURL("**/download");
      await activePage.waitForFunction(() => !document.querySelector(".mk-cinematic-story"));
      const away = await pageState(activePage);
      assert.equal(away.lenisCount, 0, "Landing Lenis class cleaned on navigation");
      await activePage.goBack({ waitUntil: "domcontentloaded" });
      await activePage.locator("#product").waitFor();
      await activePage.waitForTimeout(1200);
      const back = await pageState(activePage);
      assert.ok(back.videoCount <= 1);
      assert.equal(await activePage.locator("#product").count(), 1);
      assert.equal(await activePage.locator(".mk-cinema-skip").count(), back.videoCount);
      record(`SPA download and browser Back ${i + 1}`, { away, back });
    }
    await context.close();

    const preferenceContext = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    activePage = await preferenceContext.newPage();
    await activePage.goto(origin, { waitUntil: "domcontentloaded" });
    await waitMode(activePage, "cinematic");
    await activePage.emulateMedia({ reducedMotion: "reduce" });
    await waitMode(activePage, "static");
    assert.equal(await activePage.locator("#product video").count(), 0);
    const reduced = await pageState(activePage);
    assert.equal(reduced.lenisCount, 0);
    await activePage.emulateMedia({ reducedMotion: "no-preference" });
    await activePage.waitForTimeout(350);
    assert.equal(
      (await pageState(activePage)).mode,
      "static",
      "Do not grow the tour mid-visit after static fallback",
    );
    record("reduced-motion change releases video and retains stable fallback", {
      reduced,
      restored: await pageState(activePage),
    });
    await preferenceContext.close();

    const resizeContext = await browser.newContext({ viewport: { width: 1440, height: 900 } });
    activePage = await resizeContext.newPage();
    await activePage.goto(origin, { waitUntil: "domcontentloaded" });
    await waitMode(activePage, "cinematic");
    await activePage.setViewportSize({ width: 390, height: 844 });
    await waitMode(activePage, "static");
    assert.equal(await activePage.locator("#product video").count(), 0);
    const mobile = await pageState(activePage);
    assert.equal(mobile.lenisCount, 0);
    await activePage.locator('button[aria-label="Open menu"]').focus();
    await activePage.keyboard.press("Enter");
    assert.equal(
      await activePage.locator('button[aria-label="Close menu"]').getAttribute("aria-expanded"),
      "true",
    );
    await activePage.keyboard.press("Escape");
    assert.equal(
      await activePage.locator('button[aria-label="Open menu"]').getAttribute("aria-expanded"),
      "false",
    );
    await activePage.setViewportSize({ width: 1440, height: 900 });
    await activePage.waitForTimeout(350);
    assert.equal((await pageState(activePage)).mode, "static");
    record("viewport change releases video; mobile menu supports Enter/Escape", {
      mobile,
      restored: await pageState(activePage),
    });
    await resizeContext.close();
  }

  const compiledContext = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    reducedMotion: "reduce",
  });
  activePage = await compiledContext.newPage();
  await activePage.goto(compiledOrigin, { waitUntil: "domcontentloaded" });
  await activePage.locator("[data-hero-scene] h1").waitFor();
  const compiledHero = await activePage.locator("[data-hero-scene] h1").textContent();
  const compiledNav = await activePage
    .locator('[data-landing-header] nav[aria-label="Primary"] a')
    .evaluateAll((links) => links.map((link) => link.getAttribute("href")));
  assert.equal(compiledHero.trim(), hero.heading);
  assert.deepEqual(
    compiledNav,
    nav.map(({ href }) => href),
  );
  const footerLinks = await activePage
    .locator("footer nav a")
    .evaluateAll((links) =>
      links.map((link) => ({ text: link.textContent.trim(), href: link.getAttribute("href") })),
    );
  assert.ok(footerLinks.some(({ href }) => href === "/download"));
  assert.ok(
    footerLinks.every(
      ({ href }) => href && !["#agents", "#marketplace", "#connectors"].includes(href),
    ),
  );
  record("compiled hero/nav preserved and footer destinations valid", {
    compiledHero,
    compiledNav,
    footerLinks,
  });
  await compiledContext.close();
  report.status = "passed";
} catch (error) {
  report.status = "failed";
  report.errors.push({ message: error.message, stack: error.stack });
  if (activePage && !activePage.isClosed()) {
    report.failureState = await pageState(activePage).catch(() => null);
    await activePage
      .screenshot({ path: `${output}/keyboard-navigation-failure.png` })
      .catch(() => {});
  }
  process.exitCode = 1;
} finally {
  report.finishedAt = new Date().toISOString();
  await writeFile(`${output}/keyboard-navigation.json`, JSON.stringify(report, null, 2) + "\n");
  await browser.close();
}
console.log(JSON.stringify(report, null, 2));
