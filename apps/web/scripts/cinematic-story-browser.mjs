/** Browser/decoder checks; fixture mode never changes the manifest or public files.
 * node scripts/cinematic-story-browser.mjs [origin] [chromium,firefox,webkit] [--final|--prerender-only]
 */
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
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
const output = fileURLToPath(
  new URL("../../../artifacts/mokaid-cinema-2026-09-25/verification/", import.meta.url),
);
await mkdir(output, { recursive: true });
const dist = fileURLToPath(new URL("../dist/", import.meta.url));
const temp = await mkdtemp(join(tmpdir(), "mokaid-cinema-test-"));
const fixture = join(temp, "fixture.mp4");
let body;
let mediaInfo;
if (finalMedia) {
  assert.match(
    story.video,
    /[.-][a-f0-9]{8,64}\.mp4$/i,
    "Final verification requires the fingerprinted MP4 in the existing manifest",
  );
  const source = fileURLToPath(new URL(`../public${story.video}`, import.meta.url));
  const bytes = await readFile(source);
  const probe = spawnSync("ffprobe", [
    "-v",
    "error",
    "-show_streams",
    "-show_format",
    "-of",
    "json",
    source,
  ]);
  assert.equal(probe.status, 0, probe.stderr?.toString() || "ffprobe failed");
  const metadata = JSON.parse(probe.stdout.toString());
  const stream = metadata.streams.find((item) => item.codec_type === "video");
  assert.equal(stream?.width, 1920);
  assert.equal(stream?.height, 1080);
  assert.equal(stream?.codec_name, "h264");
  assert.ok(Math.abs(Number(metadata.format.duration) - story.duration) < 0.05);
  assert.equal(
    metadata.streams.some((item) => item.codec_type === "audio"),
    false,
  );
  const [numerator, denominator] = stream.avg_frame_rate.split("/").map(Number);
  assert.equal(numerator / denominator, story.fps);
  mediaInfo = {
    source: story.video,
    sha256: createHash("sha256").update(bytes).digest("hex"),
    bytes: bytes.length,
    width: stream.width,
    height: stream.height,
    duration: Number(metadata.format.duration),
    fps: numerator / denominator,
    codec: stream.codec_name,
    audio: false,
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
    "testsrc2=size=320x180:rate=24:duration=74",
    "-an",
    "-c:v",
    "libx264",
    "-preset",
    "ultrafast",
    "-crf",
    "28",
    "-g",
    "6",
    "-bf",
    "0",
    "-pix_fmt",
    "yuv420p",
    "-movflags",
    "+faststart",
    fixture,
  ]);
  assert.equal(encoded.status, 0, encoded.stderr?.toString() || "FFmpeg fixture generation failed");
  body = await readFile(fixture);
  mediaInfo = {
    duration: 74,
    fps: 24,
    width: 320,
    height: 180,
    gopFrames: 6,
    bFrames: 0,
    audio: false,
    bytes: body.length,
    rangeResponses: true,
  };
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

class StoryPage {
  constructor(page) {
    this.page = page;
    this.root = page.getByRole("region", { name: "Discover the Mokaid AI office" });
    this.stage = this.root.locator("[data-presented-time]");
    this.video = this.root.locator("video");
  }
  async snapshot() {
    return this.root.evaluate((el) => {
      const video = el.querySelector("video");
      const ranges = video
        ? Array.from({ length: video.seekable.length }, (_, index) => [
            video.seekable.start(index),
            video.seekable.end(index),
          ])
        : [];
      return {
        mode: el.dataset.mode,
        top: el.getBoundingClientRect().top,
        height: el.clientHeight,
        viewport: innerHeight,
        scroll: scrollY,
        hidden: document.hidden,
        currentTime: video?.currentTime,
        presentedTime: Number(el.querySelector("[data-presented-time]")?.dataset.presentedTime),
        readyState: video?.readyState,
        duration: video?.duration,
        seeking: video?.seeking,
        paused: video?.paused,
        muted: video?.muted,
        playsInline: video?.hasAttribute("playsinline"),
        playsInlineProperty: video?.playsInline,
        hasVideoFrameCallback: "requestVideoFrameCallback" in HTMLVideoElement.prototype,
        seekable: ranges,
      };
    });
  }
  async waitReady() {
    await this.page.waitForFunction(
      () => document.getElementById("product")?.dataset.mode === "cinematic",
      null,
      { timeout: 9000 },
    );
    return this.snapshot();
  }
  async frameAt(time) {
    const started = Date.now();
    await this.root.evaluate((el, progress) => {
      window.scrollTo(
        0,
        window.scrollY +
          el.getBoundingClientRect().top +
          (el.clientHeight - innerHeight) * progress,
      );
    }, progressAtTime(time));
    const expected = Math.min(story.duration - 1 / story.fps, time);
    await this.page.waitForFunction(
      (expected) => {
        const stage = document.querySelector("#product [data-presented-time]");
        const video = stage?.querySelector("video");
        return (
          video && !video.seeking && Math.abs(Number(stage.dataset.presentedTime) - expected) < 0.1
        );
      },
      expected,
      { timeout: 6000 },
    );
    const state = await this.snapshot();
    assert.equal(state.paused && state.muted && state.playsInline, true);
    return {
      requestedTime: time,
      targetTime: expected,
      presentedTime: state.presentedTime,
      errorSeconds: Math.abs(state.presentedTime - expected),
      errorFrames: Math.abs(state.presentedTime - expected) * story.fps,
      settledMs: Date.now() - started,
    };
  }
}

