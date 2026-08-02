/**
 * Headless browser check: login → dashboard office → sample agent positions.
 * Run: node scripts/verify-office-loco.mjs
 */
import { chromium } from "playwright";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(fileURLToPath(import.meta.url));
const OUT = join(ROOT, "../tmp-office-verify");
mkdirSync(OUT, { recursive: true });

const BASE = process.env.MOKAID_WEB_URL || "http://localhost:5173";
const EMAIL = process.env.MOKAID_EMAIL || "tom@yapio.io";
const PASSWORD = process.env.MOKAID_PASSWORD || "password123";

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
const consoleLogs = [];
let recoverCount = 0;
page.on("console", (msg) => {
  const text = msg.text();
  consoleLogs.push(`[${msg.type()}] ${text}`);
  if (/crowd recover/i.test(text)) recoverCount += 1;
  if (/OfficeScene|office-crowd|Recast|WebGL|error/i.test(text)) {
    console.log("CONSOLE", msg.type(), text.slice(0, 200));
  }
});
page.on("pageerror", (err) => {
  consoleLogs.push(`[pageerror] ${err.message}`);
  console.log("PAGEERROR", err.message);
});

try {
  console.log("→ login", BASE);
  await page.goto(`${BASE}/login`, { waitUntil: "networkidle", timeout: 60_000 });
  await page.getByLabel(/email/i).fill(EMAIL);
  await page.getByLabel(/password/i).fill(PASSWORD);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.waitForURL(/dashboard|onboarding|agents/i, { timeout: 60_000 });
  console.log("→ landed", page.url());

  if (!/dashboard/.test(page.url())) {
    await page.goto(`${BASE}/dashboard`, { waitUntil: "domcontentloaded", timeout: 60_000 });
  }

  // Wait for Babylon canvas + office ready.
  await page.waitForSelector('canvas[aria-label="3D office view"]', { timeout: 120_000 });
  console.log("→ canvas present");

  let snap = null;
  for (let i = 0; i < 60; i++) {
    snap = await page.evaluate(() => {
      const fn = window.__mokaidOfficeDebug;
      return typeof fn === "function" ? fn() : null;
    });
    if (snap?.officeReady && snap?.crowdReady && snap.agents?.length) break;
    await sleep(1000);
  }
  console.log("→ initial snap", JSON.stringify(snap, null, 2));
  await page.screenshot({ path: join(OUT, "office-t0.png"), fullPage: true });

  if (!snap?.crowdReady) {
    throw new Error("Recast crowd never became ready — check console logs");
  }
  if (!snap?.agents?.length) {
    throw new Error("No agents in office snapshot");
  }

  const samples = [snap];
  for (let i = 0; i < 8; i++) {
    await sleep(1000);
    const s = await page.evaluate(() => window.__mokaidOfficeDebug?.());
    samples.push(s);
    console.log(
      `t+${i + 1}s`,
      s?.agents?.map((a) => `${a.name}@(${a.x},${a.z}) spd=${a.speed} furn=${a.inFurniture}`),
    );
  }
  await page.screenshot({ path: join(OUT, "office-t8.png"), fullPage: true });

  const names = [...new Set(samples.flatMap((s) => (s?.agents ?? []).map((a) => a.name)))];

  // True locomotion: position changes while Detour reports speed (not a one-shot teleport).
  const perAgent = names.map((name) => {
    const track = samples
      .map((s) => s?.agents?.find((a) => a.name === name))
      .filter(Boolean);
    let maxStep = 0;
    let walkingInPlaceFrames = 0;
    let pathLen = 0;
    for (let i = 1; i < track.length; i++) {
      const d = Math.hypot(track[i].x - track[i - 1].x, track[i].z - track[i - 1].z);
      pathLen += d;
      maxStep = Math.max(maxStep, d);
      if (track[i].speed > 0.4 && d < 0.05) walkingInPlaceFrames += 1;
    }
    const end = Math.hypot(
      track[track.length - 1].x - track[0].x,
      track[track.length - 1].z - track[0].z,
    );
    return { name, pathLen, maxStep, end, walkingInPlaceFrames, last: track[track.length - 1] };
  });

  const moved = perAgent.some((a) => a.pathLen > 0.8 || a.maxStep > 0.35);
  const anyInFurniture = samples.some((s) => s?.agents?.some((a) => a.inFurniture));
  const stuckWalking = perAgent.some((a) => a.walkingInPlaceFrames >= 3);

  writeFileSync(
    join(OUT, "report.json"),
    JSON.stringify(
      { moved, anyInFurniture, stuckWalking, perAgent, samples, consoleLogs: consoleLogs.slice(-80) },
      null,
      2,
    ),
  );

  const buildHint = samples[samples.length - 1]?.buildHint;
  console.log("RESULT", { moved, anyInFurniture, stuckWalking, recoverCount, buildHint, perAgent });
  if (buildHint !== 14) throw new Error(`Expected OFFICE_SCENE_BUILD 14, got ${buildHint}`);
  if (!moved) throw new Error("Agents did not move >0.35m over 8s");
  if (anyInFurniture) throw new Error("Agent was inside furniture AABB during sample");
  if (stuckWalking) {
    throw new Error(
      `Walking-in-place detected (speed>0.4 but Δpos<5cm for ≥3s): ${JSON.stringify(perAgent)}`,
    );
  }
  if (recoverCount > 4) {
    throw new Error(`Too many crowd recover thrash events: ${recoverCount}`);
  }
  console.log("OK office locomotion verified");
  process.exitCode = 0;
} catch (err) {
  console.error("FAIL", err);
  await page.screenshot({ path: join(OUT, "office-fail.png"), fullPage: true }).catch(() => {});
  writeFileSync(join(OUT, "console.txt"), consoleLogs.join("\n"));
  process.exitCode = 1;
} finally {
  await browser.close();
}
