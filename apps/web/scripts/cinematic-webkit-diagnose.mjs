import { webkit } from "playwright";
import { readFile, writeFile } from "node:fs/promises";

const origin = process.argv[2] || "http://127.0.0.1:4173";
const source = process.argv[3] || JSON.parse(await readFile(new URL("../src/data/cinematic-story.json", import.meta.url), "utf8")).video;
const browser = await webkit.launch();
const report = { origin, source, engine: browser.version(), responses: [] };
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await context.addInitScript(() => {
    window.__mediaEvents = [];
    window.__eligibility = [];
    const rect = Element.prototype.getBoundingClientRect;
    Element.prototype.getBoundingClientRect = function() {
      const result = rect.call(this);
      if (this.id === "product") window.__eligibility.push({ type: "rect", timeMs: performance.now(), top: result.top, height: result.height, viewport: innerHeight, ready: document.readyState, prerender: window.__MOKAID_PRERENDER__, mode: this.dataset.mode, previousHeight: this.previousElementSibling?.getBoundingClientRect().height, previousComputedHeight: this.previousElementSibling ? getComputedStyle(this.previousElementSibling).height : null, sheets: Array.from(document.styleSheets, (sheet) => sheet.href) });
      return result;
    };
    const matchMedia = window.matchMedia;
    window.matchMedia = function(query) {
      const result = matchMedia.call(this, query);
      window.__eligibility.push({ type: "query", query, matches: result.matches, timeMs: performance.now() });
      return result;
    };
    const log = (video, type, extra = {}) => {
      window.__mediaEvents.push({ type, timeMs: performance.now(), src: video.currentSrc || video.src, readyState: video.readyState, networkState: video.networkState, duration: video.duration, currentTime: video.currentTime, error: video.error ? { code: video.error.code, message: video.error.message } : null, seekable: Array.from({ length: video.seekable.length }, (_, index) => [video.seekable.start(index), video.seekable.end(index)]), ...extra });
    };
    for (const type of ["loadstart", "loadedmetadata", "loadeddata", "canplay", "canplaythrough", "error", "abort", "emptied", "progress", "stalled", "suspend", "seeking", "seeked"]) {
      document.addEventListener(type, (event) => { if (event.target instanceof HTMLVideoElement) log(event.target, type); }, true);
    }
    const requestFrame = HTMLVideoElement.prototype.requestVideoFrameCallback;
    HTMLVideoElement.prototype.requestVideoFrameCallback = function(callback) {
      return requestFrame.call(this, (now, metadata) => { log(this, "presented", { mediaTime: metadata.mediaTime }); callback(now, metadata); });
    };
  });
  const page = await context.newPage();
  page.on("response", (response) => {
    if (response.url().endsWith(".mp4")) report.responses.push({ url: response.url(), status: response.status(), headers: response.headers(), range: response.request().headers().range });
  });
  await page.goto(origin, { waitUntil: "load" });
  await page.waitForFunction(() => window.__mediaEvents.some((event) => ["error", "presented"].includes(event.type)), null, { timeout: 15000 }).catch(() => {});
  report.page = await page.evaluate(() => ({ mode: document.getElementById("product")?.dataset.mode, finalTop: document.getElementById("product")?.getBoundingClientRect().top, events: window.__mediaEvents, eligibility: window.__eligibility, codecs: ["avc1.640032", "avc1.640028", "avc1.4D4028"].map((codec) => ({ codec, canPlay: document.createElement("video").canPlayType(`video/mp4; codecs="${codec}"`) })) }));
  const direct = await context.newPage();
  await direct.goto(`${origin}/favicon.ico`).catch(() => {});
  report.direct = await direct.evaluate(async (url) => {
    const video = document.createElement("video");
    video.muted = true;
    video.playsInline = true;
    video.preload = "auto";
    video.width = 640;
    document.body.replaceChildren(video);
    const result = new Promise((resolve) => {
      video.addEventListener("loadeddata", () => resolve({ outcome: "loadeddata", width: video.videoWidth, height: video.videoHeight, duration: video.duration }), { once: true });
      video.addEventListener("error", () => resolve({ outcome: "error", error: { code: video.error?.code, message: video.error?.message } }), { once: true });
      setTimeout(() => resolve({ outcome: "timeout", readyState: video.readyState, duration: video.duration, events: window.__mediaEvents }), 10000);
    });
    video.src = url;
    video.load();
    return result;
  }, new URL(source, origin).href);
  await writeFile(new URL("../../../artifacts/mokaid-cinema-2026-09-25/verification/webkit-media-diagnostic.json", import.meta.url), `${JSON.stringify(report, null, 2)}\n`);
  console.log(JSON.stringify(report, null, 2));
} finally { await browser.close(); }
