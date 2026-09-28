/** Browser checks for scroll-linked WebP frame packs.
 * node scripts/cinematic-story-browser.mjs [origin] [chromium,firefox,webkit] [--final|--prerender-only]
 */
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile, stat } from "node:fs/promises";
import { extname, join, resolve, sep } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chromium, firefox, webkit } from "playwright";

const origin = process.argv[2] || "http://127.0.0.1:5173";
const engines = { chromium, firefox, webkit };
const selected = (process.argv[3] || "chromium,firefox,webkit").split(",");
const finalMedia = process.argv.includes("--final");
const prerenderOnly = process.argv.includes("--prerender-only");
assert.ok(!(finalMedia && prerenderOnly), "Choose either --final or --prerender-only");
const reportPrefix = finalMedia ? "final-media" : prerenderOnly ? "prerender-nojs" : "fixture";
selected.forEach((name) => assert.ok(engines[name], `Unknown browser: ${name}`));
const story = JSON.parse(
  await readFile(new URL("../src/data/cinematic-story.json", import.meta.url), "utf8"),
);
const output =
  process.env.CINEMATIC_STORY_REPORT_DIR ||
  fileURLToPath(
    new URL("../../../artifacts/mokaid-cinema-2026-09-28/verification/", import.meta.url),
  );
await mkdir(output, { recursive: true });
const dist = fileURLToPath(new URL("../dist/", import.meta.url));
const temp = await mkdtemp(join(tmpdir(), "mokaid-cinema-test-"));
const fixtureWebp = join(temp, "fixture.webp");

assert.ok(story.frames?.desktop, "Manifest must declare frame packs");
const desktopPack =
  story.frames.desktop.base && story.frames.desktop.high
    ? story.frames.desktop.base
    : story.frames.desktop.pattern
      ? story.frames.desktop
      : story.frames.desktop.base;
const desktopHighPack = story.frames.desktop.high || null;
const mobilePack = story.frames.mobile;
assert.ok(desktopPack?.pattern, "Manifest must declare desktop base pack");
assert.equal(mobilePack.count, 148);
assert.equal(mobilePack.fps, 2);

let fixtureBody;
let mediaInfo;
if (finalMedia) {
  const first = fileURLToPath(
    new URL(
      `../public${desktopPack.pattern.replace("%05d", "00001")}`,
      import.meta.url,
    ),
  );
  const dir = fileURLToPath(
    new URL(`../public/assets/cinematic-frames.${story.frames.digest}/desktop`, import.meta.url),
  );
  const count = (await readdir(dir)).filter((name) => name.endsWith(".webp")).length;
  assert.equal(count, desktopPack.count);
  const bytes = await readFile(first);
  mediaInfo = {
    digest: story.frames.digest,
    desktop: desktopPack,
    mobile: mobilePack,
    sampleSha256: createHash("sha256").update(bytes).digest("hex"),
    sampleBytes: bytes.length,
  };
} else if (!prerenderOnly) {
  const encoded = spawnSync("ffmpeg", [
    "-hide_banner",
    "-loglevel",
    "error",
    "-y",
    "-f",
    "lavfi",
    "-i",
    "color=c=0x332244:s=64x36",
    "-frames:v",
    "1",
    "-c:v",
    "libwebp",
    "-quality",
    "80",
    fixtureWebp,
  ]);
  assert.equal(encoded.status, 0, encoded.stderr?.toString() || "fixture webp failed");
  fixtureBody = await readFile(fixtureWebp);
  mediaInfo = { fixture: true, bytes: fixtureBody.length };
}

function progressAtTime(time) {
  const next = story.scrollMap.findIndex((point) => point.time >= time);
  if (next <= 0) return 0;
  const from = story.scrollMap[next - 1];
  const to = story.scrollMap[next];
  return (
    from.progress + ((time - from.time) / (to.time - from.time)) * (to.progress - from.progress)
  );
}

function isFramePath(pathname) {
  return /\/assets\/cinematic-frames\.[a-f0-9]+\/(desktop|desktop-high|mobile)\/frame-\d+\.webp$/.test(
    pathname,
  );
}

