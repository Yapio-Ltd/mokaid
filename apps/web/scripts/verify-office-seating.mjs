/**
 * Headless check for the *stationary* half of office behaviour.
 *
 * verify-office-loco.mjs proves agents walk without clipping furniture; this
 * one watches them arrive and settle, asserting the things that were visibly
 * wrong before: agents sunk into cushions, two bodies sharing one socket, and
 * foosball players standing away from the table.
 *
 * Run: node scripts/verify-office-seating.mjs
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
/** How long to watch the office settle, in seconds. */
const WATCH_SECONDS = Number(process.env.WATCH_SECONDS || 45);

/** Scene-space furniture the poses target (mirrors office-navdata.ts). */
const SOFA_BACKREST = { minX: -2.14, maxX: -1.44, minZ: -6.29, maxZ: -5.74 };
const FOOSBALL_TABLE = { minX: -2.27, maxX: -1.42, minZ: 4.13, maxZ: 5.21 };
/** Agents closer than this are interpenetrating rather than standing together. */
const MIN_AGENT_GAP = 0.45;

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
const consoleLogs = [];
page.on("console", (msg) => consoleLogs.push(`[${msg.type()}] ${msg.text()}`));
page.on("pageerror", (err) => consoleLogs.push(`[pageerror] ${err.message}`));

try {
  await page.goto(`${BASE}/login`, { waitUntil: "networkidle", timeout: 60_000 });
  await page.getByLabel(/email/i).fill(EMAIL);
  await page.getByLabel(/password/i).fill(PASSWORD);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.waitForURL(/dashboard|onboarding|agents/i, { timeout: 60_000 });
  if (!/dashboard/.test(page.url())) {
    await page.goto(`${BASE}/dashboard`, { waitUntil: "domcontentloaded", timeout: 60_000 });
  }
  await page.waitForSelector('canvas[aria-label="3D office view"]', { timeout: 120_000 });

  let snap = null;
  for (let i = 0; i < 60; i++) {
    snap = await page.evaluate(() => window.__mokaidOfficeDebug?.() ?? null);
    if (snap?.officeReady && snap?.crowdReady && snap.agents?.length) break;
    await sleep(1000);
  }
  if (!snap?.agents?.length) throw new Error("No agents in office snapshot");
  console.log(`→ watching ${snap.agents.length} agents for ${WATCH_SECONDS}s`);

  const samples = [];
  for (let i = 0; i < WATCH_SECONDS; i++) {
    const s = await page.evaluate(() => window.__mokaidOfficeDebug?.() ?? null);
    if (s?.agents?.length) samples.push(s);
    const busy = (s?.agents ?? []).filter((a) => a.activity);
    if (busy.length) {
      console.log(`t+${i}s`, busy.map((a) => `${a.name}:${a.activity}`).join(" "));
    }
    await sleep(1000);
  }
  await page.screenshot({ path: join(OUT, "office-seating.png"), fullPage: true });

  const problems = [];
  const seenActivities = new Set();

  for (const [i, s] of samples.entries()) {
    const agents = s.agents ?? [];
    for (const a of agents) {
      if (a.activity) seenActivities.add(a.activity);

      // Overlapping furniture only matters while the agent is *moving*: a
      // sitter is on the sofa cushion by design, and an agent standing at a
      // desk chair shares that chair's footprint. Walking through a solid is
      // the real bug, so gate on actual motion.
      const moving = (a.speed ?? 0) > 0.15;
      if (a.inFurniture && moving && a.activity !== "sitting_sofa") {
        problems.push(
          `t+${i}s ${a.name} walked through furniture at (${a.rawX}, ${a.rawZ}) speed ${a.speed}`,
        );
      }

      if (a.activity === "sitting_sofa" && a.rawZ !== undefined) {
        const inBack =
          a.rawX >= SOFA_BACKREST.minX &&
          a.rawX <= SOFA_BACKREST.maxX &&
          a.rawZ >= SOFA_BACKREST.minZ &&
          a.rawZ <= SOFA_BACKREST.maxZ;
        if (inBack) problems.push(`t+${i}s ${a.name} sitting inside the sofa backrest`);
      }

      if (a.activity === "playing_foosball" && a.rawZ !== undefined) {
        // Distance to the table footprint on both axes — players stand on the
        // west flank or the south end, so a single-axis check misses one.
        const dx = Math.max(FOOSBALL_TABLE.minX - a.rawX, 0, a.rawX - FOOSBALL_TABLE.maxX);
        const dz = Math.max(FOOSBALL_TABLE.minZ - a.rawZ, 0, a.rawZ - FOOSBALL_TABLE.maxZ);
        const gap = Math.hypot(dx, dz);
        if (gap > 0.75) {
          problems.push(`t+${i}s ${a.name} playing foosball ${gap.toFixed(2)}m from the table`);
        }
      }
    }

    // Two agents occupying the same point means a socket was double-claimed.
    for (let x = 0; x < agents.length; x++) {
      for (let y = x + 1; y < agents.length; y++) {
        const d = Math.hypot(agents[x].x - agents[y].x, agents[x].z - agents[y].z);
        if (d < MIN_AGENT_GAP) {
          problems.push(
            `t+${i}s ${agents[x].name} and ${agents[y].name} overlap (${d.toFixed(2)}m apart)`,
          );
        }
      }
    }
  }

  writeFileSync(
    join(OUT, "seating-report.json"),
    JSON.stringify(
      {
        samples: samples.length,
        activitiesSeen: [...seenActivities],
        problems,
        consoleLogs: consoleLogs.slice(-60),
      },
      null,
      2,
    ),
  );

  console.log("RESULT", {
    samples: samples.length,
    activitiesSeen: [...seenActivities],
    problemCount: problems.length,
  });
  if (problems.length) {
    for (const p of problems.slice(0, 15)) console.log("  ✗", p);
    throw new Error(`${problems.length} seating problems detected`);
  }
  console.log("OK office seating verified");
} catch (err) {
  console.log("FAIL", err);
  process.exitCode = 1;
} finally {
  await browser.close();
}
