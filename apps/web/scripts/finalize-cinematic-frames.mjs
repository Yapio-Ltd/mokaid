#!/usr/bin/env node
/** Finalize story JSON + quality report from an already-exported slim frame pack. */
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const webRoot = resolve(here, "..");
const repoRoot = resolve(webRoot, "../..");
const short = process.argv[2];
assert.ok(short, "Usage: finalize-cinematic-frames.mjs <digest12>");
const publicDir = join(webRoot, "public/assets", `cinematic-frames.${short}`);
const storyPath = join(webRoot, "src/data/cinematic-story.json");
const story = JSON.parse(readFileSync(storyPath, "utf8"));
const sourceMp4 =
  process.env.MOKAID_CINEMA_SOURCE ||
  join(
    repoRoot,
    "artifacts/mokaid-cinema-2026-09-25/deliveries/mokaid-office-journey.adac1c365481.mp4",
  );
const packs = {
  desktop: { width: 720, height: 405, fps: 3, count: 222, quality: 55 },
  mobile: { width: 480, height: 270, fps: 2, count: 148, quality: 50 },
};

function bytesOf(dir) {
  return readdirSync(dir)
    .filter((name) => name.endsWith(".webp"))
    .reduce((sum, name) => sum + statSync(join(dir, name)).size, 0);
}

assert.ok(existsSync(publicDir), `Missing pack ${publicDir}`);
assert.ok(existsSync(sourceMp4), `Missing source ${sourceMp4}`);

const qualityReport = [];
for (const time of story.scrollMap.slice(0, 6).map((point) => point.time)) {
  const index = Math.min(
    packs.desktop.count,
    Math.max(1, Math.round(time * packs.desktop.fps) + 1),
  );
  const frameName = `frame-${String(index).padStart(5, "0")}.webp`;
  const framePath = join(publicDir, "desktop", frameName);
  assert.ok(existsSync(framePath), framePath);
  const reference = "/tmp/mokaid-ref.png";
  const candidate = "/tmp/mokaid-cand.png";
  for (const args of [
    [
      "-hide_banner",
      "-loglevel",
      "error",
      "-y",
      "-ss",
      String(Math.min(time, 73.95)),
      "-i",
      sourceMp4,
      "-frames:v",
      "1",
      "-vf",
      "scale=640:360:flags=lanczos",
      reference,
    ],
    [
      "-hide_banner",
      "-loglevel",
      "error",
      "-y",
      "-i",
      framePath,
      "-frames:v",
      "1",
      "-vf",
      "scale=640:360:flags=lanczos",
      candidate,
    ],
  ]) {
    const result = spawnSync("ffmpeg", args, { encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
  }
  const psnrRun = spawnSync(
    "ffmpeg",
    ["-hide_banner", "-i", reference, "-i", candidate, "-lavfi", "psnr", "-f", "null", "-"],
    { encoding: "utf8" },
  );
  const match = /average:([0-9.]+|inf)/.exec(psnrRun.stderr || "");
  const psnr = match?.[1] === "inf" ? Infinity : Number(match?.[1] || 0);
  qualityReport.push({ time, frame: frameName, psnrAverage: psnr });
  assert.ok(psnr === Infinity || psnr >= 24, `PSNR too low at t=${time}: ${psnr}`);
  rmSync(reference, { force: true });
  rmSync(candidate, { force: true });
}

const frames = {
  digest: short,
  quality: {
    desktop: packs.desktop.quality,
    mobile: packs.mobile.quality,
  },
  desktop: {
    pattern: `/assets/cinematic-frames.${short}/desktop/frame-%05d.webp`,
    firstIndex: 1,
    count: packs.desktop.count,
    fps: packs.desktop.fps,
    width: packs.desktop.width,
    height: packs.desktop.height,
    bytes: bytesOf(join(publicDir, "desktop")),
  },
  mobile: {
    pattern: `/assets/cinematic-frames.${short}/mobile/frame-%05d.webp`,
    firstIndex: 1,
    count: packs.mobile.count,
    fps: packs.mobile.fps,
    width: packs.mobile.width,
    height: packs.mobile.height,
    bytes: bytesOf(join(publicDir, "mobile")),
  },
};

const nextStory = { ...story, frames };
delete nextStory.video;
writeFileSync(storyPath, `${JSON.stringify(nextStory, null, 2)}\n`);

const reportDir = join(repoRoot, "artifacts/mokaid-cinema-2026-09-28/verification");
mkdirSync(reportDir, { recursive: true });
writeFileSync(
  join(reportDir, "frame-export.json"),
  `${JSON.stringify({ frames, qualityReport, publicDir }, null, 2)}\n`,
);

console.log(JSON.stringify({ frames, qualityReport }, null, 2));