class StoryPage {
  constructor(page) {
    this.page = page;
    this.root = page.getByRole("region", { name: "Discover the Mokaid AI office" });
    this.stage = this.root.locator("[data-presented-time]");
    this.canvas = this.root.locator("canvas.mk-cinema-canvas");
  }
  async snapshot() {
    return this.root.evaluate((el) => {
      const canvas = el.querySelector("canvas");
      const stage = el.querySelector(".mk-cinema-stage");
      const stageBox = stage?.getBoundingClientRect();
      const canvasBox = canvas?.getBoundingClientRect();
      return {
        mode: el.dataset.mode,
        top: el.getBoundingClientRect().top,
        height: el.clientHeight,
        viewport: innerHeight,
        scroll: scrollY,
        presentedTime: Number(el.querySelector("[data-presented-time]")?.dataset.presentedTime),
        canvasCount: el.querySelectorAll("canvas").length,
        stageWidth: stageBox?.width ?? 0,
        stageHeight: stageBox?.height ?? 0,
        canvasWidth: canvasBox?.width ?? 0,
        canvasHeight: canvasBox?.height ?? 0,
        canvasTop: canvasBox?.top ?? 0,
        stageTop: stageBox?.top ?? 0,
      };
    });
  }
  async waitReady() {
    await this.page.waitForFunction(
      () => document.getElementById("product")?.dataset.mode === "cinematic",
      null,
      { timeout: finalMedia ? 180_000 : 60_000 },
    );
    // Wait for cinematic CSS (Vite injects styles via JS) to size the sticky stage.
    await this.page.waitForFunction(
      () => {
        const stage = document.querySelector("#product .mk-cinema-stage");
        const canvas = document.querySelector("#product canvas.mk-cinema-canvas");
        if (!stage || !canvas) return false;
        const stageBox = stage.getBoundingClientRect();
        const canvasBox = canvas.getBoundingClientRect();
        return (
          Math.abs(stageBox.height - innerHeight) < 4 &&
          canvasBox.width > 100 &&
          canvasBox.height > 100 &&
          Math.abs(canvasBox.width - stageBox.width) < 3 &&
          Math.abs(canvasBox.height - stageBox.height) < 3
        );
      },
      null,
      { timeout: 15_000 },
    );
    return this.snapshot();
  }
  async frameAt(time) {
    const started = Date.now();
    const isMobile = await this.page.evaluate(() =>
      window.matchMedia("(orientation: portrait) and (max-width: 900px)").matches,
    );
    const candidates = isMobile
      ? [mobilePack]
      : [desktopHighPack, desktopPack].filter(Boolean);
    const expectedTimes = candidates.map((pack) => {
      const index = Math.min(
        pack.count,
        Math.max(
          pack.firstIndex,
          Math.round(Math.min(time, story.duration) * pack.fps) + pack.firstIndex,
        ),
      );
      return (index - pack.firstIndex) / pack.fps;
    });
    const tolerance = isMobile ? 0.2 : 0.35;
    let state;
    let expected = expectedTimes[0];
    for (let attempt = 0; attempt < 6; attempt += 1) {
      await this.root.evaluate((el, progress) => {
        const top = el.getBoundingClientRect().top + window.scrollY;
        window.scrollTo(0, top + (el.clientHeight - innerHeight) * progress);
      }, progressAtTime(time));
      await this.page.waitForFunction(
        ({ expectedTimes, tolerance }) => {
          const stage = document.querySelector("#product [data-presented-time]");
          if (!stage) return false;
          const presented = Number(stage.dataset.presentedTime);
          return expectedTimes.some((value) => Math.abs(presented - value) < tolerance);
        },
        { expectedTimes, tolerance },
        { timeout: attempt === 5 ? 8000 : 2500 },
      );
      state = await this.snapshot();
      expected = expectedTimes.reduce((best, candidate) =>
        Math.abs(state.presentedTime - candidate) < Math.abs(state.presentedTime - best)
          ? candidate
          : best,
      );
      if (Math.abs(state.presentedTime - expected) < tolerance) break;
    }
    assert.ok(
      Math.abs(state.presentedTime - expected) < tolerance,
      `Presented frame time must follow scroll (got ${state.presentedTime}, expected ~${expectedTimes.join("|")})`,
    );
    const cue = story.cues.find(
      (item) => state.presentedTime >= item.start && state.presentedTime < item.end,
    );
    await this.page.waitForFunction(
      (expectedText) => {
        const headings = Array.from(
          document.querySelectorAll("#product .mk-cinema-stage h2"),
          (node) => node.textContent || "",
        );
        if (!expectedText) return headings.length === 0;
        return headings.includes(expectedText);
      },
      cue?.text || null,
      { timeout: 5000 },
    );
    assert.deepEqual(
      await this.stage.getByRole("heading").allTextContents(),
      cue ? [cue.text] : [],
      "Captions must match the presented frame",
    );
    return {
      requestedTime: time,
      targetTime: expected,
      presentedTime: state.presentedTime,
      errorSeconds: Math.abs(state.presentedTime - expected),
      settledMs: Date.now() - started,
    };
  }
  async navigateAwayAndReturn(returnWith) {
    await this.frameAt(55);
    await this.page.evaluate((value) => {
      window.__cinematicNavigationProbe = value;
    }, `${returnWith}-${Date.now()}`);
    await this.page.goto(new URL("/download", origin).href, { waitUntil: "domcontentloaded" });
    if (returnWith === "history") await this.page.goBack({ waitUntil: "domcontentloaded" });
    else await this.page.getByRole("link", { name: /Mokaid|Home|home/i }).first().click();
    await this.waitReady();
    await this.page.waitForFunction(
      () => {
        const el = document.getElementById("product");
        return el && Math.abs(el.clientHeight - innerHeight * 13) < 2;
      },
      null,
      { timeout: 10_000 },
    );
    await this.frameAt(55);
  }
  async assertFullscreenCover() {
    await this.root.scrollIntoViewIfNeeded();
    const state = await this.snapshot();
    assert.ok(state.canvasCount === 1);
    assert.ok(Math.abs(state.canvasWidth - state.stageWidth) < 3, "Canvas must fill stage width");
    assert.ok(Math.abs(state.canvasHeight - state.stageHeight) < 3, "Canvas must fill stage height");
    assert.ok(Math.abs(state.canvasTop - state.stageTop) < 3, "No letterbox above the film");
    assert.ok(Math.abs(state.stageHeight - state.viewport) < 4, "Stage must be full viewport tall");
  }
}