async function runBrowser(name) {
  const report = {
    fixtureOnly: !finalMedia && !prerenderOnly,
    testMode: reportPrefix,
    disclaimer: finalMedia
      ? "Actual fingerprinted 1080p media through the supplied server. Automated browser/decoder checks do not establish creative continuity, native Safari or real mobile hardware performance."
      : prerenderOnly
        ? "Existing dist/index.html with JavaScript disabled. No video or fixture is loaded."
        : "Synthetic 320×180 H.264 decoder fixture. Does not validate Higgsfield footage, 1080p performance, native Safari or real mobile hardware.",
    timestamp: new Date().toISOString(),
    engine: name,
    origin,
    media: mediaInfo,
    passed: [],
    samples: [],
  };
  let browser;
  let current;
  const contexts = new Set();
  const prepare = async (options = {}, routeMode = "film", disableFrameCallback = false) => {
    const context = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      ...options,
    });
    contexts.add(context);
    await context.tracing.start({ screenshots: true, snapshots: true });
    if (disableFrameCallback)
      await context.addInitScript(() => {
        delete HTMLVideoElement.prototype.requestVideoFrameCallback;
      });
    const page = await context.newPage();
    page.setDefaultTimeout(10_000);
    const requests = [];
    const mediaResponses = [];
    page.on("response", (response) => {
      if (new URL(response.url()).pathname !== story.video) return;
      mediaResponses.push({
        status: response.status(),
        contentRange: response.headers()["content-range"],
        acceptRanges: response.headers()["accept-ranges"],
        contentType: response.headers()["content-type"],
      });
    });
    let releasePending;
    await page.route(`**${story.video}`, async (route) => {
      const header = route.request().headers().range;
      requests.push(header || "full");
      if (routeMode === "fail") return route.abort();
      if (routeMode === "pending") {
        await new Promise((resolve) => {
          releasePending = resolve;
        });
        return route.abort();
      }
      // An explicit response-latency simulation, not an arbitrary assertion wait.
      if (routeMode === "slow" && requests.length === 1)
        await new Promise((resolve) => setTimeout(resolve, 3000));
      // Final mode uses the real URL/server/bytes; it never substitutes the fixture.
      if (finalMedia) return route.continue();
      const range = header?.match(/^bytes=(\d+)-(\d*)$/);
      if (range) {
        const start = Number(range[1]);
        const end = range[2] ? Math.min(Number(range[2]), body.length - 1) : body.length - 1;
        if (start >= body.length)
          return route.fulfill({
            status: 416,
            headers: { "Content-Range": `bytes */${body.length}` },
          });
        return route.fulfill({
          status: 206,
          contentType: "video/mp4",
          headers: {
            "Accept-Ranges": "bytes",
            "Content-Range": `bytes ${start}-${end}/${body.length}`,
          },
          body: body.subarray(start, end + 1),
        });
      }
      return route.fulfill({
        status: 200,
        contentType: "video/mp4",
        headers: { "Accept-Ranges": "bytes" },
        body,
      });
    });
    const model = new StoryPage(page);
    current = { page, context, model };
    const failedRequest =
      routeMode === "fail"
        ? page.waitForEvent("requestfailed", {
            predicate: (request) => new URL(request.url()).pathname === story.video,
          })
        : undefined;
    // Remote font downloads are unrelated to decoder/fallback assertions and
    // can outlast the test's page timeout. Wait for layout CSS and each tested
    // state explicitly instead of the global load event.
    await page.goto(origin, { waitUntil: "domcontentloaded" });
    await page.waitForFunction(() =>
      Array.from(document.querySelectorAll('link[rel~="stylesheet"]'))
        .filter((link) => new URL(link.href).origin === location.origin)
        .every((link) => link.sheet),
    );
    return { page, context, model, requests, mediaResponses, failedRequest, release: () => releasePending?.() };
  };
  const close = async (item) => {
    await item.context.tracing.stop();
    await item.context.close();
    contexts.delete(item.context);
    current = undefined;
  };
  const verifyPrerender = async () => {
    const context = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      javaScriptEnabled: false,
    });
    contexts.add(context);
    await context.tracing.start({ screenshots: true, snapshots: true });
    const page = await context.newPage();
    const mp4Requests = [];
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
      if (url.pathname.endsWith(".mp4")) mp4Requests.push(url.pathname);
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
    current = { page, context, model };
    await page.goto(origin, { waitUntil: "load" });
    await model.root.scrollIntoViewIfNeeded();
    assert.equal(await model.root.getAttribute("data-mode"), "static");
    assert.equal(await model.root.getByRole("article").count(), 3);
    assert.equal(await model.video.count(), 0);
    assert.equal(await model.stage.count(), 0);
    assert.equal(
      await page.getByRole("heading", { name: "Enter your AI office." }).isVisible(),
      true,
    );
    assert.equal(
      await page.getByRole("link", { name: "Build your team" }).getAttribute("href"),
      "/download",
    );
    assert.equal(mp4Requests.length, 0);
    const html = await readFile(join(dist, "index.html"));
    report.prerender = {
      status: "passed",
      source: "apps/web/dist/index.html",
      sha256: createHash("sha256").update(html).digest("hex"),
      javaScriptEnabled: false,
      illustratedMoments: 3,
      filmLayers: 0,
      videoElements: 0,
      mp4Requests: 0,
    };
    report.passed.push(
      "existing prerender without JavaScript: three visible moments, CTA, no film layers or MP4 requests",
    );
    await close({ context });
  };
  try {
    browser = await engines[name].launch();
    report.version = browser.version();
    await verifyPrerender();
    if (!prerenderOnly) {
      const desktop = await prepare();
      report.readiness = await desktop.model.waitReady();
      assert.ok(desktop.requests.length > 0);
      assert.equal(report.readiness.height, report.readiness.viewport * 13);
      assert.deepEqual(report.readiness.seekable, [[0, 74]]);
      if (finalMedia) {
        const response = await desktop.context.request.get(new URL(story.video, origin).href, {
          headers: { Range: "bytes=0-1023" },
        });
        report.rangeProbe = {
          status: response.status(),
          contentRange: response.headers()["content-range"],
          contentType: response.headers()["content-type"],
          bytes: (await response.body()).length,
        };
        assert.equal(response.status(), 206);
        assert.match(report.rangeProbe.contentRange || "", /^bytes 0-1023\/\d+$/);
        assert.match(report.rangeProbe.contentType || "", /^video\/mp4/);
      }
      for (const time of [7, 13, 20, 32, 42, 51, 61, 67, 74, 0, 72, 2, 55, 18, 65, 74]) {
        report.samples.push(await desktop.model.frameAt(time));
      }
      assert.equal(
        await desktop.page
          .getByLabel("Examples of completed tasks")
          .locator(":scope > div")
          .count(),
        5,
      );
      const payoff = desktop.page.getByRole("heading", {
        name: "Your AI employees are already at work.",
      });
      assert.equal(
        await payoff.evaluate((el) => Number(getComputedStyle(el.parentElement).opacity)),
        1,
      );
      assert.equal(
        await desktop.page.getByRole("link", { name: "Build your team" }).getAttribute("href"),
        "/download",
      );
      if (finalMedia)
        await desktop.page.screenshot({ path: join(output, `final-media-${name}-payoff.png`) });
      await desktop.model.frameAt(65);
      assert.equal(await desktop.model.stage.getByRole("heading").count(), 0);
      assert.equal(await desktop.page.getByLabel("Examples of completed tasks").count(), 0);
      await desktop.model.root.evaluate((el) => {
        const start = scrollY + el.getBoundingClientRect().top;
        const travel = el.clientHeight - innerHeight;
        for (const progress of [0.2, 0.8, 0.3, 0.5]) window.scrollTo(0, start + travel * progress);
      });
      await desktop.page.waitForFunction(
        () =>
          Math.abs(
            Number(
              document.querySelector("#product [data-presented-time]")?.dataset.presentedTime,
            ) - 37,
          ) < 0.1,
      );
      report.rangeRequests = desktop.requests;
      report.mediaResponses = desktop.mediaResponses;
      report.passed.push(
        "first presented frame + full seekable range before promotion",
        "all scroll milestones, reversal to zero, large jumps",
        "latest target coalescing",
        "paused/muted/inline throughout",
        "five notifications + fully visible final CTA",
        "exit has no captions",
      );
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
        ["reduced motion", { reducedMotion: "reduce" }],
      ]) {
        const item = await prepare(options);
        await item.model.root.scrollIntoViewIfNeeded();
        assert.equal(item.requests.length, 0);
        assert.equal(await item.model.video.count(), 0);
        assert.equal(await item.model.root.getByRole("article").count(), 3);
        assert.equal(
          await item.page.getByRole("link", { name: "Build your team" }).getAttribute("href"),
          "/download",
        );
        assert.equal(
          await item.page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
          true,
        );
        report.passed.push(
          `${label}: no video request, three readable moments, CTA, no horizontal overflow`,
        );
        await close(item);
      }

      const failed = await prepare({}, "fail");
      await failed.failedRequest;
      assert.ok(failed.requests.length > 0, "The missing-media scenario must attempt its source");
      await failed.page.waitForFunction(
        () => document.getElementById("product")?.dataset.mode === "static",
      );
      assert.equal(await failed.model.video.count(), 0);
      report.passed.push("failed video request retains static fallback");
      await close(failed);

      const slow = await prepare({}, "pending");
      await slow.model.video.waitFor({ state: "attached" });
      await slow.model.root.scrollIntoViewIfNeeded();
      await slow.page.waitForFunction(
        () => document.getElementById("product")?.dataset.mode === "static",
      );
      slow.release();
      assert.equal(await slow.model.video.count(), 0);
      report.passed.push(
        "visitor enters before readiness: static layout locked, no late promotion",
      );
      await close(slow);

      if (finalMedia) {
        const beforeSlow = Date.now();
        const delayed = await prepare({}, "slow");
        const slowReady = await delayed.model.waitReady();
        await delayed.model.frameAt(55);
        await delayed.model.frameAt(7);
        report.slowResponse = {
          status: "passed",
          injectedResponseLatencyMs: 3000,
          readyAfterMs: Date.now() - beforeSlow,
          mode: slowReady.mode,
          caveat: "Response latency test; not a sustained bandwidth throttle.",
        };
        report.passed.push(
          "actual media with 3-second response latency: safe readiness, forward and reverse seeks",
        );
        await close(delayed);
      }

      const compatibility = await prepare({}, "film", true);
      await compatibility.model.waitReady();
      for (const time of [55, 7, 74]) await compatibility.model.frameAt(time);
      report.passed.push("without requestVideoFrameCallback: loadeddata/seeked compatibility path");
      await close(compatibility);
      const sorted = report.samples.map((sample) => sample.settledMs).sort((a, b) => a - b);
      report.seekSummary = {
        count: sorted.length,
        medianMs: sorted[Math.floor(sorted.length / 2)],
        p95Ms: sorted[Math.ceil(sorted.length * 0.95) - 1],
        maxMs: sorted.at(-1),
        maxErrorFrames: Math.max(...report.samples.map((sample) => sample.errorFrames)),
      };
    }
    report.status = "passed";
    await Promise.all([
      rm(join(output, `${reportPrefix}-${name}-failure.png`), { force: true }),
      rm(join(output, `${reportPrefix}-${name}-failure.trace.zip`), { force: true }),
    ]);
  } catch (error) {
    report.status = "failed";
    report.error = String(error.stack || error);
    if (current) {
      report.failureState = await current.model.snapshot().catch(() => null);
      await current.page
        .screenshot({ path: join(output, `${reportPrefix}-${name}-failure.png`) })
        .catch(() => {});
      await current.context.tracing
        .stop({ path: join(output, `${reportPrefix}-${name}-failure.trace.zip`) })
        .catch(() => {});
    }
  } finally {
    for (const context of contexts) await context.close().catch(() => {});
    await browser?.close();
    await writeFile(
      join(output, `${reportPrefix}-${name}.json`),
      `${JSON.stringify(report, null, 2)}\n`,
    );
  }
  return report;
}

try {
  const reports = await Promise.all(selected.map(runBrowser));
  if (finalMedia) {
    await writeFile(
      join(output, "final-media-summary.json"),
      `${JSON.stringify(
        {
          status: reports.every((report) => report.status === "passed") ? "passed" : "failed",
          timestamp: new Date().toISOString(),
          origin,
          media: mediaInfo,
          fixtureSubstitution: false,
          limitations:
            "Automated desktop engines; not native Safari, real mobile hardware or a creative continuity review. Timing includes concurrent browser execution.",
          engines: reports.map(({ engine, version, status, seekSummary }) => ({
            engine,
            version,
            status,
            seekSummary,
            report: `final-media-${engine}.json`,
          })),
        },
        null,
        2,
      )}\n`,
    );
  }
  console.log(
    JSON.stringify(
      reports.map(({ engine, version, status, error, failureState, passed }) => ({
        engine,
        version,
        status,
        error,
        failureState,
        passed,
      })),
      null,
      2,
    ),
  );
  if (reports.some((report) => report.status !== "passed")) process.exitCode = 1;
} finally {
  await rm(temp, { recursive: true, force: true });
}
