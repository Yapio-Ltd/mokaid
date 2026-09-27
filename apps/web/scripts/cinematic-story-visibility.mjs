/** WebKit visibility: scrubbing resumes after the tab is hidden. */
import assert from "node:assert/strict";
import { mkdir, writeFile, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { webkit } from "playwright";

const origin = process.argv[2] || "http://127.0.0.1:5173";
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
  digest: story.frames.digest,
  timestamp: new Date().toISOString(),
};
const browser = await webkit.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await page.goto(origin, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(
    () => document.getElementById("product")?.dataset.mode === "cinematic",
    null,
    { timeout: 180_000 },
  );
  const scrollTo = async (progress) => {
    await page.evaluate((value) => {
      const el = document.getElementById("product");
      window.scrollTo(
        0,
        window.scrollY + el.getBoundingClientRect().top + (el.clientHeight - innerHeight) * value,
      );
    }, progress);
    await page.waitForTimeout(200);
  };
  await scrollTo(0.27);
  report.beforeHidden = await page.evaluate(() => ({
    presentedTime: Number(
      document.querySelector("#product [data-presented-time]")?.dataset.presentedTime,
    ),
    hidden: document.hidden,
  }));
  await page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")));
  await page.evaluate(() => {
    Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  report.whileHidden = await page.evaluate(() => ({
    presentedTime: Number(
      document.querySelector("#product [data-presented-time]")?.dataset.presentedTime,
    ),
    hidden: document.hidden,
  }));
  assert.equal(report.whileHidden.presentedTime, report.beforeHidden.presentedTime);
  await page.evaluate(() => {
    Object.defineProperty(document, "hidden", { configurable: true, get: () => false });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await scrollTo(0.57);
  await page.waitForFunction(
    () =>
      Math.abs(
        Number(document.querySelector("#product [data-presented-time]")?.dataset.presentedTime) -
          42,
      ) < 0.2,
  );
  report.afterVisible = await page.evaluate(() => ({
    presentedTime: Number(
      document.querySelector("#product [data-presented-time]")?.dataset.presentedTime,
    ),
  }));
  assert.ok(Math.abs(report.afterVisible.presentedTime - 42) < 0.2);
} catch (error) {
  report.status = "failed";
  report.error = { message: error.message, stack: error.stack };
  process.exitCode = 1;
} finally {
  await browser.close();
  await writeFile(`${output}/visibility-webkit.json`, `${JSON.stringify(report, null, 2)}\n`);
}
console.log(JSON.stringify({ status: report.status }, null, 2));
