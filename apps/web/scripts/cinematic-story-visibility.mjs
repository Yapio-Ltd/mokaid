/** Targeted app visibility regression with the actual paused movie, not native OS occlusion.
 * node scripts/cinematic-story-visibility.mjs [origin] [--no-trace]
 */
import assert from "node:assert/strict";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { webkit } from "playwright";

const origin = process.argv[2] || "http://127.0.0.1:4173";
const story = JSON.parse(await readFile(new URL("../src/data/cinematic-story.json", import.meta.url), "utf8"));
const output = new URL("../../../artifacts/mokaid-cinema-2026-09-27/verification/", import.meta.url);
await mkdir(output, { recursive: true });
const traceCompositor = !process.argv.includes("--no-trace");
const reportName = traceCompositor ? "visibility-webkit" : "visibility-webkit-uncomposited";
const report = {
  status: "pending",
  origin,
  movie: story.video,
  engine: "webkit",
  simulation: "Override document.hidden/visibilityState and dispatch visibilitychange; real media decoding and the production GSAP ticker remain active.",
  limitation: "Tests application suspension/resumption only. Does not emulate Safari OS window occlusion, native rAF throttling or an actual background tab.",
};
const browser = await webkit.launch();
let page;
try {
  report.version = browser.version();
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  if (traceCompositor) await context.tracing.start({ screenshots: true, snapshots: true });
  report.tracingScreenshots = traceCompositor;
  await context.addInitScript(() => {
    let simulatedHidden = false;
    window.__visibilityEvents = [];
    window.__seekEvents = [];
    window.__presentedEvents = [];
    const requestFrame = HTMLVideoElement.prototype.requestVideoFrameCallback;
    HTMLVideoElement.prototype.requestVideoFrameCallback = function(callback) {
      return requestFrame.call(this, (now, metadata) => {
        window.__presentedEvents.push(metadata.mediaTime);
        callback(now, metadata);
      });
    };
    Object.defineProperty(document, "hidden", { configurable: true, get: () => simulatedHidden });
    Object.defineProperty(document, "visibilityState", { configurable: true, get: () => simulatedHidden ? "hidden" : "visible" });
    window.__setTestVisibility = (hidden) => {
      simulatedHidden = hidden;
      window.__visibilityEvents.push({ hidden, timeMs: performance.now() });
      document.dispatchEvent(new Event("visibilitychange"));
    };
    document.addEventListener("seeking", (event) => {
      if (event.target instanceof HTMLVideoElement)
        window.__seekEvents.push({ time: event.target.currentTime, hidden: document.hidden });
    }, true);
  });
  page = await context.newPage();
  report.pageErrors = [];
  page.on("pageerror", (error) => report.pageErrors.push(String(error)));
  await page.goto(origin, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => document.getElementById("product")?.dataset.mode === "cinematic", null, { timeout: 12000 });
  const progressAt = (time) => {
    const index = story.scrollMap.findIndex((point) => point.time >= time);
    if (index <= 0) return 0;
    const from = story.scrollMap[index - 1];
    const to = story.scrollMap[index];
    return from.progress + (time - from.time) / (to.time - from.time) * (to.progress - from.progress);
  };
  const snapshot = () => page.evaluate(() => {
    const section = document.getElementById("product");
    const video = section.querySelector("video");
    return {
      mode: section.dataset.mode,
      hidden: document.hidden,
      currentTime: video.currentTime,
      presentedTime: Number(section.querySelector("[data-presented-time]").dataset.presentedTime),
      paused: video.paused,
      seeking: video.seeking,
      mediaError: video.error?.message || null,
      recoveryVisible: Boolean(section.querySelector(".mk-cinema-recovery")),
      seekEvents: [...window.__seekEvents],
    };
  });
  const scrollTo = (time) => page.evaluate((progress) => {
    const section = document.getElementById("product");
    window.scrollTo(0, scrollY + section.getBoundingClientRect().top + (section.clientHeight - innerHeight) * progress);
  }, progressAt(time));
  const waitPresented = (time) => page.waitForFunction((target) => {
    const section = document.getElementById("product");
    const video = section.querySelector("video");
    return !video.seeking && Math.abs(Number(section.querySelector("[data-presented-time]").dataset.presentedTime) - target) < 0.1;
  }, time, { timeout: 8000 });

  await scrollTo(20);
  await waitPresented(20);
  report.beforeHidden = await snapshot();
  await page.evaluate(() => window.__setTestVisibility(true));
  for (const time of [55, 7, 42, 51]) {
    await scrollTo(time);
    // Ensure the production ticker has seen each request while the explicit
    // visibility guard is active; these are frame boundaries, not timed sleeps.
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  }
  report.whileHidden = await snapshot();
  assert.equal(report.whileHidden.currentTime, report.beforeHidden.currentTime);
  assert.equal(report.whileHidden.presentedTime, report.beforeHidden.presentedTime);
  assert.equal(report.whileHidden.seekEvents.length, report.beforeHidden.seekEvents.length);

  const started = Date.now();
  await page.evaluate(() => window.__setTestVisibility(false));
  await waitPresented(51);
  report.resumed = await snapshot();
  report.resumeSettledMs = Date.now() - started;
  report.resumedSeeks = report.resumed.seekEvents.slice(report.whileHidden.seekEvents.length);
  assert.equal(report.resumedSeeks.length, 1, "Resume must seek once to the latest scroll target");
  assert.ok(Math.abs(report.resumedSeeks[0].time - 51) < 0.1);
  assert.equal(report.resumed.paused, true);
  assert.equal(report.resumed.mediaError, null);
  assert.equal(report.resumed.recoveryVisible, false);
  await scrollTo(7);
  await waitPresented(7);
  report.reverseAfterResume = await snapshot();
  report.visibilityEvents = await page.evaluate(() => window.__visibilityEvents);
  report.status = "passed";
} catch (error) {
  report.status = "failed";
  report.error = String(error.stack || error);
  report.failureState = await page?.evaluate(() => ({ scroll: scrollY, hidden: document.hidden, ready: document.readyState, productTop: document.getElementById("product")?.getBoundingClientRect().top, height: document.getElementById("product")?.clientHeight, currentTime: document.querySelector("#product video")?.currentTime, presentedTime: document.querySelector("#product [data-presented-time]")?.dataset.presentedTime, seeking: document.querySelector("#product video")?.seeking, readyState: document.querySelector("#product video")?.readyState, paused: document.querySelector("#product video")?.paused, presentedEvents: window.__presentedEvents, seeks: window.__seekEvents })).catch(() => null);
  await page?.screenshot({ path: new URL(`${reportName}-failure.png`, output).pathname }).catch(() => {});
  process.exitCode = 1;
} finally {
  await browser.close();
  await writeFile(new URL(`${reportName}.json`, output), `${JSON.stringify(report, null, 2)}\n`);
  console.log(JSON.stringify(report, null, 2));
}