async function runEngine(name) {
  const report = {
    status: "passed",
    fixtureSubstitution: !finalMedia && !prerenderOnly,
    timestamp: new Date().toISOString(),
    engine: name,
    origin,
    media: mediaInfo,
    passed: [],
    samples: [],
  };
  let browser;
  const contexts = new Set();
  const prepare = async (options = {}, routeMode = "film", path = "/") => {
    const context = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      ...options,
    });
    contexts.add(context);
    await context.tracing.start({ screenshots: true, snapshots: true });
    const page = await context.newPage();
    page.setDefaultTimeout(15_000);
    if (routeMode === "pending") await page.clock.install();
    const requests = [];
    let releasePending;
    let failMedia = routeMode === "fail";
    const pendingResponse =
      routeMode === "pending"
        ? new Promise((resolve) => {
            releasePending = resolve;
          })
        : undefined;
    await page.route("**/*", async (route) => {
      const pathname = new URL(route.request().url()).pathname;
      if (!isFramePath(pathname)) return route.continue();
      requests.push(pathname);
      if (failMedia) return route.abort();
      if (pendingResponse) await pendingResponse;
      if (finalMedia) return route.continue();
      return route.fulfill({
        status: 200,
        contentType: "image/webp",
        headers: { "Cache-Control": "public, max-age=31536000, immutable" },
        body: fixtureBody,
      });
    });
    const model = new StoryPage(page);
    const failedRequest =
      routeMode === "fail"
        ? page.waitForEvent("requestfailed", {
            predicate: (request) => isFramePath(new URL(request.url()).pathname),
          })
        : undefined;
    await page.goto(new URL(path, origin).href, { waitUntil: "domcontentloaded" });
    await page.waitForFunction(() =>
      Array.from(document.querySelectorAll('link[rel~="stylesheet"]'))
        .filter((link) => new URL(link.href).origin === location.origin)
        .every((link) => link.sheet),
    );
    return {
      page,
      context,
      model,
      requests,
      failedRequest,
      release: () => releasePending?.(),
      allowMedia: () => {
        failMedia = false;
      },
    };
  };
  const close = async (item) => {
    await item.context.tracing.stop();
    await item.context.close();
    contexts.delete(item.context);
  };

  try {
    browser = await engines[name].launch(
      name === "chromium" && process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH
        ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH }
        : {},
    );
    report.version = browser.version();

    // Prerender / no-JS
    {
      const context = await browser.newContext({
        viewport: { width: 1440, height: 900 },
        javaScriptEnabled: false,
      });
      contexts.add(context);
      const page = await context.newPage();
      const frameRequests = [];
      const mime = {
        ".html": "text/html",
        ".css": "text/css",
        ".js": "application/javascript",
        ".webp": "image/webp",
        ".png": "image/png",
        ".svg": "image/svg+xml",
        ".woff2": "font/woff2",
      };
      await page.route("**/*", async (route) => {
        const url = new URL(route.request().url());
        if (isFramePath(url.pathname)) frameRequests.push(url.pathname);
        if (url.origin !== new URL(origin).origin) return route.abort();
        const file = resolve(
          dist,
          url.pathname === "/" ? "index.html" : `.${decodeURIComponent(url.pathname)}`,
        );
        if (!file.startsWith(`${dist.replace(/\/$/, "")}${sep}`)) return route.abort();
        try {
          return await route.fulfill({
            contentType: mime[extname(file)] || "application/octet-stream",
            body: await readFile(file),
          });
        } catch {
          return route.fulfill({ status: 404, body: "Missing prerender asset" });
        }
      });
      const model = new StoryPage(page);
      await page.goto(origin, { waitUntil: "load" });
      await model.root.scrollIntoViewIfNeeded();
      assert.equal(await model.root.getAttribute("data-mode"), "static");
      assert.equal(await model.root.getByRole("article").count(), 3);
      assert.equal(await model.canvas.count(), 0);
      assert.equal(frameRequests.length, 0);
      report.passed.push("prerender/no-JS: illustrated moments, no frame pack requests");
      await context.close();
      contexts.delete(context);
    }

    if (!prerenderOnly) {
      const desktop = await prepare();
      report.readiness = await desktop.model.waitReady();
      assert.ok(
        desktop.requests.length >= 1,
        "progressive ready must fetch at least the opening frame",
      );
      assert.ok(
        desktop.requests.some((path) => path.includes("/desktop/frame-")),
        "desktop must start on the base pack",
      );
      await desktop.page.waitForFunction(
        () => {
          const el = document.getElementById("product");
          return el && Math.abs(el.clientHeight - innerHeight * 13) < 2;
        },
        null,
        { timeout: 10_000 },
      );
      report.readiness = await desktop.model.snapshot();
      assert.equal(report.readiness.height, report.readiness.viewport * 13);
      await desktop.model.assertFullscreenCover();
      for (const time of [7, 13, 20, 32, 42, 51, 61, 67, 74, 0, 72, 2, 55, 18, 65, 74]) {
        report.samples.push(await desktop.model.frameAt(time));
      }
      // Background fill should request the whole pack during the scrub session.
      {
        const deadline = Date.now() + 30_000;
        while (Date.now() < deadline && desktop.requests.length < desktopPack.count) {
          await desktop.page.waitForTimeout(100);
        }
        assert.ok(
          desktop.requests.length >= desktopPack.count,
          `expected >= ${desktopPack.count} frame requests, got ${desktop.requests.length}`,
        );
      }
      if (desktopHighPack) {
        const deadline = Date.now() + 45_000;
        while (
          Date.now() < deadline &&
          !desktop.requests.some((path) => path.includes("/desktop-high/"))
        ) {
          await desktop.page.waitForTimeout(100);
        }
        assert.ok(
          desktop.requests.some((path) => path.includes("/desktop-high/")),
          "desktop densify must request high pack on a healthy connection",
        );
        report.passed.push("desktop: high densify pack requested after base ready");
      }
      assert.equal(
        await desktop.page
          .getByLabel("Examples of completed tasks")
          .locator(":scope > div")
          .count(),
        5,
      );
      if (finalMedia) {
        await desktop.page.screenshot({ path: join(output, `final-media-${name}-payoff.png`) });
      }
      await desktop.model.navigateAwayAndReturn("history");
      report.passed.push("desktop: progressive frames, scroll milestones, SPA restore, fullscreen cover");
      await close(desktop);

      for (const [label, options] of [
        [
          "mobile viewport",
          {
            viewport: { width: 390, height: 844 },
            ...(name === "firefox" ? {} : { isMobile: true }),
            hasTouch: true,
          },
        ],
        [
          "tablet viewport",
          {
            viewport: { width: 820, height: 1180 },
            ...(name === "firefox" ? {} : { isMobile: true }),
            hasTouch: true,
          },
        ],
      ]) {
        const item = await prepare(options);
        await item.model.waitReady();
        await item.model.assertFullscreenCover();
        for (const time of [7, 18, 35, 55, 74]) await item.model.frameAt(time);
        assert.ok(
          item.requests.every((path) => !path.includes("/desktop-high/")),
          `${label} must not request desktop-high`,
        );
        if (finalMedia && label === "mobile viewport") {
          await item.page.screenshot({
            path: join(output, `final-media-${name}-mobile-fullscreen.png`),
          });
          const layout = await item.model.snapshot();
          await writeFile(
            join(output, `final-media-${name}-mobile-layout.json`),
            `${JSON.stringify(layout, null, 2)}\n`,
          );
        }
        await item.page.setViewportSize({
          width: options.viewport.height,
          height: options.viewport.width,
        });
        await item.model.waitReady();
        await item.model.assertFullscreenCover();
        report.passed.push(`${label}: fullscreen cover, captions, rotation`);
        await close(item);
      }

      const reducedMotion = await prepare({ reducedMotion: "reduce" });
      await reducedMotion.model.root.scrollIntoViewIfNeeded();
      assert.equal(reducedMotion.requests.length, 0);
      assert.equal(await reducedMotion.model.canvas.count(), 0);
      await reducedMotion.page.emulateMedia({ reducedMotion: "no-preference" });
      await reducedMotion.model.waitReady();
      report.passed.push("reduced motion reversible");
      await close(reducedMotion);

      const failed = await prepare({}, "fail");
      await failed.failedRequest;
      const retry = failed.model.root.getByRole("button", { name: "Retry the tour" });
      await retry.waitFor({ state: "visible", timeout: 20_000 });
      failed.allowMedia();
      await retry.click();
      await failed.model.waitReady();
      await failed.model.frameAt(51);
      report.passed.push("failed pack retry restores scrubbing");
      await close(failed);
    }
  } catch (error) {
    report.status = "failed";
    report.error = { message: error.message, stack: error.stack };
    throw error;
  } finally {
    for (const context of contexts) await context.close().catch(() => undefined);
    await browser?.close().catch(() => undefined);
    await writeFile(join(output, `${reportPrefix}-${name}.json`), `${JSON.stringify(report, null, 2)}\n`);
  }
  return report;
}

const results = [];
for (const name of selected) results.push(await runEngine(name));
await rm(temp, { recursive: true, force: true });
assert.ok(results.every((item) => item.status === "passed"));
console.log(JSON.stringify({ output, results: results.map((item) => item.engine) }, null, 2));
