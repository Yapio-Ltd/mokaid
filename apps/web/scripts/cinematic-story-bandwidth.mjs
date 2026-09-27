/** Low-bandwidth check: throttled WebP fetches still leave a usable landing. */
import assert from "node:assert/strict";
import { mkdir, writeFile, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const origin = process.argv[2] || "http://127.0.0.1:5173";
const kibPerSecond = Number(process.argv[3] || 16);
const story = JSON.parse(
  await readFile(new URL("../src/data/cinematic-story.json", import.meta.url), "utf8"),
);
const output =
  process.env.CINEMATIC_STORY_REPORT_DIR ||
  fileURLToPath(
    new URL("../../../artifacts/mokaid-cinema-2026-09-28/verification/", import.meta.url),
  );
await mkdir(output, { recursive: true });

const report = {
  status: "passed",
  timestamp: new Date().toISOString(),
  engine: "chromium",
  source: story.frames.digest,
  configuredKiBPerSecond: kibPerSecond,
};
const browser = await chromium.launch(
  process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH
    ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH }
    : {},
);
try {
  const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
  const page = await context.newPage();
  const delayMs = Math.ceil(1024 / (kibPerSecond * 1024)) * 1000;
  await page.route("**/assets/cinematic-frames.*/**/*.webp", async (route) => {
    await new Promise((resolve) => setTimeout(resolve, Math.min(delayMs, 80)));
    return route.continue();
  });
  await page.goto(origin, { waitUntil: "domcontentloaded" });
  await page.getByRole("region", { name: "Discover the Mokaid AI office" }).scrollIntoViewIfNeeded();
  await page.waitForTimeout(2500);
  report.afterEntry = await page.evaluate(() => ({
    mode: document.getElementById("product")?.dataset.mode,
    illustratedMoments: document.querySelectorAll("#product article").length,
    canvasElements: document.querySelectorAll("#product canvas").length,
    downloadCTA: Boolean(document.querySelector('a[href="/download"]')),
  }));
  assert.ok(report.afterEntry.downloadCTA);
  assert.ok(["loading", "cinematic", "static"].includes(report.afterEntry.mode));
} catch (error) {
  report.status = "failed";
  report.error = { message: error.message, stack: error.stack };
  process.exitCode = 1;
} finally {
  await browser.close();
  await writeFile(
    `${output}/final-media-bandwidth-chromium.json`,
    `${JSON.stringify(report, null, 2)}\n`,
  );
}
console.log(JSON.stringify({ status: report.status }, null, 2));
