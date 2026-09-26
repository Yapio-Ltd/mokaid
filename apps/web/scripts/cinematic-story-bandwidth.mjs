/** Bounded actual-media bandwidth test; never creates or substitutes a video fixture.
 * node scripts/cinematic-story-bandwidth.mjs http://127.0.0.1:4173 [16]
 */
import assert from "node:assert/strict";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";
import { createMediaThrottleProxy } from "./cinematic-media-throttle.mjs";

const upstreamOrigin = process.argv[2] || "http://127.0.0.1:4173";
const kibPerSecond = Number(process.argv[3] || 16);
assert.ok(kibPerSecond >= 1 && kibPerSecond <= 128, "Use a bounded 1–128 KiB/s test rate");
const story = JSON.parse(
  await readFile(new URL("../src/data/cinematic-story.json", import.meta.url), "utf8"),
);
assert.match(
  story.video,
  /[.-][a-f0-9]{8,64}\.mp4$/i,
  "Wait for the final fingerprinted film; this test does not use a fixture",
);
const output = fileURLToPath(
  new URL("../../../artifacts/mokaid-cinema-2026-09-25/verification/", import.meta.url),
);
await mkdir(output, { recursive: true });
const report = {
  status: "pending",
  fixtureSubstitution: false,
  timestamp: new Date().toISOString(),
  engine: "chromium",
  source: story.video,
  upstreamOrigin,
  scenario:
    "Actual HTTP byte-range stream at an aggregate low bandwidth; enter before readiness and retain the illustrated experience.",
  configuredKiBPerSecond: kibPerSecond,
  maximumTestMs: 9000,
  chunksBytes: 1024,
  limitations:
    "Validates low-bandwidth fallback, not seek catch-up or fluent 1080p playback over this connection.",
};
let proxy;
let browser;
let context;
let page;
let deadline;
try {
  proxy = await createMediaThrottleProxy({
    upstreamOrigin,
    mediaPath: story.video,
    mediaFile: fileURLToPath(new URL(`../public${story.video}`, import.meta.url)),
    bytesPerSecond: kibPerSecond * 1024,
  });
  browser = await chromium.launch();
  report.version = browser.version();
  context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  await context.tracing.start({ screenshots: true, snapshots: true });
  page = await context.newPage();
  page.setDefaultTimeout(4000);
  deadline = setTimeout(() => {
    void context.close();
  }, report.maximumTestMs);
  await page.goto(proxy.origin, { waitUntil: "domcontentloaded", timeout: 5000 });
  const storyRegion = page.getByRole("region", { name: "Discover the Mokaid AI office" });
  await storyRegion.locator("video").waitFor({ state: "attached" });
  // Check real transfer rather than merely delaying response headers.
  const firstChunksDeadline = Date.now() + 2000;
  while (proxy.snapshot().transferredBytes < 4096 && Date.now() < firstChunksDeadline) {
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.ok(
    proxy.snapshot().transferredBytes >= 4096,
    "At least four real body chunks must cross the bandwidth-limited endpoint",
  );
  await page.waitForFunction(() => document.querySelector("#product video")?.networkState === 2);
  report.beforeEntry = await storyRegion.evaluate((root) => {
    const video = root.querySelector("video");
    return {
      mode: root.dataset.mode,
      readyState: video.readyState,
      presentedTime: Number(root.querySelector("[data-presented-time]")?.dataset.presentedTime),
    };
  });
  assert.equal(
    report.beforeEntry.mode,
    "loading",
    "The controlled low-bandwidth visit must still be awaiting media",
  );
  await storyRegion.evaluate((root) =>
    window.scrollTo(0, scrollY + root.getBoundingClientRect().top),
  );
  await page.waitForFunction(() => document.getElementById("product")?.dataset.mode === "static");
  assert.equal(await storyRegion.locator("video").count(), 0);
  assert.equal(await storyRegion.getByRole("article").count(), 3);
  const entryImage = storyRegion.getByRole("img", {
    name: "The Mokaid AI office, illuminated by violet pathways and warm desk lights.",
  });
  await entryImage.scrollIntoViewIfNeeded();
  await page.waitForFunction(() => {
    const image = document.querySelector("#product article img");
    return image && image.complete && image.naturalWidth > 0;
  });
  assert.equal(
    await storyRegion.getByRole("link", { name: "Build your team" }).getAttribute("href"),
    "/download",
  );
  report.transport = proxy.snapshot();
  assert.ok(
    report.transport.requests.some((request) => request.status === 206),
    "Browser must actually use the range-capable media endpoint",
  );
  assert.ok(
    report.transport.transferredBytes <= (kibPerSecond * 1024 * report.maximumTestMs) / 1000 + 1024,
    "Transfer stays inside the strict rate/time budget",
  );
  report.afterEntry = {
    mode: "static",
    illustratedMoments: 3,
    videoElements: 0,
    entryIllustrationDecoded: true,
    downloadCTA: true,
  };
  await page.screenshot({ path: `${output}/final-media-bandwidth-chromium.png` });
  report.status = "passed";
  await context.tracing.stop();
} catch (error) {
  report.status = "failed";
  report.error = String(error.stack || error);
  if (page)
    await page
      .screenshot({ path: `${output}/final-media-bandwidth-chromium-failure.png` })
      .catch(() => {});
  if (context)
    await context.tracing
      .stop({ path: `${output}/final-media-bandwidth-chromium-failure.trace.zip` })
      .catch(() => {});
  process.exitCode = 1;
} finally {
  clearTimeout(deadline);
  report.transport ??= proxy?.snapshot();
  await browser?.close();
  await proxy?.close();
  await writeFile(
    `${output}/final-media-bandwidth-chromium.json`,
    `${JSON.stringify(report, null, 2)}\n`,
  );
  console.log(JSON.stringify(report, null, 2));
}
